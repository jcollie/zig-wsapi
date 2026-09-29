// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The constants a `WAVEFORMATEXTENSIBLE` needs, gathered under the names
//! Microsoft uses for them.
//!
//! Not one of these is missing from `zigwin32`. They are, however, spread across
//! four of its namespaces and two of them are renamed on the way, so a reader
//! who knows what `KSDATAFORMAT_SUBTYPE_PCM` is will not find it by looking
//! where it ought to be. This file is the translation table, and it exists so
//! that `format.zig` reads like the documentation it implements:
//!
//! | what the headers call it | where `zigwin32` filed it |
//! |---|---|
//! | `WAVE_FORMAT_PCM` | `media.audio` |
//! | `WAVE_FORMAT_IEEE_FLOAT` | `media.multimedia` |
//! | `WAVE_FORMAT_EXTENSIBLE` | `media.kernel_streaming`, and as a `u32` |
//! | `KSDATAFORMAT_SUBTYPE_PCM` | `media.kernel_streaming`, as `CLSID_…` |
//! | `KSDATAFORMAT_SUBTYPE_IEEE_FLOAT` | `media.multimedia`, as `CLSID_…` |
//! | `SPEAKER_*` | `media.kernel_streaming` |
//!
//! The `CLSID_` prefix on the two subformat GUIDs is the binding generator's
//! doing: it prefixes every GUID that is not an interface id that way, and a
//! `KSDATAFORMAT_SUBTYPE_*` is a format identifier rather than a class id. They
//! are aliased here under their real names rather than used through the
//! generated ones, because a `CLSID_` that is not a class id misleads at every
//! call site it appears in.

const std = @import("std");

const win32 = @import("win32").everything;
const Guid = win32.Guid;

/// `WAVE_FORMAT_PCM`, for a `WAVEFORMATEX.wFormatTag`.
pub const wave_format_pcm: u16 = win32.WAVE_FORMAT_PCM;

/// `WAVE_FORMAT_IEEE_FLOAT`, for a `WAVEFORMATEX.wFormatTag`.
pub const wave_format_ieee_float: u16 = @intCast(win32.WAVE_FORMAT_IEEE_FLOAT);

/// `WAVE_FORMAT_EXTENSIBLE` (0xFFFE), for a `WAVEFORMATEX.wFormatTag`.
///
/// Narrowed from the `u32` the bindings declare, because the field it goes in is
/// a `u16`. The `@intCast` is here, once, rather than at each use.
pub const wave_format_extensible: u16 = @intCast(win32.WAVE_FORMAT_EXTENSIBLE);

/// `KSDATAFORMAT_SUBTYPE_PCM`, for a `WAVEFORMATEXTENSIBLE.SubFormat`.
pub const ksdataformat_subtype_pcm: *const Guid = win32.CLSID_KSDATAFORMAT_SUBTYPE_PCM;

/// `KSDATAFORMAT_SUBTYPE_IEEE_FLOAT`, for a `WAVEFORMATEXTENSIBLE.SubFormat`.
pub const ksdataformat_subtype_ieee_float: *const Guid =
    win32.CLSID_KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;

/// The speaker-position bits of a `dwChannelMask`, in ascending bit order --
/// which is also the order the samples of a frame must be interleaved in.
///
/// Gathered into an enum rather than left as eleven loose `u32` constants
/// because the *order* is the part that matters and a list of constants does not
/// show it. `channel.zig` iterates this to build a wire permutation, and the
/// declaration order here is load-bearing for that.
pub const Speaker = enum(u32) {
    front_left = win32.SPEAKER_FRONT_LEFT,
    front_right = win32.SPEAKER_FRONT_RIGHT,
    front_center = win32.SPEAKER_FRONT_CENTER,
    low_frequency = win32.SPEAKER_LOW_FREQUENCY,
    back_left = win32.SPEAKER_BACK_LEFT,
    back_right = win32.SPEAKER_BACK_RIGHT,
    front_left_of_center = win32.SPEAKER_FRONT_LEFT_OF_CENTER,
    front_right_of_center = win32.SPEAKER_FRONT_RIGHT_OF_CENTER,
    back_center = win32.SPEAKER_BACK_CENTER,
    side_left = win32.SPEAKER_SIDE_LEFT,
    side_right = win32.SPEAKER_SIDE_RIGHT,
};

