// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The queue between a program writing audio and the thread playing it.
//!
//! ```zig
//! var ring: Ring = try .init(gpa, 16384, 2);
//! defer ring.deinit(gpa);
//!
//! _ = ring.push(interleaved_frames);      // on the caller's thread
//! _ = ring.popOrSilence(render_buffer);   // on the render thread
//! ```
//!
//! ## Exactly one writer and exactly one reader
//!
//! `push` is only ever called from the thread that owns the `Stream`, and `pop`
//! only ever from that stream's render thread. That is what makes this lock-free
//! without a compare-and-swap anywhere: the writer owns `head` and the reader
//! owns `tail`, each publishes its own index with a release store, and each reads
//! the other's with an acquire load. Nothing else is shared.
//!
//! Two writers would corrupt it silently. The single-writer rule is a real
//! constraint on the public API and is documented on `Stream.write`; a program
//! that wants to produce audio from several threads has to combine them itself
//! before writing.
//!
//! The reader is a real-time thread, so `pop` and `popOrSilence` allocate
//! nothing, take no lock, and never fail. The worst a starved reader does is play
//! silence and say how much, which is what `popOrSilence` returns.
//!
//! ## Frames, not samples
//!
//! Everything here counts *frames*: one sample for each channel. A ring of 16384
//! frames at 48 kHz holds a third of a second whether the stream is mono or 7.1,
//! which is the unit a caller reasons about latency in. Samples only appear
//! inside the slices.
//!
//! ## Free-running indices
//!
//! `head` and `tail` count frames written and read since the beginning and are
//! never reduced modulo the capacity; the masking happens only when indexing the
//! storage. So `head - tail` is the occupancy with no ambiguity between full and
//! empty, which is the bug every ring buffer written the other way has. They are
//! `u32` and wrap after four thousand million frames -- about twenty-four hours
//! at 48 kHz -- and wrapping subtraction gives the right answer across that
//! boundary, which the test at the bottom of this file checks rather than
//! assumes.

const Ring = @This();

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The samples, `capacity_frames * channels` of them.
storage: []f32,
/// Frames the storage holds. Always a power of two.
capacity_frames: u32,
/// Samples in a frame.
channels: u16,
/// Frames written since the beginning. Owned by the writing thread.
head: std.atomic.Value(u32),
/// Frames read since the beginning. Owned by the reading thread.
tail: std.atomic.Value(u32),

/// The smallest ring this library will make.
///
/// A ring that one graph cycle can drain entirely is a ring the producer can
/// never stay ahead of: it would underrun every time the writer was late by one
/// cycle, which under any scheduler is often. Four thousand frames is a
/// comfortable multiple of the largest period WASAPI hands out in shared mode.
pub const min_frames = 1024;

/// A ring with no storage, for a stream that does not know its channel count yet.
///
/// A capture stream cannot size its queue until the endpoint has said how many
/// channels it delivers, which does not happen until the capture thread has
/// negotiated. This is what the field holds until then: every accessor answers zero,
/// `push` and `pop` do nothing, and `deinit` is safe -- so the window between opening
/// and negotiating needs no special case anywhere.
pub const empty: Ring = .{
    .storage = &.{},
    .capacity_frames = 0,
    // One rather than zero, because `push` and `pop` divide by it. With no capacity
    // they both do nothing regardless.
    .channels = 1,
    .head = .init(0),
    .tail = .init(0),
};

/// Allocate a ring holding at least `frames` frames.
///
/// The capacity is rounded *up* to a power of two, so `capacity()` may be larger
/// than asked for -- which is worth knowing because `writable()` will then also
/// be larger than expected. Rounding up rather than down because a caller asking
/// for a third of a second of slack should not quietly get a sixth.
pub fn init(gpa: Allocator, frames: u32, channels: u16) Allocator.Error!Ring {
    std.debug.assert(channels > 0);
    const frames_capacity = std.math.ceilPowerOfTwoAssert(u32, @max(frames, min_frames));
    return .{
        .storage = try gpa.alloc(f32, @as(usize, frames_capacity) * channels),
        .capacity_frames = frames_capacity,
        .channels = channels,
        .head = .init(0),
        .tail = .init(0),
    };
}

pub fn deinit(self: *Ring, gpa: Allocator) void {
    // Tolerates `empty`, whose storage is a zero-length literal rather than an
    // allocation.
    if (self.storage.len != 0) gpa.free(self.storage);
    self.* = undefined;
}

/// Frames the ring holds when full.
pub fn capacity(self: *const Ring) u32 {
    return self.capacity_frames;
}

