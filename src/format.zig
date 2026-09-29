// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What a stream's samples look like, and the `WAVEFORMATEX` bytes that say so.
//!
//! ```zig
//! const fmt: Format = .{ .rate = 48000, .channels = 2, .sample = .f32, .mask = 0x3 };
//!
//! var bytes: [extensible_len]u8 align(8) = undefined;
//! const encoded = fmt.encodeExtensible(&bytes);   // hand `encoded.ptr` to WASAPI
//!
//! const mix = try Format.decode(whatever_GetMixFormat_returned);
//! ```
//!
//! ## Why this is bytes rather than a struct
//!
//! `WAVEFORMATEXTENSIBLE` is the single most error-prone structure in the whole
//! of WASAPI. Every field is redundant with another -- `nBlockAlign` must equal
//! `nChannels * wBitsPerSample / 8`, `nAvgBytesPerSec` must equal
//! `nSamplesPerSec * nBlockAlign`, `wValidBitsPerSample` must not exceed
//! `wBitsPerSample`, `cbSize` must be exactly 22, and the `SubFormat` GUID must
//! agree with `wFormatTag` -- and when any of them disagree, the only thing
//! Windows says is `AUDCLNT_E_UNSUPPORTED_FORMAT`. There is no indication of
//! which field was wrong.
//!
//! So this file builds and parses the structure as *bytes*, which makes it part
//! of the operating-system-independent half of the library and lets a test on any
//! host assert the exact forty bytes against the numbers in `mmreg.h`. Those
//! golden-byte tests are the only place the encoding is ever actually checked; a
//! Windows runner can only tell you that something in there was wrong.
//!
//! Handing the bytes to WASAPI is then a `@ptrCast`, which is legal without any
//! alignment gymnastics because `zigwin32` declares every field of both
//! `WAVEFORMATEX` and `WAVEFORMATEXTENSIBLE` as `align(1)`.
//!
//! ## `cbSize == 0` is legal and common
//!
//! A driver is entitled to answer `GetMixFormat` with a plain 18-byte
//! `WAVEFORMATEX` and no extension at all, and several do for ordinary stereo.
//! A decoder that reads `dwChannelMask` unconditionally reads 22 bytes past the
//! end of an 18-byte structure. `decode` checks the length and the `cbSize`
//! before it touches the extension, and there is a test for each shape.

const std = @import("std");

const channel = @import("channel.zig");

/// How one sample is stored.
///
/// Shared mode almost always mixes in `f32`, but "almost always" is not a
/// contract: Bluetooth and some USB endpoints report `i16`, and a high-end DAC
/// reports 24 valid bits in a 32-bit container. All four are converted in
/// `mix.zig` on the way into the render buffer.
pub const Sample = enum {
    /// 32-bit IEEE float, nominally in -1.0 to 1.0. What the Windows audio
    /// engine mixes in, and what this library's own API uses throughout.
    f32,
    /// 16-bit signed integer. The format of every Bluetooth headset and of a
    /// good many USB interfaces.
    i16,
    /// 24-bit signed integer packed into three bytes, no padding. Rare, and
    /// awkward precisely because a sample is not a whole number of machine
    /// words.
    i24_packed,
    /// 24 valid bits, left-justified in a 32-bit container. What most
    /// higher-resolution hardware actually reports, and not the same thing as
    /// `i24_packed` however similar the names look.
    i24_in_32,
    /// 32-bit signed integer.
    i32,

    /// Bytes one sample occupies, including any padding in its container.
    pub fn containerBytes(self: Sample) u16 {
        return switch (self) {
            .i16 => 2,
            .i24_packed => 3,
            .f32, .i24_in_32, .i32 => 4,
        };
    }

    /// Bits that carry signal. Equal to the container's bits except for
    /// `i24_in_32`, which is the whole reason `wValidBitsPerSample` exists.
    pub fn validBits(self: Sample) u16 {
        return switch (self) {
            .i16 => 16,
            .i24_packed, .i24_in_32 => 24,
            .f32, .i32 => 32,
        };
    }

    /// Whether this is a floating-point format, which decides both `wFormatTag`
    /// and which `KSDATAFORMAT_SUBTYPE_*` GUID belongs in the extension.
    pub fn isFloat(self: Sample) bool {
        return self == .f32;
    }

    /// Work out which of these an endpoint means from the three numbers a
    /// `WAVEFORMATEX` gives, or null for a combination this library cannot carry.
    ///
    /// Ambiguity is resolved towards the container: 24 valid bits in a 32-bit
    /// container is `i24_in_32` and never `i32`, because that is what the
    /// endpoint said and truncating to 24 bits on the way out is wrong.
    pub fn fromBits(float: bool, container_bits: u16, valid_bits: u16) ?Sample {
        if (float) return if (container_bits == 32) .f32 else null;
        return switch (container_bits) {
            16 => if (valid_bits == 16) .i16 else null,
            24 => if (valid_bits == 24) .i24_packed else null,
            32 => switch (valid_bits) {
                24 => .i24_in_32,
                32 => .i32,
                else => null,
            },
            else => null,
        };
    }
};

