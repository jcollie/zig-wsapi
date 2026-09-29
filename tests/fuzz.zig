// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Fuzz targets for the parts that take input this library did not write.
//!
//! ```sh
//! zig build fuzz          # run each target once, as an ordinary test
//! zig build fuzz --fuzz   # actually fuzz them -- Linux or macOS only, see below
//! ```
//!
//! ## Where these can be fuzzed
//!
//! Zig 0.16 answers `--fuzz` on Windows with "not yet implemented for windows", so the
//! machine that can *run* this library is not the machine that can fuzz it.
//!
//! That is survivable only because every target here is in the operating-system-
//! independent half -- they import `wasapi-portable`, not `wasapi` -- so they build and
//! fuzz on a Linux runner, which is where the Forgejo workflow lives. Had the
//! `WAVEFORMATEX` decoder been written against `zigwin32`'s structures instead of against
//! bytes, it could not be fuzzed at all on any machine, which is one more reason
//! `format.zig` is shaped the way it is.
//!
//! Without `--fuzz` these still run as ordinary tests: each gets its corpus and a short
//! deterministic pass, which is worth having in continuous integration even where nobody
//! is fuzzing.
//!
//! ## What is worth fuzzing here, and what is not
//!
//! Exactly one thing in this library parses bytes it did not produce:
//! `format.decode`, which reads whatever `IAudioClient::GetMixFormat` hands back.
//! That structure is variable-length, its length field is supplied by the driver,
//! and a decoder that trusts it reads off the end of the allocation. It is the
//! only place in the library where a third party's bytes decide how far a read
//! goes, so it is the target that matters most.
//!
//! The rest is fuzzed because the inputs are cheap to generate and the invariants
//! are easy to state: a channel mask is an arbitrary 32-bit word from a driver, a
//! ring buffer sees an arbitrary interleaving of pushes and pops, and the sample
//! converters see whatever floats a caller produced -- including infinities and
//! NaN, which an audio program generates more often than anybody would like.
//!
//! Nothing that calls COM is fuzzed. A fuzzer cannot drive WASAPI, and a target
//! that opened an audio device a million times would test Windows rather than
//! this library.

const std = @import("std");
const portable = @import("wasapi-portable");

const channel = portable.channel;
const format = portable.format;
const mix = portable.mix;
const Ring = portable.Ring;

test "format.decode never reads past the bytes it was given" {
    // The target that justifies the file. `decode` is handed a pointer and a length
    // derived from the driver's own `cbSize`, and every field it reads past byte 18
    // is conditional on numbers the driver chose.
    try std.testing.fuzz({}, fuzzDecode, .{
        // Seeds: the shapes real drivers produce, so the fuzzer starts from valid
        // input and mutates outwards rather than spending its first million runs
        // discovering that a `wFormatTag` exists.
        .corpus = &.{ &seed_stereo_f32, &seed_stereo_i16, &seed_surround_f32, &seed_hires },
    });
}

/// Valid encodings, for the corpus.
///
/// Built at comptime by the encoder itself rather than written out as byte literals, so
/// that a change to the encoding cannot leave the seeds describing a format the library
/// no longer produces. The slice `encodeExtensible` returns is discarded and the array
/// returned by value: a pointer into comptime storage cannot escape to runtime.
const seed_stereo_f32 = encodedAtComptime(.{ .rate = 48000, .channels = 2, .sample = .f32 });
const seed_stereo_i16 = encodedAtComptime(.{ .rate = 44100, .channels = 2, .sample = .i16 });
const seed_surround_f32 = encodedAtComptime(.{ .rate = 48000, .channels = 6, .sample = .f32 });
const seed_hires = encodedAtComptime(.{ .rate = 96000, .channels = 2, .sample = .i24_in_32 });

fn encodedAtComptime(comptime fmt: format.Format) [format.extensible_len]u8 {
    comptime {
        var buffer: [format.extensible_len]u8 = undefined;
        _ = fmt.encodeExtensible(&buffer);
        return buffer;
    }
}

fn fuzzDecode(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [128]u8 = undefined;
    const len = smith.slice(&buffer);
    const bytes = buffer[0..len];

    const decoded = format.Format.decode(bytes) catch return;

    // Anything that decoded has to be usable: the arithmetic built on it runs on a
    // real-time thread, where a zero rate is a division by zero and a channel count
    // past the maximum is a buffer overrun.
    try std.testing.expect(decoded.rate > 0);
    try std.testing.expect(decoded.channels > 0);
    try std.testing.expect(decoded.channels <= channel.max_channels);
    try std.testing.expect(decoded.blockAlign() > 0);
    try std.testing.expect(decoded.avgBytesPerSec() > 0);

    // And it has to survive a round trip through the encoder, because that is what
    // the reopen path does with it: a format that decodes but cannot be re-encoded
    // would fail only when a device was unplugged.
    var again: [format.extensible_len]u8 align(8) = undefined;
    const re_decoded = try format.Format.decode(decoded.encodeExtensible(&again));
    try std.testing.expectEqual(decoded.rate, re_decoded.rate);
    try std.testing.expectEqual(decoded.channels, re_decoded.channels);
    try std.testing.expectEqual(decoded.sample, re_decoded.sample);
}

test "any channel mask decodes to a layout that is in wire order" {
    // `dwChannelMask` is a 32-bit word from a driver, including bits this library has
    // no name for and combinations no speaker arrangement has.
    try std.testing.fuzz({}, fuzzChannelMask, .{});
}

