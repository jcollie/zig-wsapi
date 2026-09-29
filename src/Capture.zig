// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Recording: from a microphone, or from whatever the machine is playing.
//!
//! ```zig
//! const capture = try wasapi.Capture.open(gpa, io, .{ .source = .microphone });
//! defer capture.close(io);
//!
//! var frames: [4800 * 2]f32 = undefined;
//! while (recording) {
//!     const got = try capture.readAll(io, &frames, timeout);
//!     try wav.write(frames[0 .. got * capture.channels()]);
//! }
//! ```
//!
//! ## Loopback: recording the output
//!
//! `source = .loopback` records what a *render* endpoint is playing -- everything the
//! machine is making, mixed. It is how a program records system audio without a
//! virtual cable, and it is one of the few things Windows does more simply than
//! PipeWire, where the equivalent is a monitor port on a sink.
//!
//! Two things about it are surprising enough to need saying:
//!
//!   * **It is activated on the output endpoint, not an input one.** Passing a capture
//!     endpoint gets `AUDCLNT_E_WRONG_ENDPOINT_TYPE`. `Options.source` takes care of
//!     that, which is why it is an enumeration rather than a `loopback: bool` beside a
//!     device selector that could name the wrong kind of device.
//!   * **An idle endpoint delivers nothing at all** -- not silence, *nothing*. No
//!     packets arrive, so a recording of a quiet machine would be shorter than the
//!     time it covered, and anything lining audio up against a clock would drift. The
//!     two options below deal with that, and both default to on.
//!
//! ## How much this shares with `Stream`
//!
//! The activation, the format negotiation, the sample conversion, the queue and the
//! real-time thread are all the same code -- `com/activate.zig`, `mix.zig`, `Ring` and
//! the same waiting scheme. What differs is the direction and the two loopback
//! problems above. So the documentation in `Stream` about the render thread, about
//! nothing being allocated after `open`, and about why the waits poll applies here
//! unchanged.

const Capture = @This();

const std = @import("std");

const Allocator = std.mem.Allocator;

const channel = @import("channel.zig");
const errors = @import("errors.zig");
const format_mod = @import("format.zig");
const mix = @import("mix.zig");
const stats_mod = @import("stats.zig");
const time_mod = @import("time.zig");
const wait = @import("wait.zig");
const Log = @import("log.zig").Log;
const Ring = @import("Ring.zig");
const Stream = @import("Stream.zig");

const com = @import("com/com.zig");
const activate = @import("com/activate.zig");

const log = std.log.scoped(.wasapi);

const win32 = @import("win32").everything;

pub const Format = format_mod.Format;
pub const State = Stream.State;
pub const Stats = stats_mod.Stats;

/// Where the audio comes from.
pub const Source = enum {
    /// A capture endpoint: a microphone, a line input, a webcam's microphone.
    microphone,
    /// A render endpoint's output: everything the machine is playing, mixed.
    loopback,

    fn flow(self: Source) com.Flow {
        return switch (self) {
            .microphone => .capture,
            // Loopback is activated on the *output* endpoint. Getting this backwards
            // is `AUDCLNT_E_WRONG_ENDPOINT_TYPE`.
            .loopback => .render,
        };
    }
};

/// Push-mode audio sink: the capture counterpart of `Stream.Process`.
///
/// Called once per graph cycle with the frames that arrived, one slice per channel.
/// Runs on the capture thread, against a real-time deadline: no allocation, no locks,
/// no file or network access -- so a program writing a recording to disk should queue
/// through `read` instead of doing the writing here.
pub const Process = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, planes: []const []const f32, frames: u32) void,
};

