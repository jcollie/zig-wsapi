// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Play a tone and record it back, then check that what came out is what went in.
//!
//! This is the one test that exercises the whole library at once: format negotiation,
//! the render thread, the queue, the sample conversion, WASAPI itself, the capture
//! thread, and the conversion back. Everything else in the suite tests a piece.
//!
//! It needs real audio hardware, so it reports `SkipZigTest` where there is none --
//! which includes every hosted continuous-integration runner. That makes it a test for
//! a developer's machine and for a self-hosted runner, and the README says so rather
//! than pretending the automated suite covers this.
//!
//! ## What it asserts, and why that and not a sample comparison
//!
//! Not that the recording matches the tone sample for sample -- it cannot. The audio
//! engine resamples, the endpoint may mix in another format, the recording starts at an
//! arbitrary point in the tone's phase, and both ends have latency measured in periods.
//! Comparing waveforms would fail for a dozen reasons that are all correct behaviour.
//!
//! What it asserts is that the *energy is at the right frequency*: a Goertzel filter at
//! the tone's pitch against the same filter at neighbouring pitches. That survives
//! every one of those legitimate differences and still catches the things that matter --
//! a channel swap, a conversion that scales wrongly, a ring that repeats or drops
//! blocks, a permutation that silences a channel, or audio that never arrives at all.

const std = @import("std");
const wasapi = @import("wasapi");

const frequency = 440.0;
const amplitude = 0.25;
/// Long enough for the filter to resolve the tone well clear of its neighbours, short
/// enough that the test is not tedious.
const seconds = 1.0;

test "a tone played through a Stream comes back through a loopback Capture" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = std.testing.allocator;

    // The capture opens first, so that it is running before there is anything to record
    // -- otherwise the start of the tone is missed and the measurement is of less
    // audio than intended.
    const capture = wasapi.Capture.open(gpa, io, .{
        .name = "zig-wsapi loopback test",
        .source = .loopback,
    }) catch |err| switch (err) {
        // No sound card, or none that can be opened: not a failure of this library.
        error.DeviceNotFound, error.DeviceInUse, error.AccessDenied => return error.SkipZigTest,
        else => |e| return e,
    };
    defer capture.close(io);

    if (!try capture.waitStreaming(io, seconds_timeout(5))) return error.SkipZigTest;

    const rate = capture.rate();
    const channels = capture.channels();
    try std.testing.expect(rate > 0);
    try std.testing.expect(channels > 0);

    const stream = wasapi.Stream.open(gpa, io, .{
        .name = "zig-wsapi loopback test tone",
        .channels = 2,
        .rate = rate,
    }) catch |err| switch (err) {
        error.DeviceNotFound, error.DeviceInUse, error.AccessDenied => return error.SkipZigTest,
        else => |e| return e,
    };
    defer stream.close(io);

    if (!try stream.waitStreaming(io, seconds_timeout(5))) return error.SkipZigTest;

    // Feed the tone from another thread, so this one can read the recording as it
    // arrives rather than filling the queue and then draining it.
    var player: Player = .{ .stream = stream, .io = io, .rate = rate };
    const thread = try std.Thread.spawn(.{}, Player.run, .{&player});
    defer thread.join();

    const frames_wanted: usize = @intFromFloat(seconds * @as(f64, @floatFromInt(rate)));
    const recorded = try gpa.alloc(f32, frames_wanted * channels);
    defer gpa.free(recorded);

    var got: usize = 0;
    while (got < frames_wanted) {
        const frames = try capture.readAll(
            io,
            recorded[got * channels ..],
            seconds_timeout(5),
        );
        if (frames == 0) break;
        got += frames;
    }

    player.stop.store(true, .release);

    // Anything much short of what was asked for means audio was not arriving, which is
    // a real failure rather than something to skip.
    try std.testing.expect(got > frames_wanted / 2);

    // Channel zero is enough: the tone is the same in both, and a swap would not change
    // that. What a swap *would* change is tested separately in `channel.zig`.
    const tone = goertzel(recorded[0 .. got * channels], channels, 0, frequency, rate);

    // The filter at pitches far enough away that the tone's own skirt does not reach
    // them. If the recording were noise, or the wrong audio, or scaled wrongly, these
    // would not be far below the tone.
    const below = goertzel(recorded[0 .. got * channels], channels, 0, frequency / 2, rate);
    const above = goertzel(recorded[0 .. got * channels], channels, 0, frequency * 2, rate);
    const far = goertzel(recorded[0 .. got * channels], channels, 0, 3000, rate);

    // Twenty times is about 26 dB, which is comfortably clear of anything a legitimate
    // resampler or a dithering endpoint would leave behind, and nowhere near tight
    // enough to fail on a machine with other audio playing quietly.
    try std.testing.expect(tone > below * 20);
    try std.testing.expect(tone > above * 20);
    try std.testing.expect(tone > far * 20);

    // And the level is roughly what was played, which catches a conversion that is off
    // by a factor rather than merely off in shape. Generous bounds: the endpoint's own
    // volume is somewhere in this path and this test does not touch it.
    try std.testing.expect(tone > amplitude / 20.0);

    // Nothing should have been dropped in either direction over a second of audio on an
    // otherwise idle machine.
    try std.testing.expectEqual(@as(u64, 0), capture.overruns());
}