/// A stream format, in the terms this library's API speaks.
pub const Format = struct {
    /// Frames a second.
    rate: u32,
    /// Samples in a frame.
    channels: u16,
    /// How each of those samples is stored.
    sample: Sample,
    /// The `dwChannelMask`: which speakers the channels go to, and -- through
    /// ascending bit order -- what order they are interleaved in. See `channel`.
    ///
    /// Zero means the endpoint did not say, which a plain 18-byte
    /// `WAVEFORMATEX` never does. A caller wanting a layout for it should fall
    /// back to `channel.defaultChannelMap`.
    mask: u32 = 0,

    /// Bytes one frame occupies: `nBlockAlign`.
    pub fn blockAlign(self: Format) u16 {
        return self.channels * self.sample.containerBytes();
    }

    /// Bytes a second: `nAvgBytesPerSec`.
    pub fn avgBytesPerSec(self: Format) u32 {
        return self.rate * self.blockAlign();
    }

    /// How long `frames` frames last, in nanoseconds.
    pub fn framesToNs(self: Format, frames: u64) u64 {
        return frames * std.time.ns_per_s / self.rate;
    }

    /// Whether two formats are interchangeable.
    ///
    /// The mask is part of it: two formats with the same rate, channel count and
    /// sample type but different masks interleave differently, and treating them
    /// as equal is how audio ends up in the wrong speakers.
    pub fn eql(self: Format, other: Format) bool {
        return self.rate == other.rate and
            self.channels == other.channels and
            self.sample == other.sample and
            self.mask == other.mask;
    }

    pub fn format(self: Format, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} Hz, {d} ch, {t}", .{ self.rate, self.channels, self.sample });
        if (self.mask != 0) try w.print(", mask 0x{X}", .{self.mask});
    }

    /// Write this format as a `WAVEFORMATEXTENSIBLE`.
    ///
    /// Always the extensible form, never the plain 18-byte one, because the
    /// extensible form is the only one that can state a channel layout -- and a
    /// format without a layout leaves Windows to guess where a caller's channels
    /// should go. `buf` must be `extensible_len` bytes; the returned slice is all
    /// of it.
    ///
    /// When `mask` is zero the conventional layout for the channel count is used,
    /// and if there is no convention for that count the mask is left zero, which
    /// Windows reads as "any layout" and is the best available answer.
    pub fn encodeExtensible(self: Format, buf: *[extensible_len]u8) []u8 {
        const container_bits = self.sample.containerBytes() * 8;

        // WAVEFORMATEX, 18 bytes.
        std.mem.writeInt(u16, buf[0..2], wave_format_extensible, .little);
        std.mem.writeInt(u16, buf[2..4], self.channels, .little);
        std.mem.writeInt(u32, buf[4..8], self.rate, .little);
        std.mem.writeInt(u32, buf[8..12], self.avgBytesPerSec(), .little);
        std.mem.writeInt(u16, buf[12..14], self.blockAlign(), .little);
        std.mem.writeInt(u16, buf[14..16], container_bits, .little);
        std.mem.writeInt(u16, buf[16..18], extension_len, .little);

        // The extension, 22 bytes.
        std.mem.writeInt(u16, buf[18..20], self.sample.validBits(), .little);
        std.mem.writeInt(u32, buf[20..24], self.effectiveMask(), .little);
        buf[24..40].* = if (self.sample.isFloat())
            subtype_ieee_float
        else
            subtype_pcm;

        return buf;
    }

    /// The mask that will actually be written: the caller's, or the convention
    /// for the channel count, or zero if there is no convention.
    pub fn effectiveMask(self: Format) u32 {
        if (self.mask != 0) return self.mask;
        const map = channel.defaultChannelMap(self.channels) orelse return 0;
        return channel.maskFor(map);
    }

    /// Read a `WAVEFORMATEX` or `WAVEFORMATEXTENSIBLE` out of the bytes Windows
    /// handed back.
    pub fn decode(bytes: []const u8) DecodeError!Format {
        if (bytes.len < base_len) return error.Truncated;

        const tag = std.mem.readInt(u16, bytes[0..2], .little);
        const channels = std.mem.readInt(u16, bytes[2..4], .little);
        const rate = std.mem.readInt(u32, bytes[4..8], .little);
        const container_bits = std.mem.readInt(u16, bytes[14..16], .little);
        const cb_size = std.mem.readInt(u16, bytes[16..18], .little);

        if (channels == 0) return error.NoChannels;
        if (channels > channel.max_channels) return error.TooManyChannels;
        if (rate == 0) return error.NoRate;
        if (container_bits % 8 != 0) return error.OddSampleSize;

        switch (tag) {
            wave_format_pcm, wave_format_ieee_float => {
                // The plain form. It carries no `wValidBitsPerSample`, so every
                // bit of the container is signal, and no mask -- which is why
                // `Format.mask` can be zero.
                const sample = Sample.fromBits(
                    tag == wave_format_ieee_float,
                    container_bits,
                    container_bits,
                ) orelse return error.UnsupportedSampleType;
                return .{ .rate = rate, .channels = channels, .sample = sample, .mask = 0 };
            },
            wave_format_extensible => {
                // Only now is it safe to look past byte 18. A driver that says
                // `WAVE_FORMAT_EXTENSIBLE` with too small a `cbSize` is
                // malformed, and reading it anyway is a buffer overrun.
                if (cb_size < extension_len) return error.ExtensionTooSmall;
                if (bytes.len < extensible_len) return error.Truncated;

                const valid_bits = std.mem.readInt(u16, bytes[18..20], .little);
                const mask = std.mem.readInt(u32, bytes[20..24], .little);
                const subtype = bytes[24..40];

                const float = std.mem.eql(u8, subtype, &subtype_ieee_float);
                if (!float and !std.mem.eql(u8, subtype, &subtype_pcm)) {
                    return error.UnsupportedSubformat;
                }

                // Zero means "all of the container", which is what a driver
                // writes when it has nothing to narrow.
                const effective_valid = if (valid_bits == 0) container_bits else valid_bits;
                if (effective_valid > container_bits) return error.ValidBitsTooLarge;

                const sample = Sample.fromBits(float, container_bits, effective_valid) orelse
                    return error.UnsupportedSampleType;
                return .{ .rate = rate, .channels = channels, .sample = sample, .mask = mask };
            },
            else => return error.UnsupportedFormatTag,
        }
    }
};

