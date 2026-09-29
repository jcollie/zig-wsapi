// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The one place this library waits for the render thread.
//!
//! ```zig
//! try wait.until(io, timeout, stream, isStreaming, .{ .max_ns = period_ns / 4 });
//! ```
//!
//! ## Why this polls, which is the question a reader will have
//!
//! The render thread is a raw `std.Thread` blocked in `WaitForSingleObject` on the
//! event handle WASAPI signals. It publishes what it is doing through atomics and
//! never touches a `std.Io` primitive. So the caller's side cannot be woken by it
//! -- it has to look.
//!
//! That is forced rather than preferred, for three separate reasons:
//!
//!   * **`std.Io` cannot express the wait.** `std.Io.Operation` in 0.16 is exactly
//!     file reads, file writes, device I/O control and network receives. There is
//!     no operation that waits on a Windows event `HANDLE`, and no vtable entry
//!     that could be adapted into one. The render thread therefore cannot be an
//!     `Io` task at all.
//!   * **Waking an `Io` from a foreign thread is not safe in general.** `Io.Event.set`
//!     and `Io.Condition.signal` go through the implementation's `futexWake`, and a
//!     fiber-based implementation's version reaches for the current task -- which,
//!     on an OS thread that implementation never created, is not a defined thing.
//!     It happens that `std.Io.Evented` is `void` on Windows in 0.16, so today the
//!     only implementation there is `Io.Threaded`, whose `futexWake` would be fine.
//!     A library should not encode that.
//!   * **The priority has to stay on our thread.** `AvSetMmThreadCharacteristicsW`
//!     raises a *thread* into the "Pro Audio" scheduling class, and
//!     `AvRevertMmThreadCharacteristics` has to run on the same thread. On a pooled
//!     `Io` worker the raise would outlive the stream and there would be no thread
//!     to reliably revert on.
//!
//! None of the three waits here is in the audio path -- they are a program starting
//! up, a program applying backpressure, and a program shutting down -- so a
//! sub-millisecond poll costs nothing that matters. `Options.wake` exists for an
//! embedder who knows their `Io` is safe to wake from a foreign thread and would
//! rather not poll at all.
//!
//! ## The shape of the wait
//!
//! Short first, then doubling to a cap derived from the graph period. A `write`
//! that just missed a cycle should return as soon as the cycle lands, so the first
//! slice is a quarter of a millisecond; a long backpressure wait should be nearly
//! free, so the cap is a quarter of a period, giving at most four wakeups per
//! period. A fixed slice would be wrong at one end or the other.
//!
//! `io.sleep` is itself a cancellation point, so there is exactly one
//! `io.checkCancel` -- before the first sleep, so that a zero timeout on an
//! unready predicate still honours cancellation rather than reporting a timeout.

const std = @import("std");

/// Whether the thing being waited for has happened.
///
/// Three values rather than a `bool`, and the third one is the important one: a
/// stream that has given up will never become ready, so a predicate that could
/// only say "not yet" would make `writeAll` with no timeout wait forever on a
/// stream whose device is gone. Every predicate in this library reports `.failed`
/// for that, and every wait turns it into `error.StreamFailed`.
pub const Ready = enum {
    /// Stop waiting; the wait succeeded.
    yes,
    /// Not yet. Keep waiting.
    no,
    /// It will never happen. Stop waiting and report it.
    failed,
};

/// What a wait can end with.
pub const Error = error{
    /// The deadline passed.
    Timeout,
    /// The stream failed while waiting: the endpoint went away and either it was
    /// told not to follow the default, or no replacement could be found.
    StreamFailed,
} || std.Io.Cancelable;

/// How often to look.
pub const Params = struct {
    /// The first gap. Short, so that something which has almost happened is
    /// noticed almost immediately.
    first_ns: u64 = 250 * std.time.ns_per_us,

    /// The longest gap. Derive it from the graph period -- a quarter of one is a
    /// good default -- so that the polling rate follows the thing being polled.
    max_ns: u64 = 2 * std.time.ns_per_ms,
};

/// Wait until `ready(ctx)` says so, or `timeout` passes.
///
/// `ready` is `comptime` so that the predicate inlines and this costs an atomic
/// load per look rather than an indirect call.
pub fn until(
    io: std.Io,
    timeout: std.Io.Timeout,
    ctx: anytype,
    comptime ready: fn (@TypeOf(ctx)) Ready,
    params: Params,
) Error!void {
    // Resolved once, at the top: a `Timeout.duration` measured afresh each time
    // round would restart the clock on every look and never expire.
    const deadline = timeout.toDeadline(io);

    // The only explicit cancellation check. `io.sleep` is a cancellation point in
    // its own right, so checking again in the loop body would be redundant -- but
    // without this one, a caller who cancelled before a call with an already-passed
    // deadline would get `error.Timeout` instead of `error.Canceled`.
    try io.checkCancel();

    var slice_ns = params.first_ns;
    while (true) {
        switch (ready(ctx)) {
            .yes => return,
            .failed => return error.StreamFailed,
            .no => {},
        }

        const sleep_ns = blk: {
            const left = deadline.toDurationFromNow(io) orelse break :blk slice_ns;
            const left_ns = left.raw.toNanoseconds();
            if (left_ns <= 0) return error.Timeout;
            // Never overshoot the deadline: the last slice is whatever is left.
            break :blk @min(slice_ns, @as(u64, @intCast(left_ns)));
        };

        try io.sleep(.fromNanoseconds(@intCast(sleep_ns)), .awake);

        slice_ns = @min(slice_ns * 2, params.max_ns);
    }
}

