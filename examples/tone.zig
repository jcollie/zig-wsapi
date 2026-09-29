// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Play a test tone through the push API, then report what the cycles cost.
//!
//! ```console
//! $ zig build run-tone -- 440 2
//! Speakers (High Definition Audio Device)
//!   48000 Hz, 2 ch, f32, mask 0x3, 480 frame period (10.0 ms)
//! playing 440 Hz for 2 s
//!   1000 cycles, period 10000 us, wake 12/48/210 us, busy 30/45/120 us
//!   0 underrun frames
//! ```
//!
//! The arguments are the frequency in hertz and the duration in seconds, both
//! optional.

const std = @import("std");
const wasapi = @import("wasapi");

/// Loud enough to hear, quiet enough not to startle anybody. A full-scale sine
//// through somebody's monitors is a rude way to introduce a library.
const amplitude = 0.2;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const frequency: f32 = if (args.len > 1)
        std.fmt.parseFloat(f32, args[1]) catch 440
    else
        440;
    const seconds: f32 = if (args.len > 2)
        std.fmt.parseFloat(f32, args[2]) catch 2
    else
        2;

    const stream = try wasapi.Stream.open(gpa, io, .{
        .name = "zig-wsapi tone",
        .channels = 2,
        .rate = 48000,
    });
    defer stream.close(io);

    if (!try stream.waitStreaming(io, seconds_timeout(5))) {
        try stdout.print("the stream never started\n", .{});
        return;
    }

    const format = stream.endpointFormat();
    const period = stream.quantum();
    try stdout.print("  {f}, {d} frame period ({d:.1} ms)\n", .{
        format,
        period,
        @as(f64, @floatFromInt(period)) * 1000.0 / @as(f64, @floatFromInt(format.rate)),
    });
    try stdout.print("playing {d:.0} Hz for {d:.0} s\n", .{ frequency, seconds });
    try stdout.flush();

    // A sine, written in blocks. The block size is arbitrary -- the queue is what
    // absorbs the difference between this loop and the audio engine's schedule --
    // so this deliberately uses a size that is not a multiple of any period.
    const rate = stream.rate();
    const channels = 2;
    var block: [1000 * channels]f32 = undefined;

    var phase: f32 = 0;
    const step = 2.0 * std.math.pi * frequency / @as(f32, @floatFromInt(rate));

    var frames_left: u64 = @intFromFloat(seconds * @as(f32, @floatFromInt(rate)));
    while (frames_left > 0) {
        // Explicitly `u64`: `@min` narrows its result type when one operand is
        // comptime-known, which would make `frames * channels` overflow a type
        // just wide enough to hold `frames` alone.
        const frames: u64 = @min(frames_left, block.len / channels);
        for (0..frames) |i| {
            const sample = @sin(phase) * amplitude;
            // The same sample in both channels, which is a mono tone in a stereo
            // stream rather than anything clever.
            block[i * channels + 0] = sample;
            block[i * channels + 1] = sample;
            phase += step;
            if (phase > 2.0 * std.math.pi) phase -= 2.0 * std.math.pi;
        }
        try stream.writeAll(io, block[0 .. frames * channels], seconds_timeout(5));
        frames_left -= frames;
    }

    // Without this the last period or so of audio is still inside the engine when
    // `close` tears the stream down, and the tone ends with a click.
    stream.drain(io, seconds_timeout(5));

    const stats = stream.stats();
    try stdout.print("  {f}\n", .{stats});
    try stdout.print("  {d} underrun frames\n", .{stream.underruns()});
    try stdout.print("  busy at worst {d:.1}% of a period\n", .{
        stats.process.fractionOfPeriod(stats.period_ns) * 100,
    });

    const t = stream.time();
    try stdout.print("  {f}\n", .{t});
}

fn seconds_timeout(s: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(s), .clock = .awake } };
}