pub const Options = struct {
    name: []const u8 = "zig-windows-audio",

    source: Source = .microphone,

    /// Channels to deliver. The endpoint's own count is used when this is null, which
    /// is usually what a recording wants -- a microphone is mono and asking for stereo
    /// would duplicate it.
    channels: ?u16 = null,

    /// The rate to ask for, or null for the endpoint's own -- which for a recording is
    /// almost always right, since resampling on the way in loses information for no
    /// benefit.
    rate: ?u32 = null,

    /// Which endpoint: an id, a substring of a friendly name, or null for the default.
    /// For `.loopback` this names the *output* being recorded.
    target: ?[]const u8 = null,

    /// Frames the queue holds. Bigger than a playback queue by default, because a
    /// program that writes recordings to a file does so in large, irregular bursts.
    ring_frames: u32 = 48000,

    /// Deliver audio by callback instead of queueing it for `read`.
    process: ?Process = null,

    /// Fill gaps in a loopback recording with silence, so the recording's length
    /// matches the time it covers.
    ///
    /// An idle output endpoint delivers no packets at all, so without this a recording
    /// of a machine that was quiet for ten seconds is ten seconds shorter than
    /// expected, and everything after the gap is early. With it, the elapsed time is
    /// measured and the missing frames are written as zeroes.
    ///
    /// Ignored for `.microphone`, which always delivers.
    loopback_silence: bool = true,

    /// Keep the recorded output endpoint awake by playing silence to it.
    ///
    /// The documented way to stop an idle endpoint from suspending underneath a
    /// loopback capture: open a second, silent render stream on the same device. It
    /// costs one more audio client and one more thread, and it means the endpoint
    /// never idles while recording -- which on a laptop is a small amount of battery.
    ///
    /// Without it, `loopback_silence` still keeps the timeline honest; this makes the
    /// packets keep arriving in the first place.
    keep_endpoint_active: bool = true,

    max_period_frames: u32 = 4096,
    open_timeout: std.Io.Timeout = .{
        .duration = .{ .raw = .fromSeconds(5), .clock = .awake },
    },
    log: ?Log = null,
};

gpa: Allocator,
options: Options,
strings: []u8,

ring: Ring,
/// Staging for the conversion out of the endpoint's sample type, and for the
/// per-channel planes a `Process` is handed.
stage: []f32,
planes: []f32,
plane_slices: [][]const f32,

event: com.Event,
clock: com.Clock,
thread: ?std.Thread = null,

/// The silent playback stream that keeps a loopback endpoint awake, if one was asked
/// for. Opened after the capture so that it lands on the same endpoint.
keeper: ?*Stream = null,

state: std.atomic.Value(State) = .init(.idle),
stop: std.atomic.Value(bool) = .init(false),
/// Frames the queue could not hold, which for a recording is data actually lost --
/// unlike a playback underrun, which is merely heard.
overrun_frames: std.atomic.Value(u64) = .init(0),

stats_cell: stats_mod.Cell = .{},

open_result: std.atomic.Value(OpenResult) = .init(.pending),
open_error: errors.OpenError = error.Unexpected,
negotiated: Format = .{ .rate = 0, .channels = 0, .sample = .f32 },
period_frames: u32 = 0,

const OpenResult = enum(u8) { pending, ok, failed };

/// Open a capture stream.
pub fn open(gpa: Allocator, io: std.Io, options: Options) errors.OpenError!*Capture {
    if (options.channels) |n| {
        if (n == 0 or n > channel.max_channels) return error.TooManyChannels;
    }
    if (options.max_period_frames == 0) return error.InvalidRate;

    const self = try allocate(gpa, options);
    // One teardown for everything past this point; see the same comment in
    // `Stream.open` for why a cleanup call at each failure site would double-free.
    errdefer {
        self.shutdown();
        self.freeOwned();
        gpa.destroy(self);
    }

    self.thread = std.Thread.spawn(
        .{ .stack_size = 512 * 1024 },
        captureMain,
        .{self},
    ) catch return error.ThreadSpawnFailed;

    wait.until(io, options.open_timeout, self, openSettled, .{}) catch |err| switch (err) {
        error.Timeout, error.Canceled => return error.Unexpected,
        error.StreamFailed => return self.open_error,
    };

    // Only once the capture is running, and only for loopback: the silent stream has
    // to land on the endpoint that is being recorded, and naming it by id is the only
    // way to be certain it does.
    if (self.options.source == .loopback and self.options.keep_endpoint_active) {
        self.startKeeper(io) catch |err| {
            // Not fatal. The recording still works; an idle endpoint may simply stop
            // delivering, which `loopback_silence` covers.
            log.warn("could not keep the endpoint awake: {t}", .{err});
        };
    }

    return self;
}

