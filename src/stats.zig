// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What the graph cycles have cost, and how the render thread reports it without
//! ever waiting for a reader.
//!
//! ```zig
//! const s = stream.stats();
//! std.debug.print("busy {d}% of the period, {d} underrun frames\n", .{
//!     s.process.fractionOfPeriod(s.period_ns) * 100,
//!     s.underrun_frames,
//! });
//! ```
//!
//! ## Min, mean and max rather than a histogram
//!
//! The number that decides whether a stream is safe is the *worst* cycle, not the
//! typical one. Audio has a deadline: a cycle that takes longer than the period
//! is a dropout, and it does not matter that the other nine hundred were quick.
//! So each metric is kept as its minimum, its mean and its maximum, which is what
//! `pw-top` shows and what a person actually looks at.
//!
//! ## The reader never blocks the render thread
//!
//! `Stats` is produced by a real-time thread and consumed by whatever thread asks.
//! A mutex would be wrong in the only direction that matters -- a reader
//! descheduled while holding it would stall a graph cycle -- so the handoff is a
//! sequence lock: the writer publishes between two increments of a counter, and a
//! reader that sees the counter change under it simply reads again.
//!
//! That makes the writer wait-free: it never spins, never blocks, and costs two
//! atomic stores per cycle. It makes the reader retry occasionally, which is free
//! because no reader is in the audio path. This is the opposite trade to
//! zig-pipewire's `volume()`, which takes the lock the data thread holds for a
//! whole cycle; doing it this way means `stats()` is safe to call from anywhere,
//! including from inside a `Process` callback.

const std = @import("std");

/// One metric's spread over the cycles since the last reset.
pub const Summary = struct {
    min_ns: u64 = 0,
    mean_ns: u64 = 0,
    max_ns: u64 = 0,

    /// This metric as a fraction of the cycle period.
    ///
    /// The form `pw-top` reports and the one that says whether there is headroom:
    /// a `process` maximum at 0.9 of the period is a stream about to glitch,
    /// whatever its mean says. Zero when the period is not yet known.
    pub fn fractionOfPeriod(self: Summary, period_ns: u64) f64 {
        if (period_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.max_ns)) / @as(f64, @floatFromInt(period_ns));
    }

    pub fn format(self: Summary, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}/{d}/{d} us", .{
            self.min_ns / std.time.ns_per_us,
            self.mean_ns / std.time.ns_per_us,
            self.max_ns / std.time.ns_per_us,
        });
    }
};

/// What the cycles since the last `resetStats` have cost.
pub const Stats = struct {
    /// Cycles processed since the last reset.
    cycles: u64 = 0,

    /// How far the render thread's wakeup drifted from an ideal cycle boundary.
    ///
    /// **Not** the same quantity as PipeWire's WAIT, and the difference is worth
    /// knowing. PipeWire gets a timestamp from the driver saying when the node was
    /// marked ready, and subtracts. WASAPI provides no such timestamp -- there is
    /// only the event handle becoming signalled -- so this is measured against a
    /// line that advances by one period per cycle and is rebased whenever the
    /// stream starts. It is a good measure of jitter and a poor measure of
    /// absolute scheduling latency, and it should be read as the former.
    wake: Summary = .{},

    /// Time spent inside the cycle producing audio: `pw-top` calls this BUSY.
    ///
    /// A true analogue of PipeWire's figure, from the same two timestamps around
    /// the same work, so the two can be compared directly.
    process: Summary = .{},

    /// How long a cycle lasts at the current rate and period. Both figures above
    /// have to fit inside this, together with every other client's.
    period_ns: u64 = 0,

    /// Cycles the render thread believes it missed.
    ///
    /// **Inferred**, not reported: WASAPI has no glitch counter, so this counts
    /// the times the wait timed out and the times the wake was more than a full
    /// period late. A non-zero value means the thread was not scheduled in time;
    /// the exact number is a symptom rather than a measurement.
    missed_cycles: u64 = 0,

    /// Frames of silence the render thread had to invent because the ring was
    /// short.
    ///
    /// Exact, and the number that usually matters: it is the audible consequence
    /// of everything above. Counted from the first write.
    underrun_frames: u64 = 0,

    /// Times the stream moved itself to another endpoint and carried on.
    ///
    /// Has no PipeWire counterpart, because PipeWire moves a node without the
    /// client knowing. A count that climbs while nobody is unplugging anything is
    /// worth investigating. See `Stream.Options.follow_default`.
    reopens: u64 = 0,

    pub fn format(self: Stats, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} cycles, period {d} us, wake {f}, busy {f}", .{
            self.cycles,
            self.period_ns / std.time.ns_per_us,
            self.wake,
            self.process,
        });
        if (self.missed_cycles != 0) try w.print(", {d} missed", .{self.missed_cycles});
        if (self.underrun_frames != 0) {
            try w.print(", {d} underrun frames", .{self.underrun_frames});
        }
        if (self.reopens != 0) try w.print(", {d} reopens", .{self.reopens});
    }
};