/// Frames written but not yet read.
///
/// Safe from either thread. From a third thread it is a snapshot that was true
/// at some point during the call, which is all any answer could be.
pub fn queued(self: *const Ring) u32 {
    const head = self.head.load(.acquire);
    const tail = self.tail.load(.acquire);
    return head -% tail;
}

/// Frames `push` would accept right now.
pub fn writable(self: *const Ring) u32 {
    return self.capacity_frames - self.queued();
}

/// Whether there is nothing left to play.
pub fn isEmpty(self: *const Ring) bool {
    return self.queued() == 0;
}

/// Queue interleaved frames. Returns how many whole frames were taken, which is
/// fewer than offered when the ring is full. Never blocks and never fails.
///
/// For the writing thread only. A partial `interleaved` -- a length that is not a
/// whole number of frames -- has its remainder ignored rather than being written
/// as a torn frame, because half a frame in a ring would shift every channel of
/// everything after it.
pub fn push(self: *Ring, interleaved: []const f32) u32 {
    const offered: u32 = @intCast(interleaved.len / self.channels);
    if (offered == 0) return 0;

    // Only this thread writes `head`, so a relaxed load of our own index is
    // enough; `tail` is the other thread's and needs the acquire.
    const head = self.head.load(.monotonic);
    const tail = self.tail.load(.acquire);
    const room = self.capacity_frames - (head -% tail);
    const frames = @min(offered, room);
    if (frames == 0) return 0;

    const start = head & (self.capacity_frames - 1);
    const first = @min(frames, self.capacity_frames - start);
    const ch = self.channels;

    @memcpy(
        self.storage[@as(usize, start) * ch ..][0 .. @as(usize, first) * ch],
        interleaved[0 .. @as(usize, first) * ch],
    );
    if (frames > first) {
        // Wrapped: the rest goes at the beginning of the storage.
        const rest = frames - first;
        @memcpy(
            self.storage[0 .. @as(usize, rest) * ch],
            interleaved[@as(usize, first) * ch ..][0 .. @as(usize, rest) * ch],
        );
    }

    // Release, so that the samples above are visible to the reader before the
    // index that says they are there.
    self.head.store(head +% frames, .release);
    return frames;
}

/// Take up to `out.len / channels` frames. Returns how many whole frames were
/// written into `out`; the rest of `out` is untouched.
///
/// For the reading thread only.
pub fn pop(self: *Ring, out: []f32) u32 {
    const wanted: u32 = @intCast(out.len / self.channels);
    if (wanted == 0) return 0;

    const tail = self.tail.load(.monotonic);
    const head = self.head.load(.acquire);
    const available = head -% tail;
    const frames = @min(wanted, available);
    if (frames == 0) return 0;

    const start = tail & (self.capacity_frames - 1);
    const first = @min(frames, self.capacity_frames - start);
    const ch = self.channels;

    @memcpy(
        out[0 .. @as(usize, first) * ch],
        self.storage[@as(usize, start) * ch ..][0 .. @as(usize, first) * ch],
    );
    if (frames > first) {
        const rest = frames - first;
        @memcpy(
            out[@as(usize, first) * ch ..][0 .. @as(usize, rest) * ch],
            self.storage[0 .. @as(usize, rest) * ch],
        );
    }

    self.tail.store(tail +% frames, .release);
    return frames;
}

/// Fill `out` completely, with silence for whatever the ring could not supply.
/// Returns the number of frames of silence that had to be invented.
///
/// This is what the render loop calls, because a graph cycle has to be filled
/// whether or not the producer kept up -- and filling the shortfall with zeroes
/// is what makes an underrun a moment of quiet rather than a repeat of whatever
/// was in the buffer before.
pub fn popOrSilence(self: *Ring, out: []f32) u32 {
    const wanted: u32 = @intCast(out.len / self.channels);
    const got = self.pop(out);
    if (got == wanted) return 0;
    @memset(out[@as(usize, got) * self.channels ..], 0);
    return wanted - got;
}

/// Throw away everything queued.
///
/// Only safe when no reader is running -- between a `Stop` and a `Start`, which
/// is the one moment `Stream` uses it. Called while the render thread is reading,
/// it would move `tail` under the reader's feet.
pub fn reset(self: *Ring) void {
    self.tail.store(self.head.load(.acquire), .release);
}