fn fuzzChannelMask(_: void, smith: *std.testing.Smith) anyerror!void {
    const mask = smith.value(u32);

    var buffer: [channel.max_channels]channel.Channel = undefined;
    const map = channel.mapFromMask(mask, &buffer) catch return;

    // The invariant every consumer relies on: what comes out of a mask is already in
    // the order the samples arrive in, so no permutation is needed.
    try std.testing.expect(channel.isWireOrdered(map));

    // No duplicates, so the mask it implies has as many bits as the layout has
    // channels -- which is what keeps `wireOrder` a permutation.
    try channel.validate(map);
    try std.testing.expectEqual(@as(usize, @popCount(channel.maskFor(map))), map.len);

    // And every position named is one the original mask actually contained.
    try std.testing.expectEqual(@as(u32, 0), channel.maskFor(map) & ~mask);

    // The permutation is total: every slot used exactly once.
    var order_buffer: [channel.max_channels]u8 = undefined;
    const order = try channel.wireOrder(map, &order_buffer);
    var used: u32 = 0;
    for (order) |slot| {
        try std.testing.expect(slot < map.len);
        const bit = @as(u32, 1) << @intCast(slot);
        try std.testing.expectEqual(@as(u32, 0), used & bit);
        used |= bit;
    }
}

test "a ring never loses or invents a frame, whatever order it is used in" {
    try std.testing.fuzz({}, fuzzRing, .{});
}

fn fuzzRing(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;

    const channels = smith.valueRangeAtMost(u16, 1, 4);
    var ring: Ring = try .init(gpa, Ring.min_frames, channels);
    defer ring.deinit(gpa);

    // A counter through the ring: what is popped must be exactly what was pushed, in
    // order, with nothing repeated and nothing skipped.
    var next_pushed: f32 = 0;
    var next_popped: f32 = 0;

    var scratch: [64 * 4]f32 = undefined;

    const Action = enum { push, pop, pop_or_silence, reset };

    while (!smith.eosWeightedSimple(20, 1)) {
        switch (smith.value(Action)) {
            .push => {
                const frames = smith.valueRangeAtMost(u32, 0, 64);
                const samples = @as(usize, frames) * channels;
                for (0..samples) |i| scratch[i] = next_pushed + @as(f32, @floatFromInt(i));
                const taken = ring.push(scratch[0..samples]);
                try std.testing.expect(taken <= frames);
                next_pushed += @floatFromInt(@as(usize, taken) * channels);
            },
            .pop => {
                const frames = smith.valueRangeAtMost(u32, 0, 64);
                const samples = @as(usize, frames) * channels;
                const got = ring.pop(scratch[0..samples]);
                try std.testing.expect(got <= frames);
                for (0..@as(usize, got) * channels) |i| {
                    try std.testing.expectEqual(next_popped, scratch[i]);
                    next_popped += 1;
                }
            },
            .pop_or_silence => {
                const frames = smith.valueRangeAtMost(u32, 0, 64);
                const samples = @as(usize, frames) * channels;
                const short = ring.popOrSilence(scratch[0..samples]);
                try std.testing.expect(short <= frames);
                const real = frames - short;
                for (0..@as(usize, real) * channels) |i| {
                    try std.testing.expectEqual(next_popped, scratch[i]);
                    next_popped += 1;
                }
                // The invented part is silence, not stale samples.
                for (scratch[@as(usize, real) * channels .. samples]) |sample| {
                    try std.testing.expectEqual(@as(f32, 0), sample);
                }
            },
            .reset => {
                ring.reset();
                // Everything unread is gone, so the reader's expectation has to jump
                // to wherever the writer had got to.
                next_popped = next_pushed;
            },
        }

        // The accounting invariant, checked after every operation.
        try std.testing.expectEqual(ring.capacity(), ring.queued() + ring.writable());
        try std.testing.expect(ring.queued() <= ring.capacity());
    }
}

test "the sample converters survive any float, including the ones nobody means to send" {
    try std.testing.fuzz({}, fuzzConvert, .{});
}

fn fuzzConvert(_: void, smith: *std.testing.Smith) anyerror!void {
    var samples: [64]f32 = undefined;
    const count: usize = smith.valueRangeAtMost(u32, 1, @intCast(samples.len));
    for (samples[0..count]) |*sample| sample.* = @bitCast(smith.value(u32));

    const source = samples[0..count];

    inline for (.{
        format.Sample.f32,
        format.Sample.i16,
        format.Sample.i24_packed,
        format.Sample.i24_in_32,
        format.Sample.i32,
    }) |sample_type| {
        var bytes: [samples.len * 4]u8 = undefined;
        const used = bytes[0 .. count * sample_type.containerBytes()];

        // The property that matters: an arbitrary float -- including an infinity, a
        // NaN, or a value far outside full scale, all of which a caller's own
        // arithmetic produces -- must convert without trapping. An unchecked cast
        // here would be undefined behaviour on a real-time thread.
        mix.toEndpoint(sample_type, used, source);

        var back: [samples.len]f32 = undefined;
        mix.fromEndpoint(sample_type, back[0..count], used);

        // And what comes back is always a usable sample, never a NaN that would
        // propagate through every later mix. The float format is exempt: it is a
        // verbatim copy by design, so a NaN in is a NaN out.
        if (sample_type != .f32) {
            for (back[0..count]) |sample| {
                try std.testing.expect(!std.math.isNan(sample));
                try std.testing.expect(sample >= -1.0001 and sample <= 1.0001);
            }
        }
    }
}
