// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Turning this library's `f32` frames into whatever the endpoint wants, and
//! back.
//!
//! ```zig
//! // On the render thread, per cycle:
//! mix.permute(staging, source, wire_order, channels);
//! mix.toEndpoint(.i16, endpoint_bytes, staging);
//! ```
//!
//! ## This is the hot code
//!
//! Everything here runs inside a graph cycle, on a real-time thread, once per
//! period -- so it allocates nothing, has no error returns, and takes no locks.
//! The signatures are all "write this slice from that slice", and every function
//! asserts the lengths agree rather than returning an error, because a length
//! mismatch here is a bug in this library and not a condition to recover from.
//!
//! ## What "full scale" means
//!
//! The API's `f32` samples are nominally -1.0 to 1.0. Converting to an integer
//! format multiplies by that format's positive maximum and *clamps*, because a
//! caller who hands over 1.5 wants loud audio rather than the wraparound to
//! full-negative that an unchecked cast would produce -- a click on every sample
//! that overshoots. Clamping is two instructions and is what every other audio
//! library does.
//!
//! The asymmetry of two's complement is handled by scaling by the positive
//! maximum in both directions, so -1.0 maps to -32767 rather than -32768 for
//! `i16`. That loses one code of range and keeps the signal symmetric, which is
//! the conventional trade and the one that does not distort a full-scale sine.

const std = @import("std");

const format = @import("format.zig");
const Sample = format.Sample;

/// Convert `src` `f32` frames into `dst` bytes in the endpoint's format.
///
/// `dst` must be exactly `src.len * sample.containerBytes()` bytes. Both are
/// interleaved and already in wire order -- `permute` first if they are not.
pub fn toEndpoint(sample: Sample, dst: []u8, src: []const f32) void {
    std.debug.assert(dst.len == src.len * sample.containerBytes());
    switch (sample) {
        .f32 => {
            // The common case, and the one that is nearly free: the endpoint
            // wants exactly what this library carries. Not a `@memcpy` of the
            // slices because `dst` is bytes and is not guaranteed aligned for
            // `f32`, which a WASAPI buffer in practice always is but is not
            // promised to be.
            for (src, 0..) |v, i| {
                std.mem.writeInt(u32, dst[i * 4 ..][0..4], @bitCast(v), .little);
            }
        },
        .i16 => for (src, 0..) |v, i| {
            std.mem.writeInt(i16, dst[i * 2 ..][0..2], @intCast(scale(max_i16, v)), .little);
        },
        .i24_packed => for (src, 0..) |v, i| {
            // Three bytes, little-endian, no padding.
            const bits: u32 = @bitCast(scale(max_i24, v));
            dst[i * 3 + 0] = @truncate(bits);
            dst[i * 3 + 1] = @truncate(bits >> 8);
            dst[i * 3 + 2] = @truncate(bits >> 16);
        },
        .i24_in_32 => for (src, 0..) |v, i| {
            // Twenty-four valid bits *left-justified* in a 32-bit container,
            // which is what `wValidBitsPerSample` means. Right-justifying here
            // would play about 48 dB too quiet -- audible, and the sort of
            // mistake that gets blamed on the hardware.
            //
            // The shift cannot overflow because `scale` clamps to ±0x7FFFFF.
            std.mem.writeInt(i32, dst[i * 4 ..][0..4], scale(max_i24, v) << 8, .little);
        },
        .i32 => for (src, 0..) |v, i| {
            std.mem.writeInt(i32, dst[i * 4 ..][0..4], scale(max_i32, v), .little);
        },
    }
}