/// What can be wrong with the bytes an endpoint handed back.
///
/// Every one of these is a driver disagreeing with the documentation rather than
/// a mistake on this side, which is why they are distinguished: the log line
/// naming which one it was is the only clue a bug report will carry.
pub const DecodeError = error{
    /// Fewer bytes than the structure needs. The one that matters, because the
    /// alternative to catching it is reading off the end of the allocation
    /// Windows gave us.
    Truncated,
    /// `wFormatTag` is neither PCM, float, nor extensible.
    UnsupportedFormatTag,
    /// `cbSize` is too small for the extension the tag promises.
    ExtensionTooSmall,
    /// The `SubFormat` GUID is neither of the two this library handles.
    UnsupportedSubformat,
    /// `wValidBitsPerSample` exceeds `wBitsPerSample`, which cannot be.
    ValidBitsTooLarge,
    /// A container size that is not a whole number of bytes.
    OddSampleSize,
    /// A combination of container and valid bits this library has no converter
    /// for.
    UnsupportedSampleType,
    /// `nChannels` is zero.
    NoChannels,
    /// More channels than `channel.max_channels`.
    TooManyChannels,
    /// `nSamplesPerSec` is zero.
    NoRate,
};

/// `sizeof(WAVEFORMATEX)`: the structure with no extension.
pub const base_len = 18;