test "the subformat guids are the ones the headers document" {
    // These are aliases through two different namespaces under two different
    // names, so an upstream rename would silently point them elsewhere. The
    // byte patterns are from `ksmedia.h` and are not going to change.
    const expect_float = Guid.initString("00000003-0000-0010-8000-00aa00389b71");
    const expect_pcm = Guid.initString("00000001-0000-0010-8000-00aa00389b71");

    try std.testing.expectEqualSlices(
        u8,
        &expect_float.Bytes,
        &ksdataformat_subtype_ieee_float.Bytes,
    );
    try std.testing.expectEqualSlices(u8, &expect_pcm.Bytes, &ksdataformat_subtype_pcm.Bytes);
}

test "the format tags are the documented numbers" {
    try std.testing.expectEqual(@as(u16, 0x0001), wave_format_pcm);
    try std.testing.expectEqual(@as(u16, 0x0003), wave_format_ieee_float);
    try std.testing.expectEqual(@as(u16, 0xFFFE), wave_format_extensible);
}

test "the speaker bits ascend in declaration order" {
    // `channel.zig` builds the interleaving order by walking this enum, so a
    // reordering here would silently produce audio in the wrong channels --
    // which is the one class of bug a listener catches and a test usually does
    // not. This is that test.
    var previous: u32 = 0;
    for (std.enums.values(Speaker)) |speaker| {
        const bit = @intFromEnum(speaker);
        try std.testing.expect(bit > previous);
        previous = bit;
    }

    // And the low four are the ones every layout starts with.
    try std.testing.expectEqual(@as(u32, 0x1), @intFromEnum(Speaker.front_left));
    try std.testing.expectEqual(@as(u32, 0x2), @intFromEnum(Speaker.front_right));
    try std.testing.expectEqual(@as(u32, 0x4), @intFromEnum(Speaker.front_center));
    try std.testing.expectEqual(@as(u32, 0x8), @intFromEnum(Speaker.low_frequency));
}

test "channel.zig's hand-written speaker bits are the ones zigwin32 has" {
    // `channel.zig` is in the half of the library with no operating system in
    // it, so it cannot import these constants and writes the numbers out
    // instead. This is the test that makes that safe: a typo there fails the
    // Windows build here rather than quietly moving somebody's centre channel.
    //
    // It lives in this file rather than in `channel.zig` because this is the
    // file that is allowed to know what `zigwin32` calls things.
    const channel = @import("../channel.zig");

    const pairs = .{
        .{ channel.Channel.fl, win32.SPEAKER_FRONT_LEFT },
        .{ channel.Channel.fr, win32.SPEAKER_FRONT_RIGHT },
        .{ channel.Channel.fc, win32.SPEAKER_FRONT_CENTER },
        .{ channel.Channel.lfe, win32.SPEAKER_LOW_FREQUENCY },
        .{ channel.Channel.rl, win32.SPEAKER_BACK_LEFT },
        .{ channel.Channel.rr, win32.SPEAKER_BACK_RIGHT },
        .{ channel.Channel.flc, win32.SPEAKER_FRONT_LEFT_OF_CENTER },
        .{ channel.Channel.frc, win32.SPEAKER_FRONT_RIGHT_OF_CENTER },
        .{ channel.Channel.rc, win32.SPEAKER_BACK_CENTER },
        .{ channel.Channel.sl, win32.SPEAKER_SIDE_LEFT },
        .{ channel.Channel.sr, win32.SPEAKER_SIDE_RIGHT },
        // Windows has no separate mono position; mono is the centre channel.
        .{ channel.Channel.mono, win32.SPEAKER_FRONT_CENTER },
    };

    inline for (pairs) |pair| {
        try std.testing.expectEqual(@as(u32, pair[1]), pair[0].mask());
    }
}

test "format.zig's hand-written subtype bytes are zigwin32's guids" {
    // Same arrangement as the speaker bits: `format.zig` has to stay free of any
    // operating system so its encoder can be tested on a Linux host, so it spells
    // the two `KSDATAFORMAT_SUBTYPE_*` GUIDs out as bytes. This is what proves
    // the byte order -- a GUID's mixed-endianness is exactly the kind of thing to
    // get subtly wrong, and the failure mode is that every format this library
    // offers comes back `AUDCLNT_E_UNSUPPORTED_FORMAT` with no further hint.
    const format = @import("../format.zig");

    try std.testing.expectEqualSlices(
        u8,
        &ksdataformat_subtype_ieee_float.Bytes,
        &format.subtype_ieee_float,
    );
    try std.testing.expectEqualSlices(
        u8,
        &ksdataformat_subtype_pcm.Bytes,
        &format.subtype_pcm,
    );
}