/// The render thread's private running totals.
///
/// Not shared: the render thread owns this outright and folds each cycle into it,
/// then publishes a snapshot through a `Cell`. Keeping the accumulation private is
/// what lets it be plain arithmetic with no atomics in the hot path.
pub const Accumulator = struct {
    cycles: u64 = 0,
    wake: Running = .{},
    process: Running = .{},
    period_ns: u64 = 0,
    missed_cycles: u64 = 0,
    underrun_frames: u64 = 0,
    reopens: u64 = 0,

    /// Sum and extremes for one metric. The mean is computed on the way out
    /// rather than maintained, so accumulating is two comparisons and an add.
    pub const Running = struct {
        min_ns: u64 = std.math.maxInt(u64),
        max_ns: u64 = 0,
        total_ns: u64 = 0,
        count: u64 = 0,

        pub fn add(self: *Running, ns: u64) void {
            self.min_ns = @min(self.min_ns, ns);
            self.max_ns = @max(self.max_ns, ns);
            // Saturating, because a stream left running for weeks should report a
            // slightly wrong mean rather than wrap to nonsense -- or, in a safe
            // build, trap on a real-time thread.
            self.total_ns +|= ns;
            self.count +|= 1;
        }

        pub fn summary(self: Running) Summary {
            if (self.count == 0) return .{};
            return .{
                .min_ns = self.min_ns,
                .mean_ns = self.total_ns / self.count,
                .max_ns = self.max_ns,
            };
        }
    };

    /// Fold one completed cycle in.
    pub fn record(self: *Accumulator, wake_ns: u64, process_ns: u64) void {
        self.cycles +|= 1;
        self.wake.add(wake_ns);
        self.process.add(process_ns);
    }

    /// What a reader should see.
    pub fn snapshot(self: *const Accumulator) Stats {
        return .{
            .cycles = self.cycles,
            .wake = self.wake.summary(),
            .process = self.process.summary(),
            .period_ns = self.period_ns,
            .missed_cycles = self.missed_cycles,
            .underrun_frames = self.underrun_frames,
            .reopens = self.reopens,
        };
    }

    /// Start the measurement window again, keeping the counters that describe the
    /// stream rather than the window.
    ///
    /// `period_ns` and `reopens` survive: the first is a property of the stream as
    /// it is now, and the second is a count of things that happened to it that a
    /// caller resetting a benchmark window did not mean to forget. Everything else
    /// goes, which is the point -- a benchmark wants to exclude the cycles spent
    /// starting up.
    pub fn reset(self: *Accumulator) void {
        self.* = .{ .period_ns = self.period_ns, .reopens = self.reopens };
    }
};

