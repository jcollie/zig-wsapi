// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! When a frame will be heard, and the arithmetic that works it out.
//!
//! ```zig
//! const t = stream.time();
//! const heard_at = t.presentationNs();   // on the QPC clock, in nanoseconds
//! ```
//!
//! ## Which clock
//!
//! Everything here is on the performance counter -- `QueryPerformanceCounter` --
//! and not on any `std.Io` clock. That is deliberate and it matters: the
//! performance counter is the clock `IAudioClock2.GetDevicePosition` stamps its
//! positions with, so a timestamp from this library can be compared directly
//! with one from the audio engine. A timestamp from `io.now` cannot, and mixing
//! the two gives differences that look plausible and are wrong.
//!
//! The counter is converted to nanoseconds rather than left in ticks, because
//! ticks are meaningless without the frequency and every caller would have to
//! carry it around.

const std = @import("std");

/// Convert a performance-counter reading to nanoseconds.
///
/// ## The overflow that every naive version of this has
///
/// The obvious spelling is `counter * 1_000_000_000 / frequency`. In `u64` that
/// product overflows once `counter` passes about 1.8e10, which on a 10 MHz
/// performance counter -- the usual value on x86-64 -- is a little over half an
/// hour of uptime. The counter is not reset when a process starts: it counts from
/// boot. So the naive version works on a developer's freshly rebooted machine and
/// produces nonsense on a machine that has been up since Tuesday.
///
/// Doing the multiply in `u128` costs one instruction on a 64-bit target and
/// removes the failure entirely. The test at the bottom of this file walks ten
/// years of counter values.
pub fn qpcToNs(counter: u64, frequency: u64) u64 {
    std.debug.assert(frequency != 0);
    const product = @as(u128, counter) * std.time.ns_per_s;
    return @intCast(product / frequency);
}

/// Convert a difference in performance-counter ticks to nanoseconds.
///
/// Separate from `qpcToNs` because a *difference* is small -- one graph cycle is
/// a few thousand ticks -- so this is the version the render loop calls once a
/// cycle, and it has no need of the wide multiply.
pub fn qpcDeltaToNs(ticks: u64, frequency: u64) u64 {
    std.debug.assert(frequency != 0);
    // Still widened: a difference is normally tiny, but `resetStats` and a
    // stalled device can both produce a large one, and a wrong answer there
    // would be reported as an implausible latency rather than as a crash.
    return qpcToNs(ticks, frequency);
}

/// How long `frames` frames last at `rate`, in nanoseconds.
pub fn framesToNs(frames: u64, rate: u32) u64 {
    std.debug.assert(rate != 0);
    return @intCast(@as(u128, frames) * std.time.ns_per_s / rate);
}

/// How many whole frames fit in `ns` nanoseconds at `rate`.
pub fn nsToFrames(ns: u64, rate: u32) u64 {
    return @intCast(@as(u128, ns) * rate / std.time.ns_per_s);
}

/// Convert one of Windows' hundred-nanosecond units to nanoseconds.
///
/// `REFERENCE_TIME`, which is what `GetDevicePeriod` and `GetStreamLatency`
/// speak, counts in units of 100 ns. It is the single most common unit confusion
/// in WASAPI code -- a buffer duration off by a factor of ten either stutters or
/// asks for a second of latency -- so the conversion has a name rather than a
/// bare `* 100` at each call site.
pub fn hnsToNs(hns: i64) i64 {
    return hns * 100;
}

/// Nanoseconds to Windows' hundred-nanosecond units.
pub fn nsToHns(ns: i64) i64 {
    return @divTrunc(ns, 100);
}

/// Frames in a duration given in hundred-nanosecond units.
pub fn hnsToFrames(hns: i64, rate: u32) i64 {
    std.debug.assert(rate != 0);
    return @intCast(@divTrunc(@as(i128, hns) * rate, 10_000_000));
}

/// A duration in frames, as hundred-nanosecond units.
pub fn framesToHns(frames: i64, rate: u32) i64 {
    std.debug.assert(rate != 0);
    return @intCast(@divTrunc(@as(i128, frames) * 10_000_000, rate));
}