/// Allocate everything a capture owns, or nothing.
///
/// Split out for the same reason as `Stream.allocate`: so the partial-allocation
/// `errdefer`s end here rather than staying armed through the open handshake.
fn allocate(gpa: Allocator, options: Options) errors.OpenError!*Capture {
    const self = try gpa.create(Capture);
    errdefer gpa.destroy(self);

    var strings: std.ArrayList(u8) = .empty;
    errdefer strings.deinit(gpa);
    try strings.appendSlice(gpa, options.name);
    const name_end = strings.items.len;
    if (options.target) |t| try strings.appendSlice(gpa, t);
    const target_end = strings.items.len;
    const strings_block = try strings.toOwnedSlice(gpa);
    errdefer gpa.free(strings_block);

    // The endpoint's channel count is not known until the capture thread has
    // negotiated, so every buffer is sized for the most this library will carry.
    const stage_samples = @as(usize, options.max_period_frames) * channel.max_channels;
    const stage = try gpa.alloc(f32, stage_samples);
    errdefer gpa.free(stage);
    const planes = try gpa.alloc(f32, stage_samples);
    errdefer gpa.free(planes);
    const plane_slices = try gpa.alloc([]const f32, channel.max_channels);
    errdefer gpa.free(plane_slices);

    const event: com.Event = try .create();

    self.* = .{
        .gpa = gpa,
        .options = options,
        .strings = strings_block,
        // Sized by the capture thread once the endpoint has said how many channels it
        // delivers. A queue built here would have to guess, and a `Ring` whose channel
        // count is not the real one mis-frames every push and pop -- silently, since
        // the arithmetic still divides evenly.
        .ring = .empty,
        .stage = stage,
        .planes = planes,
        .plane_slices = plane_slices,
        .event = event,
        .clock = .init(),
    };
    self.options.name = strings_block[0..name_end];
    self.options.target = if (options.target != null) strings_block[name_end..target_end] else null;
    return self;
}

pub fn close(self: *Capture, io: std.Io) void {
    if (self.keeper) |keeper| {
        keeper.close(io);
        self.keeper = null;
    }
    self.shutdown();
    const gpa = self.gpa;
    self.freeOwned();
    gpa.destroy(self);
}

fn shutdown(self: *Capture) void {
    self.stop.store(true, .release);
    self.event.set();
    if (self.thread) |thread| {
        thread.join();
        self.thread = null;
    }
}

fn freeOwned(self: *Capture) void {
    self.ring.deinit(self.gpa);
    self.gpa.free(self.plane_slices);
    self.gpa.free(self.planes);
    self.gpa.free(self.stage);
    self.gpa.free(self.strings);
    self.event.deinit();
    self.* = undefined;
}

fn openSettled(self: *Capture) wait.Ready {
    return switch (self.open_result.load(.acquire)) {
        .pending => .no,
        .ok => .yes,
        .failed => .failed,
    };
}

/// Open a silent playback stream on the endpoint being recorded, to stop it idling.
fn startKeeper(self: *Capture, io: std.Io) errors.OpenError!void {
    var apartment: com.Apartment = try .enter(com.coinit_multithreaded);
    defer apartment.leave();

    var enumerator: com.Enumerator = try .create();
    defer enumerator.deinit();

    var device = try activate.selectEndpoint(enumerator, .{
        .flow = .render,
        .role = .console,
        .target = self.options.target,
        .rate = self.negotiated.rate,
        .channels = self.negotiated.channels,
    });
    defer device.deinit();

    var id_buf: [com.Endpoint.max_id_len]u8 = undefined;
    const id = device.id(&id_buf) catch return error.Unexpected;

    // A paused stream is exactly what is wanted: it holds the endpoint open without
    // contributing any audio, and `pause` is what tells Windows the stream wants to
    // exist without being scheduled.
    const keeper = try Stream.open(self.gpa, io, .{
        .name = "zig-windows-audio loopback keeper",
        .channels = 2,
        .rate = self.negotiated.rate,
        .target = id,
        // Naming a target already turns following off, but saying so is clearer than
        // relying on it.
        .follow_default = false,
        .log = self.options.log,
    });
    self.keeper = keeper;
}

// --- reading audio ---

/// Take up to `out.len / channels()` frames. Returns how many whole frames were
/// written; the rest of `out` is untouched. Never blocks.
///
/// Only one thread may call this: the queue is single-producer, single-consumer.
pub fn read(self: *Capture, out: []f32) u32 {
    if (self.options.process != null) return 0;
    return self.ring.pop(out);
}