/// `sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)`, which is what `cbSize`
/// must be for an extensible format. Twenty-two, always.
pub const extension_len = 22;

/// `sizeof(WAVEFORMATEXTENSIBLE)`.
pub const extensible_len = base_len + extension_len;

/// `WAVE_FORMAT_PCM`.
pub const wave_format_pcm: u16 = 0x0001;
/// `WAVE_FORMAT_IEEE_FLOAT`.
pub const wave_format_ieee_float: u16 = 0x0003;
/// `WAVE_FORMAT_EXTENSIBLE`.
pub const wave_format_extensible: u16 = 0xFFFE;

/// `KSDATAFORMAT_SUBTYPE_PCM`, as it appears in the bytes of the structure.
///
/// Written out rather than imported for the same reason the speaker bits in
/// `channel.zig` are -- this file has to stay free of any operating system so
/// that the encoding can be tested anywhere. A test in `com/missing.zig` asserts
/// these sixteen bytes against `zigwin32`'s own GUID.
///
/// The layout is a GUID's usual mixed-endianness: `Data1` little-endian, `Data2`
/// and `Data3` little-endian, and `Data4`'s eight bytes in written order. So
/// `00000001-0000-0010-8000-00aa00389b71` becomes the bytes below.
pub const subtype_pcm = [16]u8{
    0x01, 0x00, 0x00, 0x00, // Data1 = 0x00000001
    0x00, 0x00, // Data2 = 0x0000
    0x10, 0x00, // Data3 = 0x0010
    0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71, // Data4
};

/// `KSDATAFORMAT_SUBTYPE_IEEE_FLOAT`. Identical to `subtype_pcm` but for the
/// first byte, which is the sort of thing that makes a transposition bug hard to
/// see by eye and easy to catch in a test.
pub const subtype_ieee_float = [16]u8{
    0x03, 0x00, 0x00, 0x00, // Data1 = 0x00000003
    0x00, 0x00, // Data2 = 0x0000
    0x10, 0x00, // Data3 = 0x0010
    0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71, // Data4
};

test "48 kHz stereo float encodes to the exact bytes mmreg.h describes" {
    // The golden test. Every number here was worked out from the field
    // definitions rather than captured from a run, so it checks the encoder
    // against the documentation and not against itself.
    const fmt: Format = .{ .rate = 48000, .channels = 2, .sample = .f32 };
    var buf: [extensible_len]u8 align(8) = undefined;
    const bytes = fmt.encodeExtensible(&buf);

    try std.testing.expectEqualSlices(u8, &.{
        0xFE, 0xFF, // wFormatTag      = WAVE_FORMAT_EXTENSIBLE
        0x02, 0x00, // nChannels       = 2
        0x80, 0xBB, 0x00, 0x00, // nSamplesPerSec  = 48000 = 0x0000BB80
        0x00, 0xDC, 0x05, 0x00, // nAvgBytesPerSec = 48000 * 8 = 384000 = 0x0005DC00
        0x08, 0x00, // nBlockAlign     = 2 * 4 = 8
        0x20, 0x00, // wBitsPerSample  = 32
        0x16, 0x00, // cbSize          = 22
        0x20, 0x00, // wValidBitsPerSample = 32
        0x03, 0x00, 0x00, 0x00, // dwChannelMask   = FL | FR
        0x03, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x10, 0x00,
        0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71, // SubFormat = IEEE_FLOAT
    }, bytes);
}

