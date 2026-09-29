// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Which speaker a channel comes out of, and what order the samples of a frame
//! go in.
//!
//! ```zig
//! const map = channel.defaultChannelMap(6).?;      // 5.1
//! const mask = channel.maskFor(map);               // 0x3F
//!
//! var order: [channel.max_channels]u8 = undefined;
//! const wire = try channel.wireOrder(map, &order); // where each channel lands
//! ```
//!
//! ## The order is the whole problem
//!
//! A `WAVEFORMATEXTENSIBLE` does not say what order its channels are in. It
//! gives a `dwChannelMask` -- a set of speaker positions -- and the samples of
//! each frame are then required to be in **ascending bit order** of that mask.
//! So the layout is implied by the *numeric values* of the `SPEAKER_*` bits, and
//! a caller's channel map is not the wire order unless it happens to be sorted
//! the same way.
//!
//! For the common layouts it does happen to be sorted the same way, which is
//! the trap: stereo, quad, 5.1 and 7.1 all come out identical whether you sort
//! by mask or take the conventional order as given, so code that assumes they
//! are the same passes every test anybody bothers to write. It stops being true
//! the moment an endpoint reports `SPEAKER_FRONT_LEFT_OF_CENTER` (0x40) or
//! `SPEAKER_BACK_CENTER` (0x100), both of which sort *before*
//! `SPEAKER_SIDE_LEFT` (0x200) in the mask and *after* the side channels in the
//! conventional ordering this library inherited from zig-pipewire.
//!
//! So `wireOrder` computes the permutation every time rather than assuming, and
//! there is a test below for exactly the two layouts where the assumption
//! breaks. Getting this wrong puts audio in the wrong speaker, which is a bug a
//! listener notices and a test suite usually does not.
//!
//! ## Why the bit values are written out here
//!
//! This file is part of the half of the library with no operating system in it,
//! so that the permutation logic can be tested on any host -- see
//! `portable.zig`. That means it cannot import `zigwin32` to get the `SPEAKER_*`
//! constants, so the numbers from `ksmedia.h` are written out below. They are
//! fixed by two decades of binary compatibility and are not going to move, and a
//! test in `com/missing.zig` asserts each one against `zigwin32`'s own
//! definition, so a typo here fails to compile the Windows build rather than
//! quietly misordering somebody's surround sound.

const std = @import("std");

/// The most channels this library will carry.
///
/// Twelve, because that is how many speaker positions a `dwChannelMask` names,
/// and a channel this library cannot name a position for is a channel it cannot
/// tell Windows where to send. WASAPI itself permits more in principle; nothing
/// that plays through the shared mixer uses them.
pub const max_channels = 12;