/// A `Stats` that one thread publishes and any number read, without a lock.
///
/// ## How it works, and why it is not a sequence lock
///
/// The obvious construction is a sequence lock: mark the value in flux, write it,
/// mark it settled. That needs a barrier *between* the odd marker and the payload
/// write -- a release store keeps earlier writes from moving after it, but not
/// later writes from moving before it -- and Zig 0.16 removed `@fence`, which was
/// the way to ask for one.
///
/// So the value is published into a small ring of slots instead. The writer fills
/// the next slot and then advertises it with one release store; that single store
/// is enough, because a release store is exactly the guarantee that everything
/// written before it is visible to a reader whose acquire load sees it. A reader
/// takes the counter, copies that slot, and takes the counter again to check it was
/// not overtaken.
///
/// The slot count is what makes the check sufficient. With `slots` places, the
/// writer does not touch the slot a reader is copying until it has published
/// `slots` more times -- four whole graph cycles, tens of milliseconds -- so a
/// reader copying seventy-odd bytes cannot be overtaken mid-copy in any realistic
/// scheduling. The recheck then catches the unrealistic case and retries.
///
/// The writer is wait-free either way: two atomic operations and a struct copy per
/// cycle, no spinning, no blocking, and nothing a reader can do to delay it. That
/// is the requirement -- the writer is a real-time thread -- and it is why
/// `Stream.stats` is safe to call from anywhere, including from inside a `Process`
/// callback.
pub fn Published(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Publications since the beginning. The low bits pick the slot.
        seq: std.atomic.Value(u32) = .init(0),
        slots: [slot_count]T = @splat(.{}),

        /// Enough that a reader copying one slot cannot be overtaken by a writer
        /// coming round again: at one publication per graph cycle that is four
        /// cycles, tens of milliseconds. A power of two so the index is a mask.
        pub const slot_count = 4;

        /// Publish. For the render thread only, and only one thread ever.
        pub fn store(self: *Self, value: T) void {
            // Only this thread writes `seq`, so reading our own counter needs no
            // ordering.
            const seq = self.seq.load(.monotonic);
            const next = seq +% 1;

            // Written before it is advertised, and into a slot no reader can be
            // looking at yet, because nothing has pointed them here.
            self.slots[next & (slot_count - 1)] = value;

            // The one barrier that matters: everything above is visible to any
            // reader whose acquire load sees this value.
            self.seq.store(next, .release);
        }

        /// Read the most recent published value.
        pub fn load(self: *const Self) T {
            while (true) {
                const before = self.seq.load(.acquire);
                const copy = self.slots[before & (slot_count - 1)];

                // Unchanged means the writer has not come round to this slot
                // again, so the copy is of one consistent publication.
                if (self.seq.load(.acquire) == before) return copy;

                std.atomic.spinLoopHint();
            }
        }
    };
}

/// The cell a `Stream` publishes its statistics through.
pub const Cell = Published(Stats);

test "an empty summary is zeroes rather than the sentinel minimum" {
    // `Running` starts its minimum at the largest `u64` so the first sample wins.
    // If that leaked out, a stream that had not run a cycle yet would report a
    // minimum of eighteen quintillion nanoseconds.
    const running: Accumulator.Running = .{};
    const summary = running.summary();
    try std.testing.expectEqual(@as(u64, 0), summary.min_ns);
    try std.testing.expectEqual(@as(u64, 0), summary.mean_ns);
    try std.testing.expectEqual(@as(u64, 0), summary.max_ns);
}

test "a summary reports the extremes and the mean" {
    var running: Accumulator.Running = .{};
    for ([_]u64{ 300, 100, 200, 400 }) |ns| running.add(ns);

    const summary = running.summary();
    try std.testing.expectEqual(@as(u64, 100), summary.min_ns);
    try std.testing.expectEqual(@as(u64, 250), summary.mean_ns);
    try std.testing.expectEqual(@as(u64, 400), summary.max_ns);
}

test "the fraction of the period is taken from the worst cycle, not the mean" {
    // The whole point of reporting a maximum: a stream whose mean is comfortable
    // and whose worst cycle is over the deadline is a stream that glitches, and
    // the fraction has to say so.
    var running: Accumulator.Running = .{};
    for ([_]u64{ 100, 100, 100, 9000 }) |ns| running.add(ns);

    const summary = running.summary();
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.9),
        summary.fractionOfPeriod(10_000),
        0.0001,
    );

    // And an unknown period is zero rather than a division by it.
    try std.testing.expectEqual(@as(f64, 0), summary.fractionOfPeriod(0));
}

test "recording a cycle advances both metrics and the count" {
    var acc: Accumulator = .{ .period_ns = 10_000_000 };
    acc.record(1_000, 500_000);
    acc.record(3_000, 700_000);

    const stats = acc.snapshot();
    try std.testing.expectEqual(@as(u64, 2), stats.cycles);
    try std.testing.expectEqual(@as(u64, 1_000), stats.wake.min_ns);
    try std.testing.expectEqual(@as(u64, 3_000), stats.wake.max_ns);
    try std.testing.expectEqual(@as(u64, 600_000), stats.process.mean_ns);
    try std.testing.expectEqual(@as(u64, 10_000_000), stats.period_ns);
}