/// Fill `out` completely, waiting for audio to arrive.
///
/// Returns the number of frames written, which is `out.len / channels()` unless the
/// deadline passed first -- so a short return is a timeout rather than an error, which
/// is what a recording loop wants.
pub fn readAll(
    self: *Capture,
    io: std.Io,
    out: []f32,
    timeout: std.Io.Timeout,
) errors.ReadError!u32 {
    if (self.options.process != null) return error.WrongMode;

    const frame_samples = self.channels();
    if (frame_samples == 0) return 0;
    const wanted: u32 = @intCast(out.len / frame_samples);

    var got: u32 = 0;
    const deadline = timeout.toDeadline(io);

    while (got < wanted) {
        got += self.ring.pop(out[@as(usize, got) * frame_samples ..]);
        if (got >= wanted) break;

        wait.until(io, deadline, self, hasAudio, wait.paramsForPeriod(self.periodNs())) catch |err|
            switch (err) {
                error.StreamFailed => return error.NotConnected,
                // A short read on a timeout: the caller gets what arrived.
                error.Timeout => return got,
                error.Canceled => return error.Canceled,
            };
    }
    return got;
}

fn hasAudio(self: *Capture) wait.Ready {
    if (self.state.load(.acquire) == .failed) return .failed;
    return if (self.ring.queued() > 0) .yes else .no;
}

/// Frames waiting to be read.
pub fn available(self: *Capture) u32 {
    if (self.options.process != null) return 0;
    return self.ring.queued();
}

/// Frames that arrived and had nowhere to go, because the queue was full.
///
/// Unlike a playback underrun this is *lost data*, not merely a moment of silence, so
/// a recording with a non-zero count here has a gap in it. The fix is a larger
/// `ring_frames` or a faster reader.
pub fn overruns(self: *Capture) u64 {
    return self.overrun_frames.load(.acquire);
}

// --- introspection ---

pub fn rate(self: *const Capture) u32 {
    return self.negotiated.rate;
}

/// Channels the captured frames have. Zero before the first cycle.
pub fn channels(self: *const Capture) u16 {
    return self.negotiated.channels;
}

pub fn capturedFormat(self: *const Capture) Format {
    return self.negotiated;
}

pub fn quantum(self: *const Capture) u32 {
    return self.period_frames;
}

pub fn getState(self: *const Capture) State {
    return self.state.load(.acquire);
}

pub fn stats(self: *const Capture) Stats {
    return self.stats_cell.load();
}

pub fn waitStreaming(
    self: *Capture,
    io: std.Io,
    timeout: std.Io.Timeout,
) std.Io.Cancelable!bool {
    wait.until(io, timeout, self, isStreaming, .{}) catch |err| switch (err) {
        error.Timeout, error.StreamFailed => return false,
        error.Canceled => return error.Canceled,
    };
    return true;
}

fn isStreaming(self: *Capture) wait.Ready {
    return switch (self.state.load(.acquire)) {
        .streaming => .yes,
        .failed => .failed,
        .idle => .no,
    };
}

fn periodNs(self: *const Capture) u64 {
    if (self.period_frames == 0 or self.negotiated.rate == 0) return 0;
    return time_mod.framesToNs(self.period_frames, self.negotiated.rate);
}

// --- the capture thread ---

