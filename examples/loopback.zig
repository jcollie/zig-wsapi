// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Record what this machine is playing into a WAV file.
//!
//! ```console
//! $ zig build run-loopback -- 5 out.wav
//! recording Speakers (High Definition Audio Device) for 5 s
//!   48000 Hz, 2 ch, f32, mask 0x3
//! wrote out.wav: 240000 frames, 0 lost
//! ```
//!
//! Start some music first, or the recording will be five seconds of silence -- which
//! is itself worth checking, because a loopback capture of an idle endpoint receives
//! no packets at all and the silence has to be manufactured. See
//! `Capture.Options.loopback_silence`.
//!
//! The same program with `.source = .microphone` records the default input instead,
//! which is what `run-record` does.

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
    const path = if (args.len > 2) args[2] else "loopback.wav";

    // `.loopback` opens the *render* endpoint and reads what is being played to it.
    const capture = try wasapi.Capture.open(gpa, io, .{
        .name = "zig-wsapi loopback",
        .source = .loopback,
    });
    defer capture.close(io);

    if (!try capture.waitStreaming(io, timeout(5))) {
        try stdout.print("the capture never started\n", .{});
        return;
    }

    const format = capture.capturedFormat();
    try stdout.print("recording for {d:.0} s\n  {f}\n", .{ seconds, format });
    try stdout.flush();

    var file: wav.Writer = try .create(io, .cwd(), path, .{
        .rate = format.rate,
        .channels = format.channels,
    });
    errdefer _ = file.finish(io) catch {};

    // A tenth of a second at a time: large enough that the file writing is not the
    // bottleneck, small enough that the queue never fills.
    const channels = capture.channels();
    var block = try gpa.alloc(f32, @as(usize, format.rate / 10) * channels);
    defer gpa.free(block);

    var frames_left: u64 = @intFromFloat(seconds * @as(f32, @floatFromInt(format.rate)));
    while (frames_left > 0) {
        const wanted: u64 = @min(frames_left, block.len / channels);
        const got = try capture.readAll(io, block[0 .. wanted * channels], timeout(5));
        if (got == 0) break; // the deadline passed with nothing arriving
        try file.write(io, block[0 .. @as(usize, got) * channels]);
        frames_left -= got;
    }

    const frames_written = try file.finish(io);

    try stdout.print("wrote {s}: {d} frames, {d} lost\n", .{
        path,
        frames_written,
        capture.overruns(),
    });
    try stdout.print("  {f}\n", .{capture.stats()});
}

fn timeout(s: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(s), .clock = .awake } };
}