test "a reset clears the window but keeps what describes the stream" {
    // A benchmark resetting to exclude start-up cycles did not mean to forget that
    // the device was swapped underneath it, nor to forget how long a cycle is.
    var acc: Accumulator = .{ .period_ns = 10_000_000 };
    acc.record(1_000, 500_000);
    acc.underrun_frames = 480;
    acc.missed_cycles = 2;
    acc.reopens = 1;

    acc.reset();
    const stats = acc.snapshot();

    try std.testing.expectEqual(@as(u64, 0), stats.cycles);
    try std.testing.expectEqual(@as(u64, 0), stats.underrun_frames);
    try std.testing.expectEqual(@as(u64, 0), stats.missed_cycles);
    try std.testing.expectEqual(@as(u64, 0), stats.wake.max_ns);

    try std.testing.expectEqual(@as(u64, 10_000_000), stats.period_ns);
    try std.testing.expectEqual(@as(u64, 1), stats.reopens);
}

test "a cell hands back what was put in it" {
    var cell: Cell = .{};
    try std.testing.expectEqual(@as(u64, 0), cell.load().cycles);

    cell.store(.{ .cycles = 42, .period_ns = 10_000_000 });
    const got = cell.load();
    try std.testing.expectEqual(@as(u64, 42), got.cycles);
    try std.testing.expectEqual(@as(u64, 10_000_000), got.period_ns);
}

test "a reader never observes a torn snapshot" {
    // The property the sequence lock exists for. The writer publishes snapshots
    // whose fields are all derived from one counter, so any reader that saw a
    // half-written value would see fields that disagree with each other -- which
    // is exactly what is asserted here, across a hundred thousand publications
    // from a genuinely concurrent thread.
    const rounds = 100_000;

    var cell: Cell = .{};
    var stop: std.atomic.Value(bool) = .init(false);

    const Writer = struct {
        fn run(c: *Cell, done: *std.atomic.Value(bool)) void {
            var i: u64 = 1;
            while (i <= rounds) : (i += 1) {
                // Every field a fixed multiple of `i`, so a torn read is visible
                // as an inconsistency rather than merely as a stale value.
                c.store(.{
                    .cycles = i,
                    .period_ns = i * 2,
                    .missed_cycles = i * 3,
                    .underrun_frames = i * 4,
                    .reopens = i * 5,
                    .wake = .{ .min_ns = i, .mean_ns = i, .max_ns = i },
                    .process = .{ .min_ns = i * 6, .mean_ns = i * 6, .max_ns = i * 6 },
                });
            }
            done.store(true, .release);
        }
    };

    const writer = try std.Thread.spawn(.{}, Writer.run, .{ &cell, &stop });

    var reads: u64 = 0;
    while (!stop.load(.acquire)) {
        const s = cell.load();
        reads += 1;
        if (s.cycles == 0) continue; // nothing published yet
        try std.testing.expectEqual(s.cycles * 2, s.period_ns);
        try std.testing.expectEqual(s.cycles * 3, s.missed_cycles);
        try std.testing.expectEqual(s.cycles * 4, s.underrun_frames);
        try std.testing.expectEqual(s.cycles * 5, s.reopens);
        try std.testing.expectEqual(s.cycles, s.wake.max_ns);
        try std.testing.expectEqual(s.cycles * 6, s.process.max_ns);
    }

    writer.join();
    try std.testing.expect(reads > 0);

    // And the last value published is the one that is there afterwards.
    try std.testing.expectEqual(@as(u64, rounds), cell.load().cycles);
}

test "stats print as a line worth logging" {
    var buf: [256]u8 = undefined;
    const quiet: Stats = .{
        .cycles = 1000,
        .period_ns = 10_000_000,
        .wake = .{ .min_ns = 1_000, .mean_ns = 2_000, .max_ns = 5_000 },
        .process = .{ .min_ns = 100_000, .mean_ns = 150_000, .max_ns = 300_000 },
    };
    try std.testing.expectEqualStrings(
        "1000 cycles, period 10000 us, wake 1/2/5 us, busy 100/150/300 us",
        try std.fmt.bufPrint(&buf, "{f}", .{quiet}),
    );

    // The troubled ones only appear when they are non-zero, so a healthy stream's
    // line stays short enough to read.
    const troubled: Stats = .{ .cycles = 1, .underrun_frames = 480, .reopens = 2 };
    const line = try std.fmt.bufPrint(&buf, "{f}", .{troubled});
    try std.testing.expect(std.mem.indexOf(u8, line, "480 underrun frames") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "2 reopens") != null);
}

test {
    std.testing.refAllDecls(@This());
}