test "a fresh ring is empty and entirely writable" {
    var ring: Ring = try .init(std.testing.allocator, 4096, 2);
    defer ring.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 4096), ring.capacity());
    try std.testing.expectEqual(@as(u32, 0), ring.queued());
    try std.testing.expectEqual(@as(u32, 4096), ring.writable());
    try std.testing.expect(ring.isEmpty());
}

test "a capacity is rounded up to a power of two, never down" {
    // Rounding down would quietly give a caller less slack than they asked for,
    // which they would eventually notice as underruns and have no way to explain.
    var ring: Ring = try .init(std.testing.allocator, 5000, 2);
    defer ring.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 8192), ring.capacity());

    // And a request below the floor is raised to it, because a ring one cycle can
    // drain is not usable.
    var tiny: Ring = try .init(std.testing.allocator, 1, 2);
    defer tiny.deinit(std.testing.allocator);
    try std.testing.expectEqual(min_frames, tiny.capacity());
}

test "what is pushed is what is popped, in order" {
    var ring: Ring = try .init(std.testing.allocator, 1024, 2);
    defer ring.deinit(std.testing.allocator);

    const written = [_]f32{ 1, 2, 3, 4, 5, 6 }; // three stereo frames
    try std.testing.expectEqual(@as(u32, 3), ring.push(&written));
    try std.testing.expectEqual(@as(u32, 3), ring.queued());

    var read: [6]f32 = @splat(0);
    try std.testing.expectEqual(@as(u32, 3), ring.pop(&read));
    try std.testing.expectEqualSlices(f32, &written, &read);
    try std.testing.expect(ring.isEmpty());
}

test "a full ring takes what it can and reports how much" {
    var ring: Ring = try .init(std.testing.allocator, min_frames, 1);
    defer ring.deinit(std.testing.allocator);

    const plenty = [_]f32{1} ** (min_frames + 500);
    try std.testing.expectEqual(min_frames, ring.push(&plenty));
    try std.testing.expectEqual(@as(u32, 0), ring.writable());

    // And a push into a full ring takes nothing rather than overwriting.
    try std.testing.expectEqual(@as(u32, 0), ring.push(&plenty));
    try std.testing.expectEqual(min_frames, ring.queued());
}

test "an empty ring pops nothing rather than stale samples" {
    var ring: Ring = try .init(std.testing.allocator, 1024, 2);
    defer ring.deinit(std.testing.allocator);

    _ = ring.push(&.{ 1, 2 });
    var out: [2]f32 = @splat(0);
    try std.testing.expectEqual(@as(u32, 1), ring.pop(&out));

    // The sample is still physically in the storage; popping again must not
    // return it.
    out = @splat(-1);
    try std.testing.expectEqual(@as(u32, 0), ring.pop(&out));
    try std.testing.expectEqualSlices(f32, &.{ -1, -1 }, &out);
}

test "a partial frame is ignored rather than torn" {
    // Writing half a frame would shift every channel of everything after it, so
    // one speaker would play the other's audio from then on.
    var ring: Ring = try .init(std.testing.allocator, 1024, 2);
    defer ring.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), ring.push(&.{ 1, 2, 3 }));
    try std.testing.expectEqual(@as(u32, 1), ring.queued());

    var out: [2]f32 = @splat(0);
    _ = ring.pop(&out);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2 }, &out);
}

test "writing across the wraparound preserves order" {
    // The case that a ring written with modulo indices gets wrong: a block that
    // starts near the end of the storage and continues at the beginning.
    var ring: Ring = try .init(std.testing.allocator, min_frames, 1);
    defer ring.deinit(std.testing.allocator);

    // Advance the indices most of the way round, so the next write must wrap.
    const filler = [_]f32{0} ** (min_frames - 3);
    _ = ring.push(&filler);
    var sink: [min_frames - 3]f32 = undefined;
    _ = ring.pop(&sink);
    try std.testing.expect(ring.isEmpty());

    const across = [_]f32{ 10, 20, 30, 40, 50, 60 };
    try std.testing.expectEqual(@as(u32, 6), ring.push(&across));

    var out: [6]f32 = @splat(0);
    try std.testing.expectEqual(@as(u32, 6), ring.pop(&out));
    try std.testing.expectEqualSlices(f32, &across, &out);
}

test "a shortfall becomes silence, and is counted" {
    // What the render loop relies on: the cycle is always filled, and the amount
    // invented is reported so `Stream.underruns` can be honest about it.
    var ring: Ring = try .init(std.testing.allocator, 1024, 2);
    defer ring.deinit(std.testing.allocator);

    _ = ring.push(&.{ 1, 1, 2, 2 }); // two frames

    var out: [10]f32 = @splat(-1); // five frames wanted
    try std.testing.expectEqual(@as(u32, 3), ring.popOrSilence(&out));
    try std.testing.expectEqualSlices(f32, &.{ 1, 1, 2, 2, 0, 0, 0, 0, 0, 0 }, &out);
}