/// `Params` for a wait on a stream whose period is known.
///
/// A quarter of a period, floored at a quarter of a millisecond and capped at two
/// milliseconds -- so an unusually long period does not make shutdown feel slow and
/// an unusually short one does not spin.
pub fn paramsForPeriod(period_ns: u64) Params {
    const quarter = if (period_ns == 0) 2 * std.time.ns_per_ms else period_ns / 4;
    return .{
        .first_ns = 250 * std.time.ns_per_us,
        .max_ns = std.math.clamp(
            quarter,
            250 * std.time.ns_per_us,
            2 * std.time.ns_per_ms,
        ),
    };
}

/// A test double for a predicate driven by a plain flag.
///
/// Counts how many times it was asked, which is what lets the tests below assert
/// that a wait really polled -- without any clock, and so without depending on how
/// a loaded machine schedules them.
const Flag = struct {
    state: std.atomic.Value(u8),
    looks: std.atomic.Value(u32) = .init(0),

    const not_yet: u8 = 0;
    const done: u8 = 1;
    const broken: u8 = 2;

    fn init(value: u8) Flag {
        return .{ .state = .init(value) };
    }

    fn check(self: *Flag) Ready {
        _ = self.looks.fetchAdd(1, .monotonic);
        return switch (self.state.load(.acquire)) {
            done => .yes,
            broken => .failed,
            else => .no,
        };
    }
};

/// How long a block of code took, on the monotonic clock, in nanoseconds.
///
/// Through `Io` rather than `std.time.Timer`, which 0.16 removed -- and which this
/// file could not have used anyway, since it must compile on any host as part of
/// `portable.zig`.
fn elapsedNs(io: std.Io, from: std.Io.Clock.Timestamp) u64 {
    const to: std.Io.Clock.Timestamp = .now(io, .awake);
    return @intCast(@max(0, from.durationTo(to).raw.toNanoseconds()));
}

test "a predicate that is already satisfied returns without sleeping" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var flag: Flag = .init(Flag.done);
    // `Timeout.none` would wait forever if this looked before returning, so this
    // also pins down that the predicate is checked first.
    try until(io, .none, &flag, Flag.check, .{});
}

test "a predicate that never becomes true times out" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var flag: Flag = .init(Flag.not_yet);
    try std.testing.expectError(error.Timeout, until(
        io,
        .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } },
        &flag,
        Flag.check,
        .{},
    ));
}

test "a failed stream is reported rather than waited on forever" {
    // The rule that matters most in this file: without the `.failed` arm, this
    // call would hang -- a stream whose device is gone never becomes ready, and
    // the timeout is `none`.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var flag: Flag = .init(Flag.broken);
    try std.testing.expectError(error.StreamFailed, until(io, .none, &flag, Flag.check, .{}));
}

test "a wait notices a foreign thread flipping the flag" {
    // The whole design in one test: the render thread is a raw OS thread that
    // cannot wake this wait, so the wait has to notice by looking.
    //
    // The other thread waits until the predicate has been asked three times before
    // answering, so this asserts the polling actually happened -- and it does so
    // without a clock, which keeps it from being flaky on a loaded machine.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var flag: Flag = .init(Flag.not_yet);

    const Setter = struct {
        fn run(f: *Flag) void {
            while (f.looks.load(.acquire) < 3) std.atomic.spinLoopHint();
            f.state.store(Flag.done, .release);
        }
    };
    const setter = try std.Thread.spawn(.{}, Setter.run, .{&flag});
    defer setter.join();

    try until(
        io,
        .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
        &flag,
        Flag.check,
        .{},
    );

    // It cannot have returned on the first look, because the flag was not set
    // until the fourth.
    try std.testing.expect(flag.looks.load(.acquire) >= 4);
}

test "a deadline is not overshot by the last slice" {
    // The slice is clamped to the time remaining, so a wait with a short deadline
    // and a much longer slice still returns near the deadline rather than a whole
    // slice past it. Without the clamp this would take at least 50 ms.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var flag: Flag = .init(Flag.not_yet);
    const started: std.Io.Clock.Timestamp = .now(io, .awake);

    try std.testing.expectError(error.Timeout, until(
        io,
        .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } },
        &flag,
        Flag.check,
        .{ .first_ns = 50 * std.time.ns_per_ms, .max_ns = 100 * std.time.ns_per_ms },
    ));

    const elapsed_ns = elapsedNs(io, started);
    // Generous at the top end: the assertion that matters is that it is nowhere
    // near the 50 ms an unclamped first slice would have taken.
    try std.testing.expect(elapsed_ns < 40 * std.time.ns_per_ms);
}

test "the polling schedule follows the graph period" {
    // A short period polls more often, a long one less, and both stay inside the
    // floor and the cap -- so neither a 2 ms period spins nor a 100 ms period
    // makes shutdown feel slow.
    const fast = paramsForPeriod(2 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 500 * std.time.ns_per_us), fast.max_ns);

    const slow = paramsForPeriod(100 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_ms), slow.max_ns);

    // An unknown period -- before the first cycle -- still gives something usable
    // rather than a zero slice that would spin.
    const unknown = paramsForPeriod(0);
    try std.testing.expect(unknown.max_ns > 0);
    try std.testing.expect(unknown.first_ns > 0);
}

test {
    std.testing.refAllDecls(@This());
}