/// When the audio of a cycle will be heard.
///
/// Every field is zero before the first cycle has run, which is the honest answer
/// -- the graph has not told us anything yet -- and is why `presentationNs` on a
/// fresh stream returns zero rather than a guess.
pub const Time = struct {
    /// When the cycle started, on the performance counter, in nanoseconds.
    now_ns: u64 = 0,

    /// The rate the stream is running at, in frames a second.
    rate: u32 = 0,

    /// Frames in a cycle: the engine period.
    ///
    /// The nearest thing Windows has to PipeWire's quantum. Unlike a PipeWire
    /// quantum it can change when the stream moves to another endpoint; see
    /// `Stream.stats` and its `reopens` count.
    quantum: u32 = 0,

    /// Frames between the start of the cycle and its first frame reaching the
    /// speaker.
    ///
    /// Measured, not estimated: it is the difference between the frames handed to
    /// the engine and the position `IAudioClock2` reports having played. It covers
    /// the audio engine and the endpoint buffer. It does **not** cover anything
    /// past the digital-to-analogue converter -- shared mode exposes no figure for
    /// that -- so a Bluetooth headset's codec delay is partly outside this number.
    delay: i64 = 0,

    /// Frames written and not yet taken by the engine, which will be heard before
    /// anything written after them.
    ///
    /// Zero for a stream in pull mode, which has no queue: its audio is produced
    /// inside the cycle that plays it.
    queued: u64 = 0,

    /// `delay`, in nanoseconds.
    pub fn delayNs(self: Time) i64 {
        if (self.rate == 0) return 0;
        return @intCast(@divTrunc(@as(i128, self.delay) * std.time.ns_per_s, self.rate));
    }

    /// `queued`, in nanoseconds.
    pub fn queuedNs(self: Time) u64 {
        if (self.rate == 0) return 0;
        return framesToNs(self.queued, self.rate);
    }

    /// When the first frame produced in this cycle is heard, on the performance
    /// counter, in nanoseconds.
    ///
    /// The number to compare against `sys.nowNsec()` to answer "how far ahead am
    /// I?", and the number to schedule against when audio has to line up with
    /// something else.
    pub fn presentationNs(self: Time) i64 {
        if (self.rate == 0) return 0;
        return @as(i64, @intCast(self.now_ns)) + self.delayNs();
    }

    /// When the *last* frame already queued will be heard.
    ///
    /// `presentationNs` plus the queue, which is the figure a caller wants when
    /// deciding whether there is time to write more before something happens.
    pub fn queueDrainsAtNs(self: Time) i64 {
        if (self.rate == 0) return 0;
        return self.presentationNs() + @as(i64, @intCast(self.queuedNs()));
    }

    pub fn format(self: Time, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.rate == 0) {
            try w.writeAll("no cycle yet");
            return;
        }
        try w.print("{d} Hz, quantum {d}, delay {d} frames ({d} us), queued {d} frames", .{
            self.rate,
            self.quantum,
            self.delay,
            @divTrunc(self.delayNs(), std.time.ns_per_us),
            self.queued,
        });
    }
};

test "the counter conversion does not overflow after half an hour of uptime" {
    // The bug this function exists to avoid. On a 10 MHz performance counter the
    // naive `counter * 1e9` overflows `u64` at about 1.8e10 ticks, which is
    // roughly half an hour after boot -- so a naive version passes every test
    // written on a freshly restarted machine.
    const hz = 10_000_000;

    // Half an hour: the point where the naive version starts being wrong.
    try std.testing.expectEqual(
        @as(u64, 1800 * std.time.ns_per_s),
        qpcToNs(1800 * hz, hz),
    );

    // Ten years of uptime, which is beyond any real machine and still exact.
    const ten_years_s: u64 = 10 * 365 * 24 * 60 * 60;
    try std.testing.expectEqual(
        ten_years_s * std.time.ns_per_s,
        qpcToNs(ten_years_s * hz, hz),
    );
}