/// A speaker position.
///
/// The set and the order are zig-pipewire's, so that a program ported between
/// the two libraries does not have to rewrite its channel maps. The order here
/// is the *conventional* one that audio people write layouts in; it is
/// deliberately **not** the wire order -- see this file's overview, and use
/// `wireOrder` when the wire order is what is wanted.
pub const Channel = enum {
    /// The single channel of a mono stream.
    ///
    /// Windows has no distinct mono position: `KSAUDIO_SPEAKER_MONO` *is*
    /// `SPEAKER_FRONT_CENTER`, so this and `fc` share a mask bit. They are still
    /// two names because they mean different things to a caller -- one is "this
    /// stream is not stereo", the other is "this is the centre channel of a
    /// surround layout" -- and `maskFor` gives the same answer for both.
    mono,
    /// Front left.
    fl,
    /// Front right.
    fr,
    /// Front centre.
    fc,
    /// Low-frequency effects: the subwoofer.
    lfe,
    /// Rear left. Windows calls this position `SPEAKER_BACK_LEFT`.
    rl,
    /// Rear right. Windows calls this position `SPEAKER_BACK_RIGHT`.
    rr,
    /// Side left.
    sl,
    /// Side right.
    sr,
    /// Front left of centre.
    flc,
    /// Front right of centre.
    frc,
    /// Rear centre. Windows calls this position `SPEAKER_BACK_CENTER`.
    rc,

    /// The `SPEAKER_*` bit for this position.
    ///
    /// The numbers are from `ksmedia.h`; see this file's overview for why they
    /// are written out rather than imported.
    pub fn mask(self: Channel) u32 {
        return switch (self) {
            // SPEAKER_FRONT_CENTER, which is what mono is on Windows.
            .mono, .fc => 0x4,
            .fl => 0x1, // SPEAKER_FRONT_LEFT
            .fr => 0x2, // SPEAKER_FRONT_RIGHT
            .lfe => 0x8, // SPEAKER_LOW_FREQUENCY
            .rl => 0x10, // SPEAKER_BACK_LEFT
            .rr => 0x20, // SPEAKER_BACK_RIGHT
            .flc => 0x40, // SPEAKER_FRONT_LEFT_OF_CENTER
            .frc => 0x80, // SPEAKER_FRONT_RIGHT_OF_CENTER
            .rc => 0x100, // SPEAKER_BACK_CENTER
            .sl => 0x200, // SPEAKER_SIDE_LEFT
            .sr => 0x400, // SPEAKER_SIDE_RIGHT
        };
    }

    /// The position a `SPEAKER_*` bit names, or null for a bit this library has
    /// no name for.
    ///
    /// `0x4` comes back as `fc` rather than `mono`: within a mask there is no
    /// way to tell them apart, and `fc` is the answer that is right for every
    /// layout with more than one channel. A one-channel stream's map is built by
    /// `defaultChannelMap` rather than by decoding a mask, so nothing needs the
    /// other answer.
    pub fn fromMask(bit: u32) ?Channel {
        return switch (bit) {
            0x1 => .fl,
            0x2 => .fr,
            0x4 => .fc,
            0x8 => .lfe,
            0x10 => .rl,
            0x20 => .rr,
            0x40 => .flc,
            0x80 => .frc,
            0x100 => .rc,
            0x200 => .sl,
            0x400 => .sr,
            else => null,
        };
    }

    /// The short name audio tools print, in the spelling Windows uses for the
    /// positions where the two differ -- so that a listing from this library can
    /// be compared with one from `ksmedia.h` without a translation table.
    pub fn name(self: Channel) []const u8 {
        return switch (self) {
            .mono => "MONO",
            .fl => "FL",
            .fr => "FR",
            .fc => "FC",
            .lfe => "LFE",
            .rl => "BL",
            .rr => "BR",
            .sl => "SL",
            .sr => "SR",
            .flc => "FLC",
            .frc => "FRC",
            .rc => "BC",
        };
    }

    pub fn format(self: Channel, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.name());
    }
};

/// What can be wrong with a channel map.
pub const MapError = error{
    /// Two entries name the same speaker. `dwChannelMask` is a *set*, so a
    /// duplicate cannot be expressed at all -- the mask would have fewer bits
    /// set than the stream has channels, and Windows would reject the format or,
    /// worse, accept it and interleave differently than intended.
    DuplicateChannel,

    /// `mono` appears alongside another channel. Mono is `SPEAKER_FRONT_CENTER`,
    /// so a map of `{ mono, fl }` is really `{ fc, fl }` with the centre channel
    /// written first -- almost certainly not what the caller meant, and silently
    /// treating it as that would hide the mistake.
    MonoWithOthers,

    /// More entries than `max_channels`.
    TooManyChannels,
};

/// The conventional layout for a channel count, or null when there is no
/// convention for it.
///
/// Defined for 1, 2, 4, 6 and 8 channels, which are the layouts Windows has
/// `KSAUDIO_SPEAKER_*` constants for and the ones a sound card actually reports.
/// Any other count needs an explicit map, because there is no sensible guess:
/// three channels could be `{fl, fr, fc}` or `{fl, fr, lfe}`, and choosing one
/// silently would put a caller's bass in their centre speaker.
pub fn defaultChannelMap(channels: u32) ?[]const Channel {
    return switch (channels) {
        1 => &.{.mono},
        2 => &.{ .fl, .fr },
        // KSAUDIO_SPEAKER_QUAD.
        4 => &.{ .fl, .fr, .rl, .rr },
        // KSAUDIO_SPEAKER_5POINT1, the "back" spelling rather than the
        // "surround" one: this is the layout with rear speakers, which is what
        // 5.1 means to everything that is not a soundbar.
        6 => &.{ .fl, .fr, .fc, .lfe, .rl, .rr },
        // KSAUDIO_SPEAKER_7POINT1_SURROUND: 5.1 plus the side pair.
        8 => &.{ .fl, .fr, .fc, .lfe, .rl, .rr, .sl, .sr },
        else => null,
    };
}