test "format.zig's hand-written format tags are zigwin32's" {
    const format = @import("../format.zig");
    try std.testing.expectEqual(wave_format_pcm, format.wave_format_pcm);
    try std.testing.expectEqual(wave_format_ieee_float, format.wave_format_ieee_float);
    try std.testing.expectEqual(wave_format_extensible, format.wave_format_extensible);
}

test "format.zig's structure sizes match the bindings' own structs" {
    // The encoder writes 18 and 40 bytes because that is what the headers say.
    // If `zigwin32`'s structs ever disagree, the `@ptrCast` that hands these
    // bytes to WASAPI would be reading a different shape than it wrote.
    const format = @import("../format.zig");
    try std.testing.expectEqual(@sizeOf(win32.WAVEFORMATEX), format.base_len);
    try std.testing.expectEqual(@sizeOf(win32.WAVEFORMATEXTENSIBLE), format.extensible_len);
    try std.testing.expectEqual(
        @sizeOf(win32.WAVEFORMATEXTENSIBLE) - @sizeOf(win32.WAVEFORMATEX),
        format.extension_len,
    );

    // And both are byte-aligned, which is what makes the cast legal in either
    // direction with no `@alignCast`.
    try std.testing.expectEqual(@as(u29, 1), @alignOf(win32.WAVEFORMATEX));
    try std.testing.expectEqual(@as(u29, 1), @alignOf(win32.WAVEFORMATEXTENSIBLE));
}

test "an encoded format is readable through the bindings' own struct" {
    // The end-to-end check that the pure encoder and the real structure agree:
    // encode as bytes, read back through `WAVEFORMATEXTENSIBLE`, and compare
    // field by field. This is the closest a test can get to what WASAPI does
    // with the pointer.
    const format = @import("../format.zig");
    const fmt: format.Format = .{ .rate = 48000, .channels = 6, .sample = .f32 };

    var bytes: [format.extensible_len]u8 align(8) = undefined;
    _ = fmt.encodeExtensible(&bytes);

    const ext: *const win32.WAVEFORMATEXTENSIBLE = @ptrCast(&bytes);
    try std.testing.expectEqual(wave_format_extensible, ext.Format.wFormatTag);
    try std.testing.expectEqual(@as(u16, 6), ext.Format.nChannels);
    try std.testing.expectEqual(@as(u32, 48000), ext.Format.nSamplesPerSec);
    try std.testing.expectEqual(@as(u16, 24), ext.Format.nBlockAlign);
    try std.testing.expectEqual(@as(u16, 32), ext.Format.wBitsPerSample);
    try std.testing.expectEqual(@as(u16, 22), ext.Format.cbSize);
    try std.testing.expectEqual(@as(u16, 32), ext.Samples.wValidBitsPerSample);
    try std.testing.expectEqual(@as(u32, 0x3F), ext.dwChannelMask);
    try std.testing.expectEqualSlices(
        u8,
        &ksdataformat_subtype_ieee_float.Bytes,
        &ext.SubFormat.Bytes,
    );

    // And the plain `WAVEFORMATEX` view of the same bytes, which is the pointer
    // type every WASAPI entry point actually takes.
    const base: *const win32.WAVEFORMATEX = @ptrCast(&bytes);
    try std.testing.expectEqual(ext.Format.nChannels, base.nChannels);
}

test "the Speaker enum here and channel.zig's order agree" {
    // Two lists of the same eleven bits in the same order, in two files that
    // cannot import each other. This asserts they have not drifted.
    const channel = @import("../channel.zig");
    var buf: [channel.max_channels]channel.Channel = undefined;

    var every_bit: u32 = 0;
    for (std.enums.values(Speaker)) |speaker| every_bit |= @intFromEnum(speaker);

    const decoded = try channel.mapFromMask(every_bit, &buf);
    try std.testing.expectEqual(std.enums.values(Speaker).len, decoded.len);
    for (std.enums.values(Speaker), decoded) |speaker, ch| {
        try std.testing.expectEqual(@as(u32, @intFromEnum(speaker)), ch.mask());
    }
}

test {
    std.testing.refAllDecls(@This());
}