test "a completely starved ring yields a whole cycle of silence" {
    var ring: Ring = try .init(std.testing.allocator, 1024, 2);
    defer ring.deinit(std.testing.allocator);

    var out: [8]f32 = @splat(-1);
    try std.testing.expectEqual(@as(u32, 4), ring.popOrSilence(&out));
    try std.testing.expectEqualSlices(f32, &(.{0} ** 8), &out);
}

test "reset drops what is queued without disturbing the accounting" {
    var ring: Ring = try .init(std.testing.allocator, 1024, 2);
    defer ring.deinit(std.testing.allocator);

    _ = ring.push(&.{ 1, 2, 3, 4, 5, 6 });
    try std.testing.expectEqual(@as(u32, 3), ring.queued());

    ring.reset();
    try std.testing.expect(ring.isEmpty());
    try std.testing.expectEqual(ring.capacity(), ring.writable());

    // And it is usable afterwards.
    try std.testing.expectEqual(@as(u32, 1), ring.push(&.{ 7, 8 }));
}

test "the occupancy is right across the point where the indices wrap" {
    // `head` and `tail` are `u32` counting frames since the beginning, so they
    // wrap after about a day at 48 kHz. Wrapping subtraction gives the right
    // occupancy across that boundary -- but only if every arithmetic operator on
    // them is the wrapping one, which is easy to get wrong and impossible to
    // notice in a test that does not reach the boundary. This reaches it.
    var ring: Ring = try .init(std.testing.allocator, 1024, 1);
    defer ring.deinit(std.testing.allocator);

    // Park both indices just short of wrapping, consistently with each other.
    ring.head.store(std.math.maxInt(u32) - 2, .release);
    ring.tail.store(std.math.maxInt(u32) - 2, .release);
    try std.testing.expect(ring.isEmpty());

    // Now push across the boundary: two frames before it, three after.
    try std.testing.expectEqual(@as(u32, 5), ring.push(&.{ 1, 2, 3, 4, 5 }));
    try std.testing.expectEqual(@as(u32, 5), ring.queued());
    try std.testing.expectEqual(@as(u32, 1019), ring.writable());

    var out: [5]f32 = @splat(0);
    try std.testing.expectEqual(@as(u32, 5), ring.pop(&out));
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4, 5 }, &out);
    try std.testing.expect(ring.isEmpty());
}

test "a producer and a consumer on two threads lose nothing and invent nothing" {
    // The property that matters and that no single-threaded test can show: with
    // one writer and one reader running genuinely concurrently, every sample
    // comes out exactly once and in order. The samples are a counter, so a
    // duplicate or a gap is visible immediately.
    const total_frames = 200_000;

    var ring: Ring = try .init(std.testing.allocator, 2048, 1);
    defer ring.deinit(std.testing.allocator);

    const Producer = struct {
        fn run(r: *Ring) void {
            var next: u32 = 0;
            while (next < total_frames) {
                // A batch that is deliberately not a divisor of the capacity, so
                // the wraparound lands at a different offset each time round.
                var batch: [37]f32 = undefined;
                const n: u32 = @min(@as(u32, batch.len), total_frames - next);
                for (0..n) |i| batch[i] = @floatFromInt(next + @as(u32, @intCast(i)));

                var pushed: u32 = 0;
                while (pushed < n) {
                    const took = r.push(batch[pushed..n]);
                    if (took == 0) std.Thread.yield() catch {};
                    pushed += took;
                }
                next += n;
            }
        }
    };

    const producer = try std.Thread.spawn(.{}, Producer.run, .{&ring});

    var expected: u32 = 0;
    var out: [53]f32 = undefined; // also deliberately coprime with the capacity
    while (expected < total_frames) {
        const got = ring.pop(&out);
        if (got == 0) {
            std.Thread.yield() catch {};
            continue;
        }
        for (out[0..got]) |sample| {
            try std.testing.expectEqual(@as(f32, @floatFromInt(expected)), sample);
            expected += 1;
        }
    }

    producer.join();
    try std.testing.expectEqual(@as(u32, total_frames), expected);
    try std.testing.expect(ring.isEmpty());
}

test {
    std.testing.refAllDecls(@This());
}