/// Check that a map can be expressed as a `dwChannelMask`.
pub fn validate(map: []const Channel) MapError!void {
    if (map.len > max_channels) return error.TooManyChannels;

    var seen: u32 = 0;
    for (map) |ch| {
        const bit = ch.mask();
        if (seen & bit != 0) return error.DuplicateChannel;
        seen |= bit;
        if (ch == .mono and map.len > 1) return error.MonoWithOthers;
    }
}

/// The `dwChannelMask` for a map.
///
/// Assumes the map is valid; call `validate` first. A map with a duplicate would
/// produce a mask with fewer bits than the stream has channels, which is exactly
/// the corruption `validate` exists to catch.
pub fn maskFor(map: []const Channel) u32 {
    var mask: u32 = 0;
    for (map) |ch| mask |= ch.mask();
    return mask;
}

/// The map a `dwChannelMask` describes, in wire order, written into `out`.
///
/// Returns the prefix of `out` that was written. Ascending bit order, which is
/// both the order the mask is walked in and the order the samples arrive in --
/// so what comes back is a layout that needs no further permutation.
///
/// `error.TooManyChannels` when the mask names more positions than `out` holds,
/// and bits this library has no name for are skipped: an endpoint reporting a
/// position outside the twelve is one whose extra channels this library cannot
/// address, and reporting the ones it can is more useful than refusing the lot.
pub fn mapFromMask(mask: u32, out: []Channel) error{TooManyChannels}![]const Channel {
    var count: usize = 0;
    for (ordered_bits) |bit| {
        if (mask & bit == 0) continue;
        if (count >= out.len) return error.TooManyChannels;
        out[count] = Channel.fromMask(bit).?;
        count += 1;
    }
    return out[0..count];
}

/// Where each channel of `map` belongs in an interleaved frame on the wire.
///
/// `out[i]` is the position within a frame that `map[i]`'s sample must be
/// written to. So a caller's channel `i` becomes wire slot `out[i]`, and a
/// renderer copies `frame[out[i]] = source[i]`.
///
/// For stereo this is the identity, and for 5.1 and 7.1 it is *also* the
/// identity -- which is precisely why it has to be computed rather than assumed.
/// See this file's overview.
pub fn wireOrder(map: []const Channel, out: []u8) MapError![]const u8 {
    try validate(map);
    if (map.len > out.len) return error.TooManyChannels;

    const mask = maskFor(map);
    for (map, 0..) |ch, i| {
        // The wire slot is the number of set bits below this channel's bit:
        // ascending bit order means everything lower comes first.
        out[i] = @intCast(@popCount(mask & (ch.mask() - 1)));
    }
    return out[0..map.len];
}

/// Whether a map is already in wire order, so a renderer can skip the
/// permutation entirely.
///
/// True for every layout `defaultChannelMap` returns, which is the common case
/// and worth not paying for once per cycle.
pub fn isWireOrdered(map: []const Channel) bool {
    var previous: u32 = 0;
    for (map) |ch| {
        const bit = ch.mask();
        if (bit <= previous) return false;
        previous = bit;
    }
    return true;
}

/// Every named speaker bit, ascending -- which is wire order.
const ordered_bits = [_]u32{
    0x1, // FL
    0x2, // FR
    0x4, // FC
    0x8, // LFE
    0x10, // BL
    0x20, // BR
    0x40, // FLC
    0x80, // FRC
    0x100, // BC
    0x200, // SL
    0x400, // SR
};

test "the named bits ascend, because that is what makes them wire order" {
    var previous: u32 = 0;
    for (ordered_bits) |bit| {
        try std.testing.expect(bit > previous);
        previous = bit;
    }
    // And every one of them names a channel, so `mapFromMask` never skips a bit
    // it listed.
    for (ordered_bits) |bit| try std.testing.expect(Channel.fromMask(bit) != null);
}

test "every channel's bit round-trips, except that mono is front centre" {
    for (std.enums.values(Channel)) |ch| {
        const back = Channel.fromMask(ch.mask()).?;
        if (ch == .mono) {
            // Documented: within a mask the two are the same position, and `fc`
            // is the answer that is right for a multi-channel layout.
            try std.testing.expectEqual(Channel.fc, back);
        } else {
            try std.testing.expectEqual(ch, back);
        }
    }
    try std.testing.expectEqual(Channel.mono.mask(), Channel.fc.mask());
}