/// Convert `src` bytes in the endpoint's format into `dst` `f32` frames.
///
/// The capture direction. `src` must be exactly
/// `dst.len * sample.containerBytes()` bytes.
pub fn fromEndpoint(sample: Sample, dst: []f32, src: []const u8) void {
    std.debug.assert(src.len == dst.len * sample.containerBytes());
    switch (sample) {
        .f32 => for (dst, 0..) |*out, i| {
            out.* = @bitCast(std.mem.readInt(u32, src[i * 4 ..][0..4], .little));
        },
        .i16 => for (dst, 0..) |*out, i| {
            out.* = unscale(max_i16, std.mem.readInt(i16, src[i * 2 ..][0..2], .little));
        },
        .i24_packed => for (dst, 0..) |*out, i| {
            const b = src[i * 3 ..][0..3];
            // Sign-extend twenty-four bits: assemble them in the *top* three
            // bytes of a `u32`, reinterpret as signed, and shift back down
            // arithmetically so the sign bit propagates.
            const wide: i32 = @bitCast(@as(u32, b[0]) << 8 | @as(u32, b[1]) << 16 |
                @as(u32, b[2]) << 24);
            out.* = unscale(max_i24, wide >> 8);
        },
        .i24_in_32 => for (dst, 0..) |*out, i| {
            // Undo the left justification: the signal is the top 24 bits.
            const raw = std.mem.readInt(i32, src[i * 4 ..][0..4], .little);
            out.* = unscale(max_i24, raw >> 8);
        },
        .i32 => for (dst, 0..) |*out, i| {
            out.* = unscale(max_i32, std.mem.readInt(i32, src[i * 4 ..][0..4], .little));
        },
    }
}

/// Rearrange the channels of interleaved frames.
///
/// `order[i]` is the slot within an output frame that input channel `i` goes to,
/// which is exactly what `channel.wireOrder` produces. `dst` and `src` must be
/// the same length and a whole number of frames of `channels` samples.
///
/// The caller should skip this entirely when `channel.isWireOrdered` says the
/// layout needs no permutation, which is every conventional layout -- this exists
/// for the ones that do.
pub fn permute(dst: []f32, src: []const f32, order: []const u8, channels: u16) void {
    std.debug.assert(dst.len == src.len);
    std.debug.assert(order.len == channels);
    std.debug.assert(src.len % channels == 0);

    const frames = src.len / channels;
    for (0..frames) |f| {
        const in = src[f * channels ..][0..channels];
        const out = dst[f * channels ..][0..channels];
        for (order, 0..) |slot, ch| out[slot] = in[ch];
    }
}

/// Spread interleaved frames into one slice per channel.
///
/// What the pull-mode `Process` callback is handed: `planes[c][f]` rather than
/// `interleaved[f * channels + c]`. Every plane must be at least `frames` long.
pub fn deinterleave(planes: []const []f32, interleaved: []const f32, frames: u32) void {
    std.debug.assert(interleaved.len >= @as(usize, frames) * planes.len);
    for (planes, 0..) |plane, ch| {
        std.debug.assert(plane.len >= frames);
        for (0..frames) |f| plane[f] = interleaved[f * planes.len + ch];
    }
}

/// Gather one slice per channel back into interleaved frames.
pub fn interleave(interleaved: []f32, planes: []const []const f32, frames: u32) void {
    std.debug.assert(interleaved.len >= @as(usize, frames) * planes.len);
    for (planes, 0..) |plane, ch| {
        std.debug.assert(plane.len >= frames);
        for (0..frames) |f| interleaved[f * planes.len + ch] = plane[f];
    }
}

/// Multiply every sample by `gain`.
pub fn applyGain(samples: []f32, gain: f32) void {
    for (samples) |*s| s.* *= gain;
}

/// Fill with silence.
pub fn silence(samples: []f32) void {
    @memset(samples, 0);
}

/// Copy `src` frames into `dst` frames, changing the channel count.
///
/// Deliberately simple: extra output channels are silent and extra input channels
/// are dropped. No downmix matrix, no centre-channel folding, no `-3 dB` law --
/// because a library that quietly invents a downmix is a library whose output
/// nobody can predict, and because the audio engine's own `AUTOCONVERTPCM` does a
/// better job than a hand-rolled matrix would.
///
/// This exists for the one case `Stream` cannot avoid: an endpoint that negotiated
/// a different channel count than the caller asked for, where the alternative is
/// refusing to play at all.
pub fn remapChannels(
    dst: []f32,
    dst_channels: u16,
    src: []const f32,
    src_channels: u16,
    frames: u32,
) void {
    std.debug.assert(dst.len >= @as(usize, frames) * dst_channels);
    std.debug.assert(src.len >= @as(usize, frames) * src_channels);

    const shared = @min(dst_channels, src_channels);
    for (0..frames) |f| {
        const in = src[f * src_channels ..][0..src_channels];
        const out = dst[f * dst_channels ..][0..dst_channels];
        @memcpy(out[0..shared], in[0..shared]);
        if (dst_channels > shared) @memset(out[shared..], 0);
    }
}