test "44.1 kHz 5.1 float encodes with the surround mask and the right arithmetic" {
    const fmt: Format = .{ .rate = 44100, .channels = 6, .sample = .f32 };
    var buf: [extensible_len]u8 align(8) = undefined;
    const bytes = fmt.encodeExtensible(&buf);

    try std.testing.expectEqual(@as(u16, 24), std.mem.readInt(u16, bytes[12..14], .little));
    try std.testing.expectEqual(
        @as(u32, 44100 * 24),
        std.mem.readInt(u32, bytes[8..12], .little),
    );
    // KSAUDIO_SPEAKER_5POINT1, filled in from the channel count because the
    // caller gave no mask.
    try std.testing.expectEqual(@as(u32, 0x3F), std.mem.readInt(u32, bytes[20..24], .little));
}

test "24 valid bits in a 32-bit container is what wValidBitsPerSample is for" {
    const fmt: Format = .{ .rate = 96000, .channels = 2, .sample = .i24_in_32 };
    var buf: [extensible_len]u8 align(8) = undefined;
    const bytes = fmt.encodeExtensible(&buf);

    // The container is 32 bits and the signal is 24. A format that reported 24
    // for both would describe packed 24-bit audio and be interleaved
    // differently.
    try std.testing.expectEqual(@as(u16, 32), std.mem.readInt(u16, bytes[14..16], .little));
    try std.testing.expectEqual(@as(u16, 24), std.mem.readInt(u16, bytes[18..20], .little));
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, bytes[12..14], .little));
    try std.testing.expectEqualSlices(u8, &subtype_pcm, bytes[24..40]);
}

test "an encoded format decodes back to itself" {
    const cases = [_]Format{
        .{ .rate = 48000, .channels = 2, .sample = .f32, .mask = 0x3 },
        .{ .rate = 44100, .channels = 2, .sample = .i16, .mask = 0x3 },
        .{ .rate = 96000, .channels = 2, .sample = .i24_in_32, .mask = 0x3 },
        .{ .rate = 192000, .channels = 2, .sample = .i32, .mask = 0x3 },
        .{ .rate = 48000, .channels = 6, .sample = .f32, .mask = 0x3F },
        .{ .rate = 48000, .channels = 8, .sample = .f32, .mask = 0x63F },
        .{ .rate = 8000, .channels = 1, .sample = .i16, .mask = 0x4 },
        .{ .rate = 48000, .channels = 3, .sample = .i24_packed, .mask = 0x7 },
    };

    for (cases) |fmt| {
        var buf: [extensible_len]u8 align(8) = undefined;
        const decoded = try Format.decode(fmt.encodeExtensible(&buf));
        try std.testing.expect(fmt.eql(decoded));
    }
}

test "a plain 18-byte WAVEFORMATEX decodes without reading past its end" {
    // The shape that breaks a naive decoder: `cbSize` is zero, there is no
    // extension, and the allocation really is only eighteen bytes long. Passing
    // exactly eighteen bytes means a read of byte 18 would be caught by the
    // slice bounds in a safe build -- which is the point of testing it this way.
    var bytes: [base_len]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..2], wave_format_pcm, .little);
    std.mem.writeInt(u16, bytes[2..4], 2, .little);
    std.mem.writeInt(u32, bytes[4..8], 44100, .little);
    std.mem.writeInt(u32, bytes[8..12], 44100 * 4, .little);
    std.mem.writeInt(u16, bytes[12..14], 4, .little);
    std.mem.writeInt(u16, bytes[14..16], 16, .little);
    std.mem.writeInt(u16, bytes[16..18], 0, .little);

    const decoded = try Format.decode(&bytes);
    try std.testing.expectEqual(@as(u32, 44100), decoded.rate);
    try std.testing.expectEqual(@as(u16, 2), decoded.channels);
    try std.testing.expectEqual(Sample.i16, decoded.sample);
    // No extension means no layout, and the caller has to fall back.
    try std.testing.expectEqual(@as(u32, 0), decoded.mask);
    try std.testing.expectEqual(@as(u32, 0x3), decoded.effectiveMask());
}