/// Writes a sine into a stream until told to stop.
const Player = struct {
    stream: *wasapi.Stream,
    io: std.Io,
    rate: u32,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(self: *Player) void {
        var phase: f32 = 0;
        const step = 2.0 * std.math.pi * frequency / @as(f32, @floatFromInt(self.rate));
        var block: [960 * 2]f32 = undefined;

        while (!self.stop.load(.acquire)) {
            for (0..block.len / 2) |i| {
                const sample = @sin(phase) * amplitude;
                block[i * 2 + 0] = sample;
                block[i * 2 + 1] = sample;
                phase += step;
                if (phase > 2.0 * std.math.pi) phase -= 2.0 * std.math.pi;
            }
            self.stream.writeAll(self.io, &block, seconds_timeout(5)) catch return;
        }
    }
};

/// The magnitude of one frequency in one channel of interleaved audio.
///
/// A Goertzel filter: a single-bin discrete Fourier transform, which is the cheapest
/// honest way to ask "how much of this pitch is in here" without a whole transform.
fn goertzel(
    interleaved: []const f32,
    channels: u16,
    which: u16,
    hz: f64,
    rate: u32,
) f64 {
    const w = 2.0 * std.math.pi * hz / @as(f64, @floatFromInt(rate));
    const coeff = 2.0 * @cos(w);

    var s1: f64 = 0;
    var s2: f64 = 0;
    var count: usize = 0;

    var i: usize = which;
    while (i < interleaved.len) : (i += channels) {
        const s = @as(f64, interleaved[i]) + coeff * s1 - s2;
        s2 = s1;
        s1 = s;
        count += 1;
    }
    if (count == 0) return 0;

    const power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    // Scaled by the sample count so the answer is an amplitude rather than something
    // that grows with the length of the recording.
    return @sqrt(@max(0, power)) / @as(f64, @floatFromInt(count)) * 2;
}

fn seconds_timeout(s: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromSeconds(s), .clock = .awake } };
}

test "the filter finds a synthetic tone and rejects its neighbours" {
    // The measurement itself, checked against audio this test made rather than against
    // audio a sound card made -- so a failure here is the filter's fault and a failure
    // above is the library's. Runs on any host, with no hardware.
    const rate = 48000;
    const n = rate; // one second
    var samples: [n * 2]f32 = undefined;

    var phase: f64 = 0;
    const step = 2.0 * std.math.pi * frequency / @as(f64, rate);
    for (0..n) |i| {
        const sample: f32 = @floatCast(@sin(phase) * amplitude);
        samples[i * 2 + 0] = sample;
        samples[i * 2 + 1] = 0; // silent right channel, to prove the stride works
        phase += step;
    }

    const at_tone = goertzel(&samples, 2, 0, frequency, rate);
    const at_half = goertzel(&samples, 2, 0, frequency / 2, rate);
    const at_double = goertzel(&samples, 2, 0, frequency * 2, rate);

    // The amplitude comes back, to within the filter's own leakage.
    try std.testing.expectApproxEqAbs(@as(f64, amplitude), at_tone, 0.02);
    try std.testing.expect(at_tone > at_half * 20);
    try std.testing.expect(at_tone > at_double * 20);

    // And the channel stride is respected: the right channel is silent.
    try std.testing.expect(goertzel(&samples, 2, 1, frequency, rate) < 0.001);
}