test "the counter conversion is exact at the frequencies real machines report" {
    // 10 MHz is the usual x86-64 value; 3.579545 MHz is the old PIT-derived one
    // that still turns up in virtual machines; 1 GHz appears on some ARM parts.
    for ([_]u64{ 10_000_000, 3_579_545, 1_000_000_000, 24_000_000 }) |hz| {
        try std.testing.expectEqual(@as(u64, 0), qpcToNs(0, hz));
        try std.testing.expectEqual(@as(u64, std.time.ns_per_s), qpcToNs(hz, hz));
        try std.testing.expectEqual(@as(u64, 60 * std.time.ns_per_s), qpcToNs(60 * hz, hz));
    }
}

test "frames and nanoseconds convert both ways" {
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), framesToNs(48000, 48000));
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_ms), framesToNs(480, 48000));
    try std.testing.expectEqual(@as(u64, 48000), nsToFrames(std.time.ns_per_s, 48000));
    try std.testing.expectEqual(@as(u64, 480), nsToFrames(10 * std.time.ns_per_ms, 48000));

    // And a long duration, where a `u64` product would be the risk.
    const a_day_of_frames: u64 = 48000 * 60 * 60 * 24;
    try std.testing.expectEqual(
        @as(u64, 24 * 60 * 60 * std.time.ns_per_s),
        framesToNs(a_day_of_frames, 48000),
    );
}

test "Windows' hundred-nanosecond units convert correctly" {
    // The factor-of-ten confusion that makes a buffer either stutter or ask for a
    // second of latency. 10_000_000 hundred-nanosecond units is one second.
    try std.testing.expectEqual(@as(i64, std.time.ns_per_s), hnsToNs(10_000_000));
    try std.testing.expectEqual(@as(i64, 10_000_000), nsToHns(std.time.ns_per_s));

    // A 10 ms period at 48 kHz is 480 frames and 100_000 of Windows' units.
    try std.testing.expectEqual(@as(i64, 480), hnsToFrames(100_000, 48000));
    try std.testing.expectEqual(@as(i64, 100_000), framesToHns(480, 48000));

    // And the round trip, at the awkward rate.
    try std.testing.expectEqual(@as(i64, 441), hnsToFrames(framesToHns(441, 44100), 44100));
}

test "a stream that has not run yet reports zero rather than a guess" {
    const t: Time = .{};
    try std.testing.expectEqual(@as(i64, 0), t.delayNs());
    try std.testing.expectEqual(@as(i64, 0), t.presentationNs());
    try std.testing.expectEqual(@as(u64, 0), t.queuedNs());
    try std.testing.expectEqual(@as(i64, 0), t.queueDrainsAtNs());

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("no cycle yet", try std.fmt.bufPrint(&buf, "{f}", .{t}));
}

test "presentation time is the cycle start plus the measured delay" {
    const t: Time = .{
        .now_ns = 1_000_000_000,
        .rate = 48000,
        .quantum = 480,
        .delay = 960, // two periods downstream
        .queued = 4800, // a tenth of a second queued
    };

    try std.testing.expectEqual(@as(i64, 20 * std.time.ns_per_ms), t.delayNs());
    try std.testing.expectEqual(@as(i64, 1_020_000_000), t.presentationNs());
    try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), t.queuedNs());
    try std.testing.expectEqual(@as(i64, 1_120_000_000), t.queueDrainsAtNs());
}

test "a negative delay is carried rather than clamped" {
    // `IAudioClock2` can report a position ahead of what was written when the
    // engine has already consumed a partially filled buffer. Clamping it to zero
    // would make a caller's scheduling silently early; carrying the sign lets
    // them see it.
    const t: Time = .{ .now_ns = 1_000_000_000, .rate = 48000, .delay = -480 };
    try std.testing.expectEqual(@as(i64, -10 * std.time.ns_per_ms), t.delayNs());
    try std.testing.expectEqual(@as(i64, 990_000_000), t.presentationNs());
}

test {
    std.testing.refAllDecls(@This());
}