/// Full scale for each integer width, as the positive maximum.
///
/// Named rather than derived from `std.math.maxInt` at each use because 24-bit
/// audio has no Zig integer type of its own: `i24_packed` and `i24_in_32` both
/// carry a value bounded by `max_i24` in a wider container, and reaching for
/// `maxInt(i32)` there is exactly the mistake that plays the audio 48 dB quiet.
const max_i16 = 32767;
const max_i24 = 8388607;
const max_i32 = 2147483647;

/// Scale an `f32` in -1.0 to 1.0 to an integer bounded by ±`max`, clamping.
///
/// ## Why the bounds are checked before the cast and not after
///
/// The obvious spelling -- `@intFromFloat(clamp(v * max, -max, max))` -- has a
/// bug that only appears at 32 bits. `max_i32` is 2147483647, which `f32` cannot
/// represent: converting it to `f32` rounds *up* to 2147483648. So the clamp's
/// upper bound is one greater than the largest `i32`, a full-scale sample passes
/// through it unchanged, and `@intFromFloat` then traps -- "integer part of
/// floating point value out of bounds" -- on exactly the input an audio stream
/// hits constantly.
///
/// Comparing first and returning the integer bound directly avoids it: the cast
/// only ever sees a value strictly inside the range. NaN fails both comparisons
/// and is mapped to silence, because the alternative is undefined behaviour on a
/// real-time thread and a caller who produced a NaN has a worse problem than one
/// silent sample.
fn scale(comptime max: comptime_int, v: f32) i32 {
    const max_f: f32 = @floatFromInt(max);
    if (v >= 1.0) return max;
    if (v <= -1.0) return -max;
    if (std.math.isNan(v)) return 0;
    // `@round` rather than truncation, which would bias every sample towards
    // zero and show up as distortion on quiet material.
    return @intFromFloat(@round(v * max_f));
}

/// The inverse of `scale`.
fn unscale(comptime max: comptime_int, v: i32) f32 {
    const max_f: f32 = @floatFromInt(max);
    return @as(f32, @floatFromInt(v)) / max_f;
}

test "float to f32 is the identity, bit for bit" {
    // Including the awkward values: a conversion that went through an integer
    // anywhere would lose these.
    const src = [_]f32{ 0.0, 1.0, -1.0, 0.5, -0.5, 1.0e-30, 3.5, -7.25 };
    var bytes: [src.len * 4]u8 = undefined;
    toEndpoint(.f32, &bytes, &src);

    var back: [src.len]f32 = undefined;
    fromEndpoint(.f32, &back, &bytes);
    try std.testing.expectEqualSlices(f32, &src, &back);
}

test "full scale maps to full scale, symmetrically" {
    var bytes: [2 * 2]u8 = undefined;
    toEndpoint(.i16, &bytes, &.{ 1.0, -1.0 });
    try std.testing.expectEqual(
        @as(i16, 32767),
        std.mem.readInt(i16, bytes[0..2], .little),
    );
    // -32767 rather than -32768: scaling by the positive maximum in both
    // directions keeps a full-scale sine symmetric, at the cost of one code.
    try std.testing.expectEqual(
        @as(i16, -32767),
        std.mem.readInt(i16, bytes[2..4], .little),
    );
}