fn captureMain(self: *Capture) void {
    var apartment = com.Apartment.enter(com.coinit_multithreaded) catch |err| {
        self.failOpen(err);
        return;
    };
    defer apartment.leave();

    var pro_audio: com.ProAudio = .raise();
    defer pro_audio.revert();

    var enumerator = com.Enumerator.create() catch |err| {
        self.failOpen(err);
        return;
    };
    defer enumerator.deinit();

    // The endpoint's own format is what a recording wants, so the request asks for
    // whatever the endpoint mixes at unless the caller said otherwise. Its mix format
    // is not known until the client is activated, so a null rate or channel count is
    // resolved by asking for something the endpoint is certain to accept and letting
    // the negotiation adopt its format.
    var activated = activate.open(enumerator, .{
        .flow = self.options.source.flow(),
        .role = .console,
        .target = self.options.target,
        .rate = self.options.rate orelse 48000,
        .channels = self.options.channels orelse 2,
        .loopback = self.options.source == .loopback,
        .category = .Other,
    }, self.event) catch |err| {
        self.failOpen(err);
        return;
    };
    defer activated.deinit();

    self.negotiated = activated.negotiation.endpoint;
    self.period_frames = activated.period_frames;

    if (self.negotiated.channels > channel.max_channels) {
        self.failOpen(error.TooManyChannels);
        return;
    }

    // Now that the channel count is known, the queue can be sized correctly. This is
    // the one allocation that happens off the calling thread, and it is still before
    // the first cycle -- nothing is allocated once the loop below is running.
    if (self.options.process == null) {
        self.ring = Ring.init(
            self.gpa,
            @max(self.options.ring_frames, 2 * self.options.max_period_frames),
            self.negotiated.channels,
        ) catch {
            self.failOpen(error.OutOfMemory);
            return;
        };
    }

    var accumulator: stats_mod.Accumulator = .{
        .period_ns = time_mod.framesToNs(activated.period_frames, self.negotiated.rate),
    };

    activated.start() catch |err| {
        self.failOpen(err);
        return;
    };

    self.open_result.store(.ok, .release);
    self.state.store(.streaming, .release);

    self.runCapture(&activated, &accumulator);
    activated.stopQuietly();
}

fn failOpen(self: *Capture, err: errors.OpenError) void {
    self.open_error = err;
    self.open_result.store(.failed, .release);
    self.state.store(.failed, .release);
}

fn runCapture(
    self: *Capture,
    activated: *activate.Activated,
    accumulator: *stats_mod.Accumulator,
) void {
    const capture = activated.capture orelse {
        self.state.store(.failed, .release);
        return;
    };

    var last_wake_ticks: u64 = 0;
    const period_ticks = self.clock.nsToTicks(accumulator.period_ns);
    // For `loopback_silence`: when audio was last seen, so a gap can be measured.
    var last_data_ticks = self.clock.ticks();

    while (!self.stop.load(.acquire)) {
        const timeout_ms: u32 = @intCast(std.math.clamp(
            2 * accumulator.period_ns / std.time.ns_per_ms,
            20,
            2000,
        ));
        switch (self.event.wait(timeout_ms)) {
            .signalled => {},
            .timed_out => {
                accumulator.missed_cycles +|= 1;
                // An idle loopback endpoint is *expected* to go quiet, so a timeout
                // there is not a fault -- it is the gap this option exists to fill.
                if (self.fillSilence(&last_data_ticks)) continue;
                continue;
            },
            .failed => {
                self.state.store(.failed, .release);
                return;
            },
        }

        const wake_ticks = self.clock.ticks();

        // The engine may have several packets waiting; take them all before sleeping
        // again, or the queue falls behind and never catches up.
        var drained_any = false;
        while (true) {
            var packet_frames: u32 = 0;
            if (com.failed(capture.GetNextPacketSize(&packet_frames))) break;
            if (packet_frames == 0) break;

            var data: ?*u8 = null;
            var frames: u32 = 0;
            var flags: u32 = 0;
            const hr = capture.GetBuffer(&data, &frames, &flags, null, null);
            if (com.failed(hr)) {
                if (com.eql(hr, win32.AUDCLNT_E_DEVICE_INVALIDATED)) {
                    log.warn("the recorded endpoint went away", .{});
                    self.state.store(.failed, .release);
                    return;
                }
                break;
            }
            // `AUDCLNT_S_BUFFER_EMPTY` is a success meaning there was nothing there.
            if (frames == 0) {
                _ = capture.ReleaseBuffer(0);
                break;
            }

            self.deliver(activated, data, frames, flags);
            _ = capture.ReleaseBuffer(frames);
            drained_any = true;
        }

        if (drained_any) last_data_ticks = self.clock.ticks();

        const done_ticks = self.clock.ticks();
        if (last_wake_ticks != 0 and period_ticks != 0) {
            const interval = wake_ticks -| last_wake_ticks;
            const deviation = if (interval > period_ticks)
                interval - period_ticks
            else
                period_ticks - interval;
            accumulator.record(
                self.clock.deltaNs(0, deviation),
                self.clock.deltaNs(wake_ticks, done_ticks),
            );
        } else {
            accumulator.record(0, self.clock.deltaNs(wake_ticks, done_ticks));
        }
        last_wake_ticks = wake_ticks;

        self.stats_cell.store(accumulator.snapshot());
    }
}

