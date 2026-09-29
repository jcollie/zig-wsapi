// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The Win32 that is not COM: the event handle WASAPI signals, the performance
//! counter, and the scheduling class an audio thread needs.
//!
//! ```zig
//! var event: Event = try .create();
//! defer event.deinit();
//!
//! var pro_audio: ProAudio = .raise();
//! defer pro_audio.revert();
//!
//! switch (event.wait(timeout_ms)) { .signalled => {}, .timed_out => {}, .failed => {} }
//! ```
//!
//! These are wrapped rather than called directly so that the render loop reads as
//! audio code rather than as Win32 code -- and so that the two easy mistakes in it
//! are impossible to make: waiting forever, and converting the performance counter
//! in a way that overflows after half an hour of uptime.

const std = @import("std");

const errors = @import("../errors.zig");
const com = @import("com.zig");
const time = @import("../time.zig");

const log = std.log.scoped(.wasapi);

const win32 = @import("win32").everything;

/// An auto-reset event, which is what WASAPI signals when a buffer is free.
///
/// Auto-reset rather than manual: the render loop wants to be woken once per
/// buffer, and a manual-reset event would spin until it was cleared by hand.
///
/// This library also signals it itself, from `close` and from the notification
/// callbacks, to break the render thread out of its wait promptly. A spurious wake
/// costs one `GetCurrentPadding` and nothing else, which is why that is safe to do.
pub const Event = struct {
    handle: win32.HANDLE,

    pub fn create() errors.Error!Event {
        const handle = win32.CreateEventW(null, 0, 0, null) orelse {
            log.warn("CreateEventW failed: {t}", .{win32.GetLastError()});
            return error.SystemResources;
        };
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Event) void {
        _ = win32.CloseHandle(self.handle);
        self.* = undefined;
    }

    /// Wake whoever is waiting.
    ///
    /// Safe from any thread, including a COM notification callback -- it is one of
    /// the very few things such a callback is allowed to do.
    pub fn set(self: Event) void {
        _ = win32.SetEvent(self.handle);
    }

    /// Clear the event without waiting on it, for reuse across a reopen.
    pub fn reset(self: Event) void {
        _ = win32.ResetEvent(self.handle);
    }

    pub const Wake = enum {
        /// The event was signalled: there is a buffer to fill, or somebody wants
        /// the loop to look at its flags.
        signalled,
        /// Nothing happened before the timeout. For a running stream this means a
        /// cycle was missed, which is worth counting and, if it keeps happening,
        /// worth treating as the device having gone away.
        timed_out,
        /// The wait itself failed, which should not happen to a valid handle.
        failed,
    };

    /// Wait for the event, for at most `timeout_ms`.
    ///
    /// There is deliberately no way to wait forever. A device that stops signalling
    /// -- because its driver crashed, or because it was removed in a way that
    /// produced no error -- would hang the render thread, and with it `close` and
    /// the whole program's shutdown. A bounded wait turns that into a countable
    /// `missed_cycles` and a reopen.
    pub fn wait(self: Event, timeout_ms: u32) Wake {
        std.debug.assert(timeout_ms != win32.INFINITE);
        return switch (win32.WaitForSingleObject(self.handle, timeout_ms)) {
            win32.WAIT_OBJECT_0 => .signalled,
            win32.WAIT_TIMEOUT => .timed_out,
            else => |result| {
                log.warn("WaitForSingleObject returned {d}: {t}", .{
                    result,
                    win32.GetLastError(),
                });
                return .failed;
            },
        };
    }
};

/// The performance counter, as nanoseconds.
///
/// A type rather than a bare function because the frequency has to be read once
/// and kept: reading it per cycle would be a syscall in the audio path, and
/// passing it around by hand is how the wrong one ends up in a conversion.
pub const Clock = struct {
    frequency: u64,

    pub fn init() Clock {
        // `LARGE_INTEGER` is a union of a 64-bit `QuadPart` and a pair of halves,
        // which is how these two calls report a value that predates 64-bit
        // registers. `QuadPart` is the one to read.
        var frequency: win32.LARGE_INTEGER = .{ .QuadPart = 0 };
        // Documented to succeed on every system since Windows XP, so a failure
        // here means something is deeply wrong; falling back to a plausible value
        // keeps the audio playing and makes the timestamps merely wrong, which is
        // the better of the two failures.
        if (win32.QueryPerformanceFrequency(&frequency) == 0 or frequency.QuadPart <= 0) {
            log.warn("QueryPerformanceFrequency failed; timestamps will be wrong", .{});
            return .{ .frequency = 10_000_000 };
        }
        return .{ .frequency = @intCast(frequency.QuadPart) };
    }

    /// Raw ticks. For measuring a difference, where converting both ends would
    /// round twice.
    pub fn ticks(self: Clock) u64 {
        _ = self;
        var counter: win32.LARGE_INTEGER = .{ .QuadPart = 0 };
        // Cannot fail on any supported system.
        _ = win32.QueryPerformanceCounter(&counter);
        return @intCast(@max(0, counter.QuadPart));
    }

    /// Now, in nanoseconds, on the same clock `IAudioClock2` reports its positions
    /// on -- which is what makes the two comparable.
    pub fn nowNs(self: Clock) u64 {
        return time.qpcToNs(self.ticks(), self.frequency);
    }

    /// A difference in ticks, as nanoseconds.
    pub fn deltaNs(self: Clock, from_ticks: u64, to_ticks: u64) u64 {
        if (to_ticks <= from_ticks) return 0;
        return time.qpcToNs(to_ticks - from_ticks, self.frequency);
    }

    /// A duration in nanoseconds, as ticks.
    pub fn nsToTicks(self: Clock, ns: u64) u64 {
        return @intCast(@as(u128, ns) * self.frequency / std.time.ns_per_s);
    }
};