test "overshoot clamps instead of wrapping" {
    // The bug this is here to prevent: an unclamped cast of 1.5 wraps to a large
    // negative number, so every sample that overshoots becomes a click.
    var bytes: [4 * 2]u8 = undefined;
    toEndpoint(.i16, &bytes, &.{ 1.5, -1.5, 100.0, -100.0 });

    try std.testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, bytes[0..2], .little));
    try std.testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, bytes[2..4], .little));
    try std.testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, bytes[4..6], .little));
    try std.testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, bytes[6..8], .little));
}

test "an integer round trip is accurate to that format's resolution" {
    const src = [_]f32{ 0.0, 1.0, -1.0, 0.5, -0.5, 0.25, -0.75, 0.001 };

    inline for (.{
        .{ Sample.i16, 1.0 / 32767.0 },
        .{ Sample.i32, 1.0 / 2147483647.0 },
        .{ Sample.i24_packed, 1.0 / 8388607.0 },
        .{ Sample.i24_in_32, 1.0 / 8388607.0 },
    }) |case| {
        const sample: Sample = case[0];
        const tolerance: f32 = case[1] * 2;

        var bytes: [src.len * 4]u8 = undefined;
        const used = bytes[0 .. src.len * sample.containerBytes()];
        toEndpoint(sample, used, &src);

        var back: [src.len]f32 = undefined;
        fromEndpoint(sample, &back, used);

        for (src, back) |want, got| {
            try std.testing.expectApproxEqAbs(want, got, tolerance);
        }
    }
}

test "24 valid bits in 32 is left-justified, not right-justified" {
    // The distinction that decides whether the audio plays at the right level or
    // about 48 dB too quiet. `wValidBitsPerSample` means the signal occupies the
    // *top* 24 bits of the container.
    var bytes: [4]u8 = undefined;
    toEndpoint(.i24_in_32, &bytes, &.{1.0});
    const raw = std.mem.readInt(i32, bytes[0..4], .little);

    // Full scale must be near the top of the 32-bit range, with only the low
    // byte cleared -- not near 8388607, which is what right-justifying gives.
    try std.testing.expect(raw > 0x7F00_0000);
    try std.testing.expectEqual(@as(i32, 0), raw & 0xFF);
}

test "packed 24-bit occupies exactly three bytes per sample" {
    var bytes: [2 * 3]u8 = undefined;
    toEndpoint(.i24_packed, &bytes, &.{ 1.0, -1.0 });

    // Full positive is 0x7FFFFF little-endian; full negative is its negation,
    // 0x800001, rather than 0x800000 -- the conversion is symmetric.
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0x7F }, bytes[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x80 }, bytes[3..6]);
}

