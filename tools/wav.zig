// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Just enough of the WAV container for the recording examples to write a file
//! something else can play.
//!
//! ```zig
//! var writer: wav.Writer = try .create(io, dir, "out.wav", .{ .rate = 48000, .channels = 2 });
//! try writer.write(io, interleaved_frames);
//! const frames = try writer.finish(io);
//! ```
//!
//! Deliberately not part of the library. A WAV writer is not audio plumbing -- it is a
//! file format -- and putting one in `wasapi` would mean every program that depends on
//! the library carries it. The examples need one, so it lives with them.
//!
//! 32-bit float samples, which is what the library hands over, so nothing is converted
//! and nothing is lost. Most players handle float WAV; the ones that do not are old.

const std = @import("std");

/// What a file is being written at.
pub const Format = struct {
    rate: u32,
    channels: u16,
};

pub const Writer = struct {
    file: std.Io.File,
    format: Format,
    /// Frames written, for the two length fields that can only be filled in at the end.
    frames: u64 = 0,

    const header_len = 44;

    /// Create the file and write a placeholder header.
    pub fn create(
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
        format: Format,
    ) !Writer {
        const file = try dir.createFile(io, path, .{});
        var self: Writer = .{ .file = file, .format = format };
        // Written now rather than skipped over, so that a program which dies partway
        // leaves a file a player can at least open.
        try self.writeHeader(io);
        return self;
    }

    /// Append interleaved `f32` frames.
    pub fn write(self: *Writer, io: std.Io, interleaved: []const f32) !void {
        if (interleaved.len == 0) return;
        // Positional rather than streaming, so that `finish` can go back over the
        // header without a seek -- which is the only reason this type tracks its own
        // frame count.
        try self.file.writePositionalAll(
            io,
            std.mem.sliceAsBytes(interleaved),
            self.dataOffset(),
        );
        self.frames += interleaved.len / self.format.channels;
    }

    /// Fill in the lengths, close, and report how many frames were written.
    ///
    /// Returns the count rather than leaving the caller to read `frames`, because this
    /// invalidates the writer -- and a caller reading the field afterwards gets the
    /// undefined pattern, which as a frame count looks like a real and enormous number.
    pub fn finish(self: *Writer, io: std.Io) !u64 {
        try self.writeHeader(io);
        self.file.close(io);
        const written = self.frames;
        self.* = undefined;
        return written;
    }

    /// Where the next block of samples goes.
    fn dataOffset(self: *const Writer) u64 {
        return header_len + self.frames * self.format.channels * 4;
    }

    fn writeHeader(self: *Writer, io: std.Io) !void {
        const bytes_per_sample = 4;
        const block_align: u16 = self.format.channels * bytes_per_sample;
        const data_bytes: u32 = @intCast(self.frames * block_align);

        var header: [header_len]u8 = undefined;
        @memcpy(header[0..4], "RIFF");
        // Everything after this field, which is the file minus the first eight bytes.
        std.mem.writeInt(u32, header[4..8], 36 + data_bytes, .little);
        @memcpy(header[8..12], "WAVE");

        @memcpy(header[12..16], "fmt ");
        std.mem.writeInt(u32, header[16..20], 16, .little); // chunk size
        std.mem.writeInt(u16, header[20..22], 3, .little); // WAVE_FORMAT_IEEE_FLOAT
        std.mem.writeInt(u16, header[22..24], self.format.channels, .little);
        std.mem.writeInt(u32, header[24..28], self.format.rate, .little);
        std.mem.writeInt(u32, header[28..32], self.format.rate * block_align, .little);
        std.mem.writeInt(u16, header[32..34], block_align, .little);
        std.mem.writeInt(u16, header[34..36], bytes_per_sample * 8, .little);

        @memcpy(header[36..40], "data");
        std.mem.writeInt(u32, header[40..44], data_bytes, .little);

        try self.file.writePositionalAll(io, &header, 0);
    }
};

test "samples go after the header, and each block after the last" {
    // The offset arithmetic is the whole of what this type does that could be wrong
    // silently: an off-by-one puts a sample inside the header, and a wrong stride
    // interleaves the file with garbage or overwrites what came before.
    const empty: Writer = .{
        .file = undefined,
        .format = .{ .rate = 48000, .channels = 2 },
    };
    try std.testing.expectEqual(@as(u64, Writer.header_len), empty.dataOffset());

    // One second of stereo float is 384000 bytes, so the next block starts there --
    // plus the header.
    const after_a_second: Writer = .{
        .file = undefined,
        .format = .{ .rate = 48000, .channels = 2 },
        .frames = 48000,
    };
    try std.testing.expectEqual(
        @as(u64, Writer.header_len + 384000),
        after_a_second.dataOffset(),
    );

    // And the stride follows the channel count, not a fixed stereo assumption: a 5.1
    // recording advances three times as fast.
    const surround: Writer = .{
        .file = undefined,
        .format = .{ .rate = 48000, .channels = 6 },
        .frames = 48000,
    };
    try std.testing.expectEqual(
        @as(u64, Writer.header_len + 48000 * 6 * 4),
        surround.dataOffset(),
    );
}

test {
    std.testing.refAllDecls(@This());
}