test "the conventional layouts have the masks Windows documents" {
    // These are the `KSAUDIO_SPEAKER_*` values from `ksmedia.h`. If one of these
    // changes, a surround endpoint gets a format it will refuse -- or accept and
    // then play to the wrong speakers.
    try std.testing.expectEqual(@as(u32, 0x4), maskFor(defaultChannelMap(1).?)); // MONO
    try std.testing.expectEqual(@as(u32, 0x3), maskFor(defaultChannelMap(2).?)); // STEREO
    try std.testing.expectEqual(@as(u32, 0x33), maskFor(defaultChannelMap(4).?)); // QUAD
    try std.testing.expectEqual(@as(u32, 0x3F), maskFor(defaultChannelMap(6).?)); // 5POINT1
    try std.testing.expectEqual(@as(u32, 0x63F), maskFor(defaultChannelMap(8).?)); // 7POINT1_SURROUND
}

test "a channel count with no convention is refused rather than guessed" {
    // Three channels could be {fl, fr, fc} or {fl, fr, lfe}, and picking one
    // would put a caller's bass in their centre speaker with no complaint.
    for ([_]u32{ 0, 3, 5, 7, 9, 12, 64 }) |n| {
        try std.testing.expectEqual(@as(?[]const Channel, null), defaultChannelMap(n));
    }
    for ([_]u32{ 1, 2, 4, 6, 8 }) |n| {
        try std.testing.expect(defaultChannelMap(n) != null);
    }
}

test "the conventional layouts are all already in wire order" {
    // This is the coincidence that makes the wire-order bug so easy to ship: for
    // every layout anybody tests with, the permutation is the identity.
    for ([_]u32{ 1, 2, 4, 6, 8 }) |n| {
        const map = defaultChannelMap(n).?;
        try std.testing.expect(isWireOrdered(map));

        var buf: [max_channels]u8 = undefined;
        const order = try wireOrder(map, &buf);
        for (order, 0..) |slot, i| try std.testing.expectEqual(@as(u8, @intCast(i)), slot);
    }
}

test "a layout with a front-of-centre pair is not in the conventional order" {
    // 0x40 and 0x80 sort *before* the side channels in the mask and *after*
    // them in this library's `Channel` order, so here the identity permutation
    // is wrong. This is the test that would have caught it.
    const map = [_]Channel{ .fl, .fr, .fc, .lfe, .sl, .sr, .flc, .frc };
    try std.testing.expect(!isWireOrdered(&map));

    var buf: [max_channels]u8 = undefined;
    const order = try wireOrder(&map, &buf);

    // Mask is 0x1|0x2|0x4|0x8|0x200|0x400|0x40|0x80 = 0x6CF. Ascending:
    // FL(0x1) FR(0x2) FC(0x4) LFE(0x8) FLC(0x40) FRC(0x80) SL(0x200) SR(0x400).
    // So the caller's sides land in slots 6 and 7, and the front-of-centre pair
    // it wrote last lands in slots 4 and 5.
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 6, 7, 4, 5 }, order);
}

test "a layout with a rear centre is not in the conventional order either" {
    // BC is 0x100, which sorts before SL's 0x200 -- but `Channel` lists `rc`
    // last of all, after both sides.
    const map = [_]Channel{ .fl, .fr, .sl, .sr, .rc };
    try std.testing.expect(!isWireOrdered(&map));

    var buf: [max_channels]u8 = undefined;
    const order = try wireOrder(&map, &buf);

    // Mask 0x1|0x2|0x200|0x400|0x100 = 0x703. Ascending: FL FR BC SL SR.
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 3, 4, 2 }, order);
}