test "silence converts to the right kind of zero in every format" {
    // A conversion with a sign or offset error shows up here as a constant, which
    // in an audio stream is a thump at the start and a raised noise floor after.
    inline for (.{ Sample.f32, Sample.i16, Sample.i24_packed, Sample.i24_in_32, Sample.i32 }) |s| {
        var bytes: [4 * 4]u8 = undefined;
        const used = bytes[0 .. 4 * s.containerBytes()];
        toEndpoint(s, used, &.{ 0, 0, 0, 0 });
        for (used) |b| try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "a permutation moves channels where the wire order says" {
    // Two frames of a layout whose caller order is FL FR SL SR FLC FRC and whose
    // wire order puts the front-of-centre pair before the sides. Taken from the
    // worked example in `channel.zig`.
    const channel = @import("channel.zig");
    const map = [_]channel.Channel{ .fl, .fr, .fc, .lfe, .sl, .sr, .flc, .frc };

    var order_buf: [channel.max_channels]u8 = undefined;
    const order = try channel.wireOrder(&map, &order_buf);

    // Frame values are the caller's channel index, so where each lands is visible.
    const src = [_]f32{ 0, 1, 2, 3, 4, 5, 6, 7 } ++ [_]f32{ 10, 11, 12, 13, 14, 15, 16, 17 };
    var dst: [src.len]f32 = @splat(-1);
    permute(&dst, &src, order, 8);

    // Caller channels 4 and 5 (the sides) land in slots 6 and 7; channels 6 and 7
    // (front of centre) land in slots 4 and 5.
    try std.testing.expectEqualSlices(f32, &.{ 0, 1, 2, 3, 6, 7, 4, 5 }, dst[0..8]);
    try std.testing.expectEqualSlices(f32, &.{ 10, 11, 12, 13, 16, 17, 14, 15 }, dst[8..16]);
}

test "the identity permutation leaves frames alone" {
    const src = [_]f32{ 1, 2, 3, 4, 5, 6 };
    var dst: [src.len]f32 = @splat(-1);
    permute(&dst, &src, &.{ 0, 1 }, 2);
    try std.testing.expectEqualSlices(f32, &src, &dst);
}

test "interleaving and deinterleaving are inverses" {
    const interleaved = [_]f32{ 1, 10, 2, 20, 3, 30, 4, 40 }; // four stereo frames
    var left: [4]f32 = undefined;
    var right: [4]f32 = undefined;

    const planes = [_][]f32{ &left, &right };
    deinterleave(&planes, &interleaved, 4);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, &left);
    try std.testing.expectEqualSlices(f32, &.{ 10, 20, 30, 40 }, &right);

    var back: [8]f32 = @splat(-1);
    const const_planes = [_][]const f32{ &left, &right };
    interleave(&back, &const_planes, 4);
    try std.testing.expectEqualSlices(f32, &interleaved, &back);
}

test "a shorter frame than the planes hold converts only what was asked for" {
    // The render loop hands the callback a bounded frame count that is usually
    // smaller than the scratch it allocated, so this is the normal case.
    const interleaved = [_]f32{ 1, 10, 2, 20, 3, 30, 4, 40 };
    var left: [4]f32 = @splat(-1);
    var right: [4]f32 = @splat(-1);
    const planes = [_][]f32{ &left, &right };

    deinterleave(&planes, &interleaved, 2);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, -1, -1 }, &left);
    try std.testing.expectEqualSlices(f32, &.{ 10, 20, -1, -1 }, &right);
}

test "extra output channels are silent and extra input channels are dropped" {
    // Stated plainly rather than matrixed: this is the behaviour documented on
    // `remapChannels`, and a test is how it stays that rather than drifting into
    // an accidental downmix.
    const stereo = [_]f32{ 1, 2, 3, 4 }; // two frames
    var six: [12]f32 = @splat(-1);
    remapChannels(&six, 6, &stereo, 2, 2);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 0, 0, 0, 0 }, six[0..6]);
    try std.testing.expectEqualSlices(f32, &.{ 3, 4, 0, 0, 0, 0 }, six[6..12]);

    const surround = [_]f32{ 1, 2, 3, 4, 5, 6 }; // one 5.1 frame
    var down: [2]f32 = @splat(-1);
    remapChannels(&down, 2, &surround, 6, 1);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2 }, &down);
}

test "gain scales and silence clears" {
    var samples = [_]f32{ 1, -1, 0.5, 0.25 };
    applyGain(&samples, 0.5);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, -0.5, 0.25, 0.125 }, &samples);

    silence(&samples);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &samples);
}

test "a full-scale sine survives an i16 round trip without visible distortion" {
    // The end-to-end property that the individual conversions add up to: a
    // full-scale sine is the signal that finds clipping, sign errors and biased
    // rounding, and it is what a listener would notice.
    const n = 480;
    var sine: [n]f32 = undefined;
    for (&sine, 0..) |*s, i| {
        const phase = @as(f32, @floatFromInt(i)) / @as(f32, n) * 2.0 * std.math.pi;
        s.* = @sin(phase);
    }

    var bytes: [n * 2]u8 = undefined;
    toEndpoint(.i16, &bytes, &sine);
    var back: [n]f32 = undefined;
    fromEndpoint(.i16, &back, &bytes);

    // Error stays within one code of the format everywhere -- no clipping at the
    // peaks, no sign flip through zero.
    var worst: f32 = 0;
    for (sine, back) |want, got| worst = @max(worst, @abs(want - got));
    try std.testing.expect(worst < 2.0 / 32767.0);
}

test {
    std.testing.refAllDecls(@This());
}
