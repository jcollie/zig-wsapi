// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Record the default microphone into a WAV file, showing a level meter as it goes.
//!
//! ```console
//! $ zig build run-record -- 5 voice.wav
//! recording Microphone Array (Realtek(R) Audio)
//!   48000 Hz, 2 ch, f32, mask 0x3
//!   [########################                        ] -12.4 dB
//! wrote voice.wav: 240000 frames, 0 lost
//! ```
//!
//! The only difference from `loopback.zig` is `.source = .microphone`. Everything else --
//! the queue, the reading, the conversion -- is the same code.
//!
//! Windows will refuse this if microphone access is switched off in the privacy settings,
//! which arrives as `error.AccessDenied`. That is a setting rather than a fault, so it is
//! reported as such rather than as a failure of the audio stack.

const std = @import("std");
const wasapi = @import("wasapi");
const wav = @import("wav");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const seconds: f32 = if (args.len > 1)
        std.fmt.parseFloat(f32, args[1]) catch 5
    else
        5;
    const path = if (args.len > 2) args[2] else "record.wav";

    const capture = wasapi.Capture.open(gpa, io, .{
        .name = "zig-wsapi record",
        .source = .microphone,
    }) catch |err| switch (err) {
        error.AccessDenied => {
            try stdout.print(
                "microphone access is switched off for this machine or this program;\n" ++
                    "Settings > Privacy & security > Microphone controls it\n",
                .{},
            );
            return;
        },
        error.DeviceNotFound => {
            try stdout.print("this machine has no capture endpoint\n", .{});
            return;
        },
        else => |e| return e,
    };
    defer capture.close(io);

    if (!try capture.waitStreaming(io, timeout(5))) {
        try stdout.print("the capture never started\n", .{});
        return;
    }

    const format = capture.capturedFormat();
    try stdout.print("recording\n  {f}\n", .{format});
    try stdout.flush();

    var file: wav.Writer = try .create(io, .cwd(), path, .{
        .rate = format.rate,
        .channels = format.channels,
    });
    errdefer _ = file.finish(io) catch {};

    const channels = capture.channels();
    const block = try gpa.alloc(f32, @as(usize, format.rate / 10) * channels);
    defer gpa.free(block);

    var frames_left: u64 = @intFromFloat(seconds * @as(f32, @floatFromInt(format.rate)));
    while (frames_left > 0) {
        const wanted: u64 = @min(frames_left, block.len / channels);
        const got = try capture.readAll(io, block[0 .. wanted * channels], timeout(5));
        if (got == 0) break;

        const samples = block[0 .. @as(usize, got) * channels];
        try file.write(io, samples);
        frames_left -= got;

        // A level meter, redrawn in place. Peak rather than average, because that is what
        // tells somebody whether they are about to clip.
        try drawMeter(stdout, peakOf(samples));
        try stdout.flush();
    }

    const frames_written = try file.finish(io);
    try stdout.print("\nwrote {s}: {d} frames, {d} lost\n", .{
        path,
        frames_written,
        capture.overruns(),
    });
}

fn peakOf(samples: []const f32) f32 {
    var peak: f32 = 0;
    for (samples) |s| peak = @max(peak, @abs(s));
    return peak;
}

fn drawMeter(stdout: *std.Io.Writer, peak: f32) !void {
    const width = 48;
    // Decibels rather than the raw amplitude, because hearing is logarithmic and a linear
    // meter spends most of its length on sounds nobody can hear.
    const db: f32 = if (peak > 0) 20.0 * @log10(peak) else -120.0;
    // A 60 dB window, which is what a recording meter conventionally shows.
    const filled: usize = @intFromFloat(std.math.clamp(
        (db + 60.0) / 60.0 * @as(f32, width),
        0,
        @as(f32, width),
    ));

    try stdout.print("\r  [", .{});
    for (0..width) |i| try stdout.writeByte(if (i < filled) '#' else ' ');
    if (peak > 0) {
        try stdout.print("] {d:>6.1} dB", .{db});
    } else {
        try stdout.print("]   silent", .{});
    }
}

fn timeout(s: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(s), .clock = .awake } };
}