test "a plain 18-byte float WAVEFORMATEX decodes too" {
    var bytes: [base_len]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..2], wave_format_ieee_float, .little);
    std.mem.writeInt(u16, bytes[2..4], 2, .little);
    std.mem.writeInt(u32, bytes[4..8], 48000, .little);
    std.mem.writeInt(u32, bytes[8..12], 48000 * 8, .little);
    std.mem.writeInt(u16, bytes[12..14], 8, .little);
    std.mem.writeInt(u16, bytes[14..16], 32, .little);
    std.mem.writeInt(u16, bytes[16..18], 0, .little);

    const decoded = try Format.decode(&bytes);
    try std.testing.expectEqual(Sample.f32, decoded.sample);
}

test "a truncated structure is refused rather than read" {
    // Both the too-short-for-anything case and the claims-extensible-but-is-not
    // case, which is the one that would overrun.
    var tiny: [8]u8 = @splat(0);
    try std.testing.expectError(error.Truncated, Format.decode(&tiny));

    var lying: [base_len]u8 = undefined;
    std.mem.writeInt(u16, lying[0..2], wave_format_extensible, .little);
    std.mem.writeInt(u16, lying[2..4], 2, .little);
    std.mem.writeInt(u32, lying[4..8], 48000, .little);
    std.mem.writeInt(u32, lying[8..12], 48000 * 8, .little);
    std.mem.writeInt(u16, lying[12..14], 8, .little);
    std.mem.writeInt(u16, lying[14..16], 32, .little);
    std.mem.writeInt(u16, lying[16..18], extension_len, .little); // says 22, has 0
    try std.testing.expectError(error.Truncated, Format.decode(&lying));
}

test "an extensible format with too small a cbSize is refused" {
    var bytes: [extensible_len]u8 align(8) = undefined;
    const fmt: Format = .{ .rate = 48000, .channels = 2, .sample = .f32 };
    _ = fmt.encodeExtensible(&bytes);
    std.mem.writeInt(u16, bytes[16..18], 6, .little); // a real but wrong cbSize
    try std.testing.expectError(error.ExtensionTooSmall, Format.decode(&bytes));
}

test "nonsense in the fields is refused, one error each" {
    var bytes: [extensible_len]u8 align(8) = undefined;
    const good: Format = .{ .rate = 48000, .channels = 2, .sample = .f32 };

    _ = good.encodeExtensible(&bytes);
    std.mem.writeInt(u16, bytes[2..4], 0, .little);
    try std.testing.expectError(error.NoChannels, Format.decode(&bytes));

    _ = good.encodeExtensible(&bytes);
    std.mem.writeInt(u16, bytes[2..4], channel.max_channels + 1, .little);
    try std.testing.expectError(error.TooManyChannels, Format.decode(&bytes));

    _ = good.encodeExtensible(&bytes);
    std.mem.writeInt(u32, bytes[4..8], 0, .little);
    try std.testing.expectError(error.NoRate, Format.decode(&bytes));

    _ = good.encodeExtensible(&bytes);
    std.mem.writeInt(u16, bytes[14..16], 20, .little);
    try std.testing.expectError(error.OddSampleSize, Format.decode(&bytes));

    _ = good.encodeExtensible(&bytes);
    std.mem.writeInt(u16, bytes[18..20], 48, .little); // valid > container
    try std.testing.expectError(error.ValidBitsTooLarge, Format.decode(&bytes));

    _ = good.encodeExtensible(&bytes);
    std.mem.writeInt(u16, bytes[0..2], 0x0055, .little); // WAVE_FORMAT_MPEGLAYER3
    try std.testing.expectError(error.UnsupportedFormatTag, Format.decode(&bytes));

    _ = good.encodeExtensible(&bytes);
    bytes[24] = 0x99; // a subtype that is neither PCM nor float
    try std.testing.expectError(error.UnsupportedSubformat, Format.decode(&bytes));
}

