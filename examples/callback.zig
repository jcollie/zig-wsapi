// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Play a chord through the pull API: a `Process` callback filling one plane per
//! channel, once per graph cycle.
//!
//! ```console
//! $ zig build run-chord -- 3
//! 48000 Hz, 2 ch, f32, mask 0x3, 480 frame period
//! playing an A major triad for 3 s from the process callback
//!   612 cycles, period 10000 us, wake 0/181/2210 us, busy 21/34/96 us
//! ```
//!
//! The difference from `tone.zig` is where the audio comes from: there is no queue
//! and no writing thread, and the callback runs inside the graph cycle that plays
//! what it produces. That is the lower-latency shape, and the one a synthesiser
//! wants -- at the cost of having to produce audio on the engine's schedule and
//! inside its deadline.

const std = @import("std");
const wasapi = @import("wasapi");

/// Three sine oscillators: A4, and the major third and fifth above it.
///
/// Quiet enough that three of them together do not clip -- 0.15 each peaks at 0.45
/// when the phases line up, which they do at the start.
const Chord = struct {
    phases: [3]f32 = @splat(0),
    steps: [3]f32,

    const frequencies = [3]f32{ 440.0, 554.365, 659.255 };
    const amplitude = 0.15;

    fn init(rate: u32) Chord {
        var steps: [3]f32 = undefined;
        for (&steps, frequencies) |*step, frequency| {
            step.* = 2.0 * std.math.pi * frequency / @as(f32, @floatFromInt(rate));
        }
        return .{ .steps = steps };
    }

    /// The callback. Runs on the render thread, against a real-time deadline: no
    /// allocation, no locks, no input or output. Three multiply-adds per sample is
    /// comfortably inside that.
    fn fill(ctx: *anyopaque, planes: []const []f32, frames: u32) void {
        const self: *Chord = @ptrCast(@alignCast(ctx));

        for (0..frames) |i| {
            var sample: f32 = 0;
            for (&self.phases, self.steps) |*phase, step| {
                sample += @sin(phase.*) * amplitude;
                phase.* += step;
                if (phase.* > 2.0 * std.math.pi) phase.* -= 2.0 * std.math.pi;
            }
            // Every plane must be filled completely; whatever is left unwritten is
            // whatever the previous cycle put there.
            for (planes) |plane| plane[i] = sample;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const seconds: i64 = if (args.len > 1) std.fmt.parseInt(i64, args[1], 10) catch 3 else 3;

    // The oscillators have to know the rate, and the rate is not known until the
    // stream is open -- so the callback is pointed at storage that outlives both and
    // is filled in once the stream has said.
    var chord: Chord = .init(48000);

    const stream = try wasapi.Stream.open(gpa, io, .{
        .name = "zig-wsapi chord",
        .channels = 2,
        .rate = 48000,
        .process = .{ .ctx = &chord, .func = &Chord.fill },
    });
    defer stream.close(io);

    if (!try stream.waitStreaming(io, timeout(5))) {
        try stdout.print("the stream never started\n", .{});
        return;
    }

    // The endpoint may have settled on another rate, in which case the oscillators
    // were stepping at the wrong one for the first cycle or two. Retuning here costs
    // nothing and keeps the pitch right.
    if (stream.rate() != 48000) chord = .init(stream.rate());

    try stdout.print("{f}, {d} frame period\n", .{ stream.endpointFormat(), stream.quantum() });
    try stdout.print("playing an A major triad for {d} s from the process callback\n", .{seconds});
    try stdout.flush();

    // Pull mode has nothing to write, so this is simply how long to let it run.
    try io.sleep(.fromSeconds(seconds), .awake);

    try stdout.print("  {f}\n", .{stream.stats()});
}

fn timeout(s: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(s), .clock = .awake } };
}