/// The "Pro Audio" scheduling class, for the render thread.
///
/// Multimedia Class Scheduler Service gives a thread a reserved share of the
/// processor and raises its priority above ordinary work, which is what keeps a
/// graph cycle from being preempted by a compiler. "Pro Audio" is the class with
/// the shortest guaranteed period of the ones Windows defines.
///
/// ## Failure is not fatal
///
/// `AvSetMmThreadCharacteristicsW` returns null in session 0, in some container
/// configurations, on Windows Server without the Desktop Experience, and if the
/// scheduler service has been disabled. None of those is a reason to refuse to
/// play audio -- the stream will simply be more prone to glitching under load --
/// so this logs and carries on.
///
/// The revert has to run on the same thread that raised, which is why this is a
/// value the render thread holds rather than a pair of free functions.
pub const ProAudio = struct {
    handle: ?win32.HANDLE,

    /// Windows' name for the class. A UTF-16 literal because that is what the W
    /// entry point takes.
    const task_name = std.unicode.utf8ToUtf16LeStringLiteral("Pro Audio");

    pub fn raise() ProAudio {
        var task_index: u32 = 0;
        const handle = win32.AvSetMmThreadCharacteristicsW(task_name, &task_index);
        if (handle == null or handle == win32.INVALID_HANDLE_VALUE) {
            log.warn(
                "AvSetMmThreadCharacteristicsW(\"Pro Audio\") failed: {t}; " ++
                    "the render thread will run at ordinary priority",
                .{win32.GetLastError()},
            );
            return .{ .handle = null };
        }
        return .{ .handle = handle };
    }

    /// Whether the thread is actually in the class. False is a working stream with
    /// less scheduling headroom, not a broken one.
    pub fn raised(self: ProAudio) bool {
        return self.handle != null;
    }

    pub fn revert(self: *ProAudio) void {
        if (self.handle) |handle| {
            if (win32.AvRevertMmThreadCharacteristics(handle) == 0) {
                log.warn("AvRevertMmThreadCharacteristics failed: {t}", .{win32.GetLastError()});
            }
        }
        self.* = undefined;
    }
};

test "an event can be created, signalled, waited on and closed" {
    var event: Event = try .create();
    defer event.deinit();

    // Auto-reset: one `set` satisfies exactly one `wait`.
    event.set();
    try std.testing.expectEqual(Event.Wake.signalled, event.wait(1000));

    // And having been consumed, the next wait times out rather than returning
    // again -- which is what makes one wake mean one buffer.
    try std.testing.expectEqual(Event.Wake.timed_out, event.wait(0));
}

test "resetting an event discards a pending signal" {
    // Used across a reopen, so that a signal from the endpoint that has gone away
    // does not make the loop think the new one is ready.
    var event: Event = try .create();
    defer event.deinit();

    event.set();
    event.reset();
    try std.testing.expectEqual(Event.Wake.timed_out, event.wait(0));
}

test "the clock advances and its frequency is plausible" {
    const clock: Clock = .init();

    // Every documented value is at least a megahertz; a frequency far below that
    // would mean the conversion is reading the wrong field.
    try std.testing.expect(clock.frequency >= 1_000_000);

    const first = clock.nowNs();
    // Enough work that the counter has to have moved, without a sleep -- this file
    // is tested on Windows where the counter is at least a megahertz, so a few
    // thousand iterations is comfortably more than one tick.
    var spin: u64 = 0;
    for (0..200_000) |i| spin +%= i;
    std.mem.doNotOptimizeAway(spin);
    const second = clock.nowNs();

    try std.testing.expect(second >= first);
    try std.testing.expect(second > 0);
}

test "a tick difference converts to a sensible duration" {
    const clock: Clock = .init();

    // One second's worth of ticks is one second's worth of nanoseconds.
    try std.testing.expectEqual(
        @as(u64, std.time.ns_per_s),
        clock.deltaNs(0, clock.frequency),
    );

    // And the inverse.
    try std.testing.expectEqual(clock.frequency, clock.nsToTicks(std.time.ns_per_s));

    // A difference that runs backwards -- which a reopen's rebased baseline can
    // produce -- is zero rather than an enormous unsigned number.
    try std.testing.expectEqual(@as(u64, 0), clock.deltaNs(1000, 500));
}

test "the scheduling class can be raised and reverted, or declined" {
    // Either outcome is a pass: what is asserted is that both paths are safe to
    // run, because a test runner may well be somewhere the class is unavailable.
    var pro_audio: ProAudio = .raise();
    if (!pro_audio.raised()) {
        std.log.warn("MMCSS declined to raise this thread; the fallback path was tested", .{});
    }
    pro_audio.revert();
}

test {
    std.testing.refAllDecls(@This());
}