test "zero valid bits means the whole container" {
    // What a driver writes when it has nothing to narrow. Reading it literally
    // would make a 32-bit stream look like a zero-bit one.
    var bytes: [extensible_len]u8 align(8) = undefined;
    const fmt: Format = .{ .rate = 48000, .channels = 2, .sample = .f32 };
    _ = fmt.encodeExtensible(&bytes);
    std.mem.writeInt(u16, bytes[18..20], 0, .little);

    const decoded = try Format.decode(&bytes);
    try std.testing.expectEqual(Sample.f32, decoded.sample);
}

test "the two subtype guids differ only in their first byte" {
    // Which is exactly why they are written out with the bytes labelled: a
    // transposition in the tail would be invisible by eye and would make every
    // format this library offers unsupported.
    try std.testing.expectEqual(@as(u8, 0x01), subtype_pcm[0]);
    try std.testing.expectEqual(@as(u8, 0x03), subtype_ieee_float[0]);
    try std.testing.expectEqualSlices(u8, subtype_pcm[1..], subtype_ieee_float[1..]);
}

test "sample sizes and the arithmetic built on them" {
    try std.testing.expectEqual(@as(u16, 2), Sample.i16.containerBytes());
    try std.testing.expectEqual(@as(u16, 3), Sample.i24_packed.containerBytes());
    try std.testing.expectEqual(@as(u16, 4), Sample.i24_in_32.containerBytes());
    try std.testing.expectEqual(@as(u16, 24), Sample.i24_in_32.validBits());
    try std.testing.expectEqual(@as(u16, 32), Sample.f32.validBits());

    const fmt: Format = .{ .rate = 48000, .channels = 6, .sample = .i16 };
    try std.testing.expectEqual(@as(u16, 12), fmt.blockAlign());
    try std.testing.expectEqual(@as(u32, 576000), fmt.avgBytesPerSec());
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), fmt.framesToNs(48000));
}

test "24 valid bits in 32 is not the same sample type as 32 in 32" {
    // The distinction a decoder loses if it only looks at the container: an
    // endpoint asking for 24-in-32 and given full-scale 32-bit samples plays
    // the low byte as noise.
    try std.testing.expectEqual(Sample.i24_in_32, Sample.fromBits(false, 32, 24).?);
    try std.testing.expectEqual(Sample.i32, Sample.fromBits(false, 32, 32).?);
    try std.testing.expectEqual(Sample.i24_packed, Sample.fromBits(false, 24, 24).?);
    try std.testing.expectEqual(Sample.f32, Sample.fromBits(true, 32, 32).?);

    // And the combinations that are not real.
    try std.testing.expectEqual(@as(?Sample, null), Sample.fromBits(true, 64, 64));
    try std.testing.expectEqual(@as(?Sample, null), Sample.fromBits(false, 8, 8));
    try std.testing.expectEqual(@as(?Sample, null), Sample.fromBits(false, 16, 12));
}

test "a format prints legibly" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "48000 Hz, 2 ch, f32, mask 0x3",
        try std.fmt.bufPrint(&buf, "{f}", .{
            Format{ .rate = 48000, .channels = 2, .sample = .f32, .mask = 0x3 },
        }),
    );
    try std.testing.expectEqualStrings(
        "44100 Hz, 2 ch, i16",
        try std.fmt.bufPrint(&buf, "{f}", .{
            Format{ .rate = 44100, .channels = 2, .sample = .i16 },
        }),
    );
}

test "formats differing only in layout are not equal" {
    // 5.1 with rear speakers and 5.1 with side speakers have the same rate,
    // channel count and sample type, and interleave differently.
    const back: Format = .{ .rate = 48000, .channels = 6, .sample = .f32, .mask = 0x3F };
    const side: Format = .{ .rate = 48000, .channels = 6, .sample = .f32, .mask = 0x60F };
    try std.testing.expect(!back.eql(side));
    try std.testing.expect(back.eql(back));
}

test {
    std.testing.refAllDecls(@This());
}