test "a wire order is a permutation, for every layout" {
    // The property that matters regardless of the specific numbers: every slot
    // is used exactly once. A permutation that dropped or doubled a slot would
    // silence one speaker and sum two others into another.
    const layouts = [_][]const Channel{
        defaultChannelMap(1).?,
        defaultChannelMap(2).?,
        defaultChannelMap(4).?,
        defaultChannelMap(6).?,
        defaultChannelMap(8).?,
        &.{ .fl, .fr, .fc, .lfe, .sl, .sr, .flc, .frc },
        &.{ .fl, .fr, .sl, .sr, .rc },
        &.{ .sr, .sl, .fr, .fl },
        &.{ .rc, .lfe, .fl },
    };

    for (layouts) |map| {
        var buf: [max_channels]u8 = undefined;
        const order = try wireOrder(map, &buf);
        try std.testing.expectEqual(map.len, order.len);

        var used: u32 = 0;
        for (order) |slot| {
            try std.testing.expect(slot < map.len);
            const bit = @as(u32, 1) << @intCast(slot);
            try std.testing.expectEqual(@as(u32, 0), used & bit); // not used twice
            used |= bit;
        }
    }
}

test "a mask decodes to a layout that needs no further permutation" {
    var buf: [max_channels]Channel = undefined;

    const stereo = try mapFromMask(0x3, &buf);
    try std.testing.expectEqualSlices(Channel, &.{ .fl, .fr }, stereo);
    try std.testing.expect(isWireOrdered(stereo));

    const surround = try mapFromMask(0x3F, &buf);
    try std.testing.expectEqualSlices(
        Channel,
        &.{ .fl, .fr, .fc, .lfe, .rl, .rr },
        surround,
    );
    try std.testing.expect(isWireOrdered(surround));

    // The awkward one: decoding gives wire order even though the conventional
    // spelling of the same set does not.
    const awkward = try mapFromMask(0x6CF, &buf);
    try std.testing.expectEqualSlices(
        Channel,
        &.{ .fl, .fr, .fc, .lfe, .flc, .frc, .sl, .sr },
        awkward,
    );
    try std.testing.expect(isWireOrdered(awkward));
}

test "a mask decodes to the same set it was built from" {
    for ([_]u32{ 1, 2, 4, 6, 8 }) |n| {
        const map = defaultChannelMap(n).?;
        var buf: [max_channels]Channel = undefined;
        const decoded = try mapFromMask(maskFor(map), &buf);
        try std.testing.expectEqual(maskFor(map), maskFor(decoded));
    }
}

test "a bit with no name is skipped rather than refused" {
    // 0x800 is SPEAKER_TOP_CENTER, which this library has no position for. An
    // endpoint reporting it still has eleven channels this library can address.
    var buf: [max_channels]Channel = undefined;
    const decoded = try mapFromMask(0x3 | 0x800, &buf);
    try std.testing.expectEqualSlices(Channel, &.{ .fl, .fr }, decoded);
}

test "a map that cannot be a mask is refused" {
    // A duplicate would make the mask name fewer positions than the stream has
    // channels, and Windows would either refuse the format or interleave it
    // differently than the caller intended.
    try std.testing.expectError(error.DuplicateChannel, validate(&.{ .fl, .fl }));
    try std.testing.expectError(error.DuplicateChannel, validate(&.{ .fl, .fr, .fl }));

    // `mono` is `fc`, so this map is really `{ fc, fl }` -- and a caller who
    // wrote `mono` did not mean that.
    try std.testing.expectError(error.MonoWithOthers, validate(&.{ .mono, .fl }));

    // `{ mono, fc }` is both faults at once -- a duplicate bit *and* mono in
    // company -- and it reports `MonoWithOthers`, which is the one that explains
    // why the two entries collided. A caller told only that something was
    // duplicated would be looking for a repeated name that is not there.
    try std.testing.expectError(error.MonoWithOthers, validate(&.{ .mono, .fc }));

    const too_many = [_]Channel{.fl} ** (max_channels + 1);
    try std.testing.expectError(error.TooManyChannels, validate(&too_many));

    // And every conventional layout passes.
    for ([_]u32{ 1, 2, 4, 6, 8 }) |n| try validate(defaultChannelMap(n).?);
}

test "a channel prints as the name ksmedia.h uses" {
    // So that a listing from this library can be compared against the headers
    // without a translation table -- which means `rl` prints as `BL`.
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("BL", try std.fmt.bufPrint(&buf, "{f}", .{Channel.rl}));
    try std.testing.expectEqualStrings("BC", try std.fmt.bufPrint(&buf, "{f}", .{Channel.rc}));
    try std.testing.expectEqualStrings("FL", try std.fmt.bufPrint(&buf, "{f}", .{Channel.fl}));
}

test {
    std.testing.refAllDecls(@This());
}