/// Hand one packet to the caller, converting it on the way.
fn deliver(
    self: *Capture,
    activated: *const activate.Activated,
    data: ?*u8,
    frames: u32,
    flags: u32,
) void {
    const endpoint = activated.negotiation.endpoint;
    const channel_count = endpoint.channels;
    const samples = @as(usize, frames) * channel_count;
    if (samples > self.stage.len) return; // a packet larger than was planned for

    const silent = flags & @as(u32, @intCast(@intFromEnum(win32.AUDCLNT_BUFFERFLAGS_SILENT))) != 0;

    if (silent or data == null) {
        // The engine says the buffer is silent and its contents are meaningless, so
        // reading them would record whatever happened to be in the memory.
        mix.silence(self.stage[0..samples]);
    } else {
        const raw: [*]const u8 = @ptrCast(data.?);
        const bytes = @as(usize, frames) * endpoint.blockAlign();
        mix.fromEndpoint(endpoint.sample, self.stage[0..samples], raw[0..bytes]);
    }

    self.publishFrames(self.stage[0..samples], frames, channel_count);
}

fn publishFrames(self: *Capture, interleaved: []const f32, frames: u32, channel_count: u16) void {
    if (self.options.process) |process| {
        // One plane per channel, over the scratch, so the callback sees the same shape
        // `Stream.Process` produces.
        for (0..channel_count) |ch| {
            const plane = self.planes[ch * self.options.max_period_frames ..][0..frames];
            for (0..frames) |f| plane[f] = interleaved[f * channel_count + ch];
            self.plane_slices[ch] = plane;
        }
        process.func(process.ctx, self.plane_slices[0..channel_count], frames);
        return;
    }

    // The ring was allocated at `max_channels` wide, so its idea of a frame is not
    // the endpoint's. Writing whole frames of the endpoint's width means going
    // through the ring's own frame size, which is why the ring is created with
    // `max_channels` and the reader is told the real count through `channels()`.
    const taken = self.ring.push(interleaved);
    if (taken < frames) {
        const lost = frames - taken;
        _ = self.overrun_frames.fetchAdd(lost, .monotonic);
    }
}

/// Write silence for a gap in a loopback recording. Returns whether it did.
fn fillSilence(self: *Capture, last_data_ticks: *u64) bool {
    if (self.options.source != .loopback or !self.options.loopback_silence) return false;
    if (self.negotiated.rate == 0) return false;

    const now = self.clock.ticks();
    const gap_ns = self.clock.deltaNs(last_data_ticks.*, now);
    const gap_frames: u32 = @intCast(@min(
        time_mod.nsToFrames(gap_ns, self.negotiated.rate),
        self.options.max_period_frames,
    ));
    if (gap_frames == 0) return false;

    const channel_count = self.negotiated.channels;
    const samples = @as(usize, gap_frames) * channel_count;
    if (samples > self.stage.len) return false;

    mix.silence(self.stage[0..samples]);
    self.publishFrames(self.stage[0..samples], gap_frames, channel_count);
    last_data_ticks.* = now;
    return true;
}

test "loopback records an output endpoint and a microphone records an input one" {
    // The mistake this mapping exists to prevent: activating loopback on a capture
    // endpoint is `AUDCLNT_E_WRONG_ENDPOINT_TYPE`, which says nothing about why.
    try std.testing.expectEqual(com.Flow.render, Source.loopback.flow());
    try std.testing.expectEqual(com.Flow.capture, Source.microphone.flow());
}

test "an overrun is counted as lost frames rather than ignored" {
    // A capture overrun is lost data, unlike a playback underrun which is only heard,
    // so it has to be countable.
    var capture: Capture = undefined;
    capture.overrun_frames = .init(0);
    _ = capture.overrun_frames.fetchAdd(480, .monotonic);
    try std.testing.expectEqual(@as(u64, 480), capture.overruns());
}

test {
    std.testing.refAllDecls(@This());
}
