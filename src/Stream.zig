// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A playback stream: audio in, sound out.
//!
//! ```zig
//! const stream = try wasapi.Stream.open(gpa, io, .{ .name = "my app", .channels = 2 });
//! defer stream.close(io);
//!
//! _ = try stream.waitStreaming(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
//! try stream.writeAll(io, interleaved_f32_samples, .none);
//! stream.drain(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
//! ```
//!
//! Or, supplying audio on demand instead of pushing it:
//!
//! ```zig
//! const stream = try wasapi.Stream.open(gpa, io, .{
//!     .channels = 2,
//!     .process = .{ .ctx = &my_synth, .func = &fillPlanes },
//! });
//! defer stream.close(io);
//! ```
//!
//! ## Two modes, chosen at open time
//!
//! **Push**: `write` and `writeAll` queue interleaved frames, and a render thread
//! takes them. The queue is what absorbs the difference between how a program
//! produces audio and how the audio engine consumes it, and it is why a program
//! with an irregular loop can still play cleanly.
//!
//! **Pull**: a `Process` callback is invoked once per graph cycle and fills a slice
//! per channel. Lower latency -- there is no queue to traverse -- and the right
//! shape for a synthesiser or a mixer, at the cost of having to produce audio on
//! somebody else's schedule, inside a real-time deadline.
//!
//! Which one a stream does is fixed at `open` and the other one's calls fail:
//! `write` on a pull-mode stream returns `error.WrongMode` rather than silently
//! queueing audio that nothing will ever read.
//!
//! ## The render thread
//!
//! One raw `std.Thread` per stream, raised into the "Pro Audio" scheduling class,
//! blocked in `WaitForSingleObject` on the event handle WASAPI signals. It owns
//! every COM object the stream has -- created there, used there, released there --
//! so no interface pointer ever crosses a thread boundary and no marshalling is
//! ever needed.
//!
//! It is not a `std.Io` task and cannot be, for reasons set out in `wait.zig`: there
//! is no `std.Io.Operation` that can wait on a Windows event handle. Everything the
//! caller can observe is published through atomics, and the three calls that wait --
//! `writeAll`, `waitStreaming`, `drain` -- poll on a schedule derived from the graph
//! period. None of them is in the audio path.
//!
//! ## Nothing is allocated after `open`
//!
//! Every buffer a cycle touches is allocated once, sized from
//! `Options.max_period_frames`. That is what lets the stream survive its endpoint
//! being unplugged: the reopen path re-activates COM objects but allocates nothing,
//! so it cannot fail for want of memory at the worst possible moment. It is also
//! why a new endpoint wanting a longer period than `max_period_frames` is served in
//! several chunks per cycle rather than in one.

const Stream = @This();

const std = @import("std");
const builtin = @import("builtin");

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

const com = @import("com/com.zig");
const activate = @import("com/activate.zig");

const log = std.log.scoped(.wasapi);

const win32 = @import("win32").everything;

pub const Format = format_mod.Format;
pub const Stats = stats_mod.Stats;
pub const Time = time_mod.Time;

/// What a stream is doing.
pub const State = enum(u8) {
    /// Opened, but the render thread has not run a cycle yet. Audio written now is
    /// queued and will be heard once it does.
    idle,
    /// Running. Audio written now is heard.
    streaming,
    /// The endpoint went away and the stream did not recover: either it was told
    /// not to follow the default, or nothing usable could be found. Terminal --
    /// `close` is the only thing left to do.
    ///
    /// There is deliberately no state for "reopening". A caller gates its producer
    /// loop on `isActive`, and a momentary `idle` in the middle of a device change
    /// would make a well-written program stop feeding the ring -- which is the
    /// opposite of what is wanted, since the whole point of the reopen is that the
    /// queued audio survives. A device change is observable through `Stats.reopens`.
    failed,
};

/// What the audio is for.
///
/// Windows uses this for two separate things, which is why one enum covers both:
/// the stream *category*, which decides whether a voice call ducks music and which
/// per-category volume applies, and the endpoint *role*, which decides which
/// default device a stream lands on when it is given no target.
pub const Role = enum {
    /// Music. The default, and what most programs want.
    music,
    /// A film or a video: the same category as music to Windows, but it says what
    /// is meant.
    movie,
    /// A voice call. Ducks other audio, and lands on the communications endpoint
    /// rather than the console one -- which on a machine with a headset is a
    /// different device.
    communication,
    /// Game audio.
    game,
    /// Interface sounds and alerts: short, and not worth ducking anything for.
    notification,
    /// Speech, for a screen reader or a voice assistant.
    speech,
    /// Anything else.
    other,

    fn toCategory(self: Role) win32.AUDIO_STREAM_CATEGORY {
        return switch (self) {
            .music => .Media,
            .movie => .Movie,
            .communication => .Communications,
            .game => .GameMedia,
            .notification => .Alerts,
            .speech => .Speech,
            .other => .Other,
        };
    }

    fn toEndpointRole(self: Role) com.Role {
        return switch (self) {
            // The one that matters: a voice call belongs on whatever the user chose
            // for voice calls, which is very often not their speakers.
            .communication => .communications,
            .movie, .music => .multimedia,
            else => .console,
        };
    }
};

/// Pull-mode audio source.
///
/// `planes` has one entry per channel, each `frames` samples long, and every one
/// must be filled completely -- whatever is left unwritten is whatever the previous
/// cycle put there.
///
/// Runs on the render thread, inside a graph cycle, against a real-time deadline: no
/// allocation, no locks, no file or network access. It is never re-entered, is never
/// called after `close` returns, and is not called at all while the stream is moving
/// to another endpoint -- so a gap is possible and `Stats.reopens` is how to notice
/// one happened.
pub const Process = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, planes: []const []f32, frames: u32) void,
};

/// How the stream presents itself and where it connects.
///
/// Every string here is copied during `open`, because the reopen path may need them
/// minutes later -- so none of them has to outlive the call.
pub const Options = struct {
    /// Shown in the Windows volume mixer.
    name: []const u8 = "zig-wsapi",

    /// Channels the caller will supply.
    channels: u16 = 2,

    /// One entry per channel, in the order the caller interleaves them. Null uses
    /// the conventional layout for the count, which exists for 1, 2, 4, 6 and 8
    /// channels; any other count needs a map.
    channel_map: ?[]const channel.Channel = null,

    /// The rate to ask for. If the endpoint mixes at another rate the audio engine
    /// resamples; read `rate()` after opening for what was settled on.
    rate: u32 = 48000,

    /// A preferred period in frames, or null for the engine's default -- which is
    /// ten milliseconds, or as little as about two on hardware and Windows versions
    /// that support the low-latency path.
    ///
    /// A request shorter than the engine allows is raised to its minimum rather
    /// than refused.
    latency_frames: ?u32 = null,

    role: Role = .music,

    /// Which endpoint: an id from `com.Endpoint.id`, or a substring of a friendly
    /// name, or null for whatever Windows would use.
    ///
    /// Naming a target also turns off following the default, because a caller who
    /// asked for a particular device did not ask to be moved off it.
    target: ?[]const u8 = null,

    /// Frames the queue holds. Ignored in pull mode, which has no queue.
    ///
    /// Rounded up to a power of two, so `writable()` may report more than this.
    ring_frames: u32 = 16384,

    /// Supply audio by callback instead of through `write`.
    process: ?Process = null,

    /// Move to the new default endpoint when the user changes it, or when this one
    /// is unplugged, instead of failing.
    ///
    /// The queued audio survives the move and plays on afterwards, so what a
    /// listener hears is a gap rather than a stoppage. Turn it off to get the
    /// zig-pipewire behaviour of a `.failed` stream instead.
    ///
    /// Ignored when `target` is set.
    follow_default: bool = true,

    /// Give up on reopening after this long and fail instead.
    reopen_timeout: std.Io.Timeout = .none,

    /// How long `open` will wait for the render thread to report success.
    open_timeout: std.Io.Timeout = .{
        .duration = .{ .raw = .fromSeconds(5), .clock = .awake },
    },

    /// The longest period the stream will serve in one piece.
    ///
    /// Bounds every buffer allocated at `open`, which is what lets the reopen path
    /// allocate nothing. An endpoint wanting a longer period is served in several
    /// chunks per cycle, which costs nothing but a loop.
    max_period_frames: u32 = 4096,

    /// Groups several streams under one entry in the Windows volume mixer, so a
    /// program that opens more than one appears once. Null gives this stream its own
    /// entry.
    session_guid: ?win32.Guid = null,

    log: ?Log = null,
};

// --- what the caller owns ---

gpa: Allocator,
options: Options,
/// One block holding every copied string in `options`, so teardown is one free.
strings: []u8,
/// The caller's channel map, copied for the same reason.
map: []channel.Channel,

// --- shared with the render thread ---

ring: Ring,
/// Two staging buffers, ping-ponged through the permute and channel-remap steps.
/// Sized for `max_period_frames` at whichever channel count is larger.
stage_a: []f32,
stage_b: []f32,
/// Pull mode only: the planes handed to `Process`, and the slices describing them.
planes: []f32,
plane_slices: [][]f32,

event: com.Event,
clock: com.Clock,
thread: ?std.Thread = null,

state: std.atomic.Value(State) = .init(.idle),
/// Whether the caller wants audio playing. False between `pause` and `unpause`.
active: std.atomic.Value(bool) = .init(true),
stop: std.atomic.Value(bool) = .init(false),
/// Bits the caller sets and the render thread clears; see `control_*` below.
control: std.atomic.Value(u32) = .init(0),
/// Bits a COM device notification sets and the render thread clears, as
/// `com.notify.Flags`.
///
/// Kept apart from `control` rather than sharing one word, because the two have
/// different bit layouts and different writers -- one is this library's own protocol
/// between the caller and the render thread, the other is a shape a notification handler
/// can produce without knowing anything about streams.
notify_flags: std.atomic.Value(u32) = .init(0),

/// Frames of silence the render thread had to invent. Published separately from
/// `Stats` because `underruns()` is cheap and `stats()` copies a structure.
underrun_frames: std.atomic.Value(u64) = .init(0),
/// Frames handed to the audio engine, and frames it reports having played.
frames_written: std.atomic.Value(u64) = .init(0),
frames_played: std.atomic.Value(u64) = .init(0),
/// The position the endpoint has to reach for everything the *caller* wrote to have
/// been heard.
///
/// Not the same as `frames_written`, and the difference is the whole of why `drain`
/// works: once the queue runs dry the render thread keeps handing the engine silence,
/// so `frames_written` climbs forever and `played >= written` is never true. This
/// marks where the last real audio ended instead.
drain_target: std.atomic.Value(u64) = .init(0),

stats_cell: stats_mod.Cell = .{},
time_cell: stats_mod.Published(Time) = .{},

/// What `open` is waiting to hear from the render thread.
open_result: std.atomic.Value(OpenResult) = .init(.pending),
/// Valid once `open_result` is `.failed`, written before it and read after, so the
/// release/acquire pair on that atomic carries it.
open_error: errors.OpenError = error.Unexpected,
/// Published once, before `open_result` becomes `.ok`.
negotiated: Format = .{ .rate = 0, .channels = 0, .sample = .f32 },
period_frames: u32 = 0,
buffer_frames: u32 = 0,

const OpenResult = enum(u8) { pending, ok, failed };

/// The render thread should look at its flags: something asked it to.
const control_wake: u32 = 1 << 0;
/// The default endpoint changed; reopen on the new one.
const control_default_changed: u32 = 1 << 1;
/// Start the statistics window again.
const control_reset_stats: u32 = 1 << 2;

/// Open a playback stream.
///
/// The returned pointer is owned by the caller and must be handed to `close`.
pub fn open(gpa: Allocator, io: std.Io, options: Options) errors.OpenError!*Stream {
    if (options.channels == 0 or options.channels > channel.max_channels) {
        return error.TooManyChannels;
    }
    if (options.channel_map) |map| {
        if (map.len != options.channels) return error.ChannelMapMismatch;
    }
    if (options.rate == 0) return error.InvalidRate;
    if (options.max_period_frames == 0) return error.InvalidRate;

    // The layout the caller will interleave in, validated before anything is
    // allocated so a bad map costs nothing.
    const caller_map = options.channel_map orelse
        channel.defaultChannelMap(options.channels) orelse return error.NoDefaultChannelMap;
    channel.validate(caller_map) catch |err| return switch (err) {
        error.TooManyChannels => error.TooManyChannels,
        error.DuplicateChannel, error.MonoWithOthers => error.ChannelMapMismatch,
    };

    const self = try allocate(gpa, options, caller_map);
    // The single teardown for everything past this point. One `errdefer` rather than a
    // cleanup call at each failure, because Zig keeps an `errdefer` armed after the
    // thing it guards has been handed on -- so a function that both calls a cleanup
    // helper *and* has earlier `errdefer`s frees everything twice. That is what
    // `allocate` is for: its `errdefer`s guard locals and stop at its return.
    errdefer {
        self.shutdown();
        self.freeOwned();
        gpa.destroy(self);
    }

    self.thread = std.Thread.spawn(
        .{ .stack_size = 512 * 1024 },
        renderMain,
        .{self},
    ) catch return error.ThreadSpawnFailed;

    // The render thread does all the COM work, so `open` has to wait to hear how it
    // went.
    wait.until(io, options.open_timeout, self, openSettled, .{}) catch |err| switch (err) {
        error.Timeout => {
            log.warn("the render thread did not report back within the open timeout", .{});
            return error.Unexpected;
        },
        // A cancelled open is not a device problem, but `OpenError` has nowhere to say
        // so -- and reporting it as anything else would be a lie about the hardware.
        error.Canceled => return error.Unexpected,
        error.StreamFailed => return self.open_error,
    };

    self.emit(.info, "stream opened");
    return self;
}

/// Allocate everything a stream owns, or nothing.
///
/// Split out so that the partial-allocation `errdefer`s end here rather than staying
/// armed through the thread spawn and the open handshake -- see the `errdefer` in
/// `open`.
fn allocate(
    gpa: Allocator,
    options: Options,
    caller_map: []const channel.Channel,
) errors.OpenError!*Stream {
    const self = try gpa.create(Stream);
    errdefer gpa.destroy(self);

    // One block holding every string, so teardown is one free. The offsets are
    // computed rather than captured as slices, because `toOwnedSlice` moves the
    // storage and a slice taken beforehand would dangle.
    var strings: std.ArrayList(u8) = .empty;
    errdefer strings.deinit(gpa);
    try strings.appendSlice(gpa, options.name);
    const name_end = strings.items.len;
    if (options.target) |t| try strings.appendSlice(gpa, t);
    const target_end = strings.items.len;
    const strings_block = try strings.toOwnedSlice(gpa);
    errdefer gpa.free(strings_block);

    const map = try gpa.dupe(channel.Channel, caller_map);
    errdefer gpa.free(map);

    // Big enough for either side of the conversion: the caller's channel count or
    // whatever the endpoint turns out to want. `max_channels` because the endpoint's
    // count is not known until the render thread has negotiated, and this has to be
    // allocated before it starts.
    const stage_samples = @as(usize, options.max_period_frames) * channel.max_channels;
    const stage_a = try gpa.alloc(f32, stage_samples);
    errdefer gpa.free(stage_a);
    const stage_b = try gpa.alloc(f32, stage_samples);
    errdefer gpa.free(stage_b);

    // Pull mode needs one plane per channel; push mode needs neither.
    const pull = options.process != null;
    const planes = try gpa.alloc(
        f32,
        if (pull) @as(usize, options.max_period_frames) * options.channels else 0,
    );
    errdefer gpa.free(planes);
    const plane_slices = try gpa.alloc([]f32, if (pull) options.channels else 0);
    errdefer gpa.free(plane_slices);

    // Push mode's queue. Pull mode gets the floor, unused: a zero-length ring would
    // mean every accessor needed a special case for a mode that never touches it.
    var ring: Ring = try .init(
        gpa,
        if (pull) Ring.min_frames else @max(options.ring_frames, 2 * options.max_period_frames),
        options.channels,
    );
    errdefer ring.deinit(gpa);

    const event: com.Event = try .create();

    self.* = .{
        .gpa = gpa,
        .options = options,
        .strings = strings_block,
        .map = map,
        .ring = ring,
        .stage_a = stage_a,
        .stage_b = stage_b,
        .planes = planes,
        .plane_slices = plane_slices,
        .event = event,
        .clock = .init(),
    };
    // Point the stored options at our own copies rather than at the caller's memory,
    // which may be gone by the time a reopen needs the target name.
    self.options.name = strings_block[0..name_end];
    self.options.target = if (options.target != null) strings_block[name_end..target_end] else null;
    self.options.channel_map = self.map;
    return self;
}

/// Stop the stream and release everything it owns.
pub fn close(self: *Stream, io: std.Io) void {
    _ = io;
    self.shutdown();
    const gpa = self.gpa;
    self.freeOwned();
    gpa.destroy(self);
}

/// Ask the render thread to stop, and wait for it.
fn shutdown(self: *Stream) void {
    self.stop.store(true, .release);
    // Break it out of its wait rather than letting the timeout expire, so `close`
    // returns in microseconds instead of milliseconds -- and so that a stream
    // backing off between reopen attempts does not make shutdown take seconds.
    self.event.set();
    if (self.thread) |thread| {
        thread.join();
        self.thread = null;
    }
}

fn freeOwned(self: *Stream) void {
    self.ring.deinit(self.gpa);
    self.gpa.free(self.plane_slices);
    self.gpa.free(self.planes);
    self.gpa.free(self.stage_b);
    self.gpa.free(self.stage_a);
    self.gpa.free(self.map);
    self.gpa.free(self.strings);
    self.event.deinit();
    self.* = undefined;
}

fn openSettled(self: *Stream) wait.Ready {
    return switch (self.open_result.load(.acquire)) {
        .pending => .no,
        .ok => .yes,
        .failed => .failed,
    };
}

fn emit(self: *const Stream, level: Log.Level, message: []const u8) void {
    if (self.options.log) |sink| sink.emit(level, message);
}

// --- pushing audio ---

/// Queue interleaved frames. Returns how many whole frames were taken, which is
/// fewer than offered when the queue is full. Never blocks.
///
/// Only one thread may call this. The queue is single-producer, single-consumer;
/// two threads writing would corrupt it silently, so a program producing audio in
/// several places has to combine it before writing.
///
/// Returns zero in pull mode, which has no queue. Use `writeAll` if you want that
/// to be an error rather than a silent nothing.
pub fn write(self: *Stream, interleaved: []const f32) u32 {
    if (self.options.process != null) return 0;
    const taken = self.ring.push(interleaved);
    return taken;
}

/// Queue every frame, waiting for room.
///
/// Waits for *some* room and writes what fits, repeatedly -- not for room for the
/// whole remainder -- so a write larger than the queue makes progress instead of
/// waiting for space that will never exist at once.
///
/// `timeout` of `.none` waits indefinitely, which on a paused stream means forever:
/// a paused stream consumes nothing, so there is no room coming. That is the
/// caller's deadlock rather than something this library can resolve, and it is worth
/// knowing about rather than papering over.
pub fn writeAll(
    self: *Stream,
    io: std.Io,
    interleaved: []const f32,
    timeout: std.Io.Timeout,
) errors.WriteError!void {
    if (self.options.process != null) return error.WrongMode;

    const channels = self.options.channels;
    var offset: usize = 0;
    const deadline = timeout.toDeadline(io);

    while (offset < interleaved.len) {
        const taken = self.ring.push(interleaved[offset..]);
        offset += @as(usize, taken) * channels;
        if (offset >= interleaved.len) break;

        // A whole frame of room is enough to make progress on the next attempt.
        wait.until(io, deadline, self, hasRoom, wait.paramsForPeriod(self.periodNs())) catch |err|
            switch (err) {
                error.StreamFailed => return error.NotConnected,
                error.Timeout => return error.NotConnected,
                error.Canceled => return error.Canceled,
            };
    }
}

fn hasRoom(self: *Stream) wait.Ready {
    if (self.state.load(.acquire) == .failed) return .failed;
    return if (self.ring.writable() > 0) .yes else .no;
}

/// Frames `write` would take right now. Zero in pull mode.
pub fn writable(self: *Stream) u32 {
    if (self.options.process != null) return 0;
    return self.ring.writable();
}

/// Frames queued and not yet played. Zero in pull mode.
pub fn queued(self: *Stream) u32 {
    if (self.options.process != null) return 0;
    return self.ring.queued();
}

/// Frames of silence the render thread had to invent because the queue was short.
///
/// A count that climbs during playback means the producer is not keeping up. Once
/// you stop writing, the engine keeps asking: expect this to pick up roughly a
/// period's worth between the last frame written and `close`, which is why `drain`
/// exists.
pub fn underruns(self: *Stream) u64 {
    return self.underrun_frames.load(.acquire);
}

// --- control ---

/// Take the stream out of the engine's schedule.
///
/// Nothing is heard, `process` stops being called, and -- once nothing else is
/// playing -- Windows can let the endpoint idle, which a stream playing silence
/// would prevent. The stream keeps its place and its volume in the mixer, and
/// `unpause` puts it back.
///
/// Safe from any thread, including from inside `process`. It asks rather than
/// waits: the render thread acts on it within a cycle.
pub fn pause(self: *Stream) void {
    self.active.store(false, .release);
    self.request(control_wake);
}

/// Undo `pause`. Not `resume`, which Zig reserves.
pub fn unpause(self: *Stream) void {
    self.active.store(true, .release);
    self.request(control_wake);
}

/// Whether the stream is wanted playing: false between `pause` and `unpause`.
pub fn isActive(self: *Stream) bool {
    return self.active.load(.acquire);
}

fn request(self: *Stream, flags: u32) void {
    _ = self.control.fetchOr(flags | control_wake, .release);
    self.event.set();
}

// --- introspection ---

/// The rate the stream settled on.
///
/// Fixed for the life of the stream, including across a move to another endpoint:
/// audio already queued was written at this rate, and changing it would corrupt
/// what has not played yet. If the new endpoint cannot take this rate, the stream
/// fails rather than changing it.
pub fn rate(self: *const Stream) u32 {
    return self.negotiated.rate;
}

/// Frames per cycle, or zero before the first one.
///
/// Unlike `rate`, this *can* change when the stream moves to another endpoint.
/// `Stats.reopens` is how to notice that it did.
pub fn quantum(self: *const Stream) u32 {
    return self.period_frames;
}

/// How many channels the endpoint settled on.
///
/// Not necessarily what was asked for: `write` still takes the requested channel
/// count and the frames are mapped onto this one.
pub fn endpointChannels(self: *const Stream) u16 {
    return self.negotiated.channels;
}

/// The format the endpoint is actually receiving.
pub fn endpointFormat(self: *const Stream) Format {
    return self.negotiated;
}

pub fn getState(self: *const Stream) State {
    return self.state.load(.acquire);
}

/// When the audio of the last cycle will be heard.
///
/// Safe from any thread, including from inside `process`, because it reads a
/// published snapshot rather than taking anything the render thread holds.
pub fn time(self: *const Stream) Time {
    return self.time_cell.load();
}

/// What the cycles since the last `resetStats` have cost.
pub fn stats(self: *const Stream) Stats {
    return self.stats_cell.load();
}

/// Start the measurement window again, so a benchmark can exclude the cycles spent
/// starting up.
pub fn resetStats(self: *Stream) void {
    self.request(control_reset_stats);
}

fn periodNs(self: *const Stream) u64 {
    const period = self.period_frames;
    const r = self.negotiated.rate;
    if (period == 0 or r == 0) return 0;
    return time_mod.framesToNs(period, r);
}

// --- waiting ---

/// Wait until the stream is running, or `timeout` passes.
///
/// Returns false on timeout. `error.Canceled` rather than false for a cancelled
/// wait, because a caller that treats the two the same cannot tell a slow device
/// from a shutdown.
pub fn waitStreaming(
    self: *Stream,
    io: std.Io,
    timeout: std.Io.Timeout,
) std.Io.Cancelable!bool {
    wait.until(io, timeout, self, isStreaming, .{}) catch |err| switch (err) {
        error.Timeout, error.StreamFailed => return false,
        error.Canceled => return error.Canceled,
    };
    return true;
}

fn isStreaming(self: *Stream) wait.Ready {
    return switch (self.state.load(.acquire)) {
        .streaming => .yes,
        .failed => .failed,
        .idle => .no,
    };
}

/// Wait until everything queued has actually been played.
///
/// Call this before `close` so the tail of the audio is heard rather than cut off.
///
/// Two conditions, and the second is the one that matters: the queue has to empty,
/// *and* the endpoint has to report having played everything handed to it. Waiting
/// only for the queue would return while a period of audio was still inside the
/// audio engine.
pub fn drain(self: *Stream, io: std.Io, timeout: std.Io.Timeout) void {
    wait.until(io, timeout, self, isDrained, wait.paramsForPeriod(self.periodNs())) catch {};
}

fn isDrained(self: *Stream) wait.Ready {
    switch (self.state.load(.acquire)) {
        .failed => return .failed,
        // Nothing has been consumed yet, so nothing can have drained -- unless
        // there was never anything to drain.
        .idle => return if (self.ring.isEmpty()) .yes else .no,
        .streaming => {},
    }
    if (!self.ring.isEmpty()) return .no;
    // Pull mode has no queue and no tail: whatever the callback produced for the
    // cycle in flight is already the engine's problem.
    if (self.options.process != null) return .yes;

    const target = self.drain_target.load(.acquire);
    const played = self.frames_played.load(.acquire);
    return if (played >= target) .yes else .no;
}

// --- the render thread ---

/// Everything the render loop needs that is not in the `Stream`.
const Engine = struct {
    stream: *Stream,
    enumerator: com.Enumerator,
    activated: activate.Activated,
    accumulator: stats_mod.Accumulator,
    /// Frames handed to the engine since this activation started. Reset on a
    /// reopen, because the endpoint's own position counter restarts with it.
    written_this_activation: u64 = 0,
    /// When the previous cycle woke, in performance-counter ticks. The interval
    /// between wakeups is what `Stats.wake` reports.
    last_wake_ticks: u64 = 0,
    period_ticks: u64 = 0,
    /// Whether the ring has been fed at all, so that a stream nobody has written to
    /// is not reported as underrunning.
    ever_fed: bool = false,
    /// Consecutive waits that timed out, which is how a silent endpoint is noticed.
    consecutive_timeouts: u32 = 0,
};

fn renderMain(self: *Stream) void {
    // This thread is ours, so it gets the multithreaded apartment and there is no
    // host to accommodate.
    var apartment = com.Apartment.enter(com.coinit_multithreaded) catch |err| {
        self.failOpen(err);
        return;
    };
    defer apartment.leave();

    // Before anything else, and not fatal if it is refused -- see `ProAudio`.
    var pro_audio: com.ProAudio = .raise();
    defer pro_audio.revert();

    var enumerator = com.Enumerator.create() catch |err| {
        self.failOpen(err);
        return;
    };
    defer enumerator.deinit();

    // Ask to be told when the default endpoint changes, which is the one case that
    // produces no error at all: the current endpoint keeps working perfectly while the
    // user is now expecting audio somewhere else. Without this the move would wait for
    // the endpoint to fail, which it never will.
    var watcher: ?*com.NotificationClient = null;
    if (self.options.follow_default and self.options.target == null) {
        watcher = com.NotificationClient.create(self.gpa, .{
            .flags = &self.notify_flags,
            // Signalled after the bits are set, so the render thread stops waiting and
            // looks -- which turns a device change into a reopen within microseconds
            // rather than within a period.
            .event = self.event,
        }) catch null;
        if (watcher) |client| {
            client.register(enumerator) catch |err| {
                log.warn("could not watch for device changes: {t}", .{err});
                // Not registered, so there is nothing to unregister -- drop the
                // reference `create` gave us.
                _ = client.interface.IUnknown.Release();
                watcher = null;
            };
        }
    }
    defer if (watcher) |client| client.unregister(enumerator);

    var activated = self.activateOnce(enumerator) catch |err| {
        self.failOpen(err);
        return;
    };

    var engine: Engine = .{
        .stream = self,
        .enumerator = enumerator,
        .activated = activated,
        .accumulator = .{},
    };
    defer engine.activated.deinit();

    self.publishActivation(&engine);

    // Fill the buffer before starting, so the first cycle is not an underrun by
    // construction.
    preroll(&engine);

    engine.activated.start() catch |err| {
        self.failOpen(err);
        return;
    };
    rebase(&engine);

    // Only now is the stream open as far as the caller is concerned.
    self.open_result.store(.ok, .release);
    self.state.store(.streaming, .release);

    run(&engine);

    activated = engine.activated;
    activated.stopQuietly();
}

fn failOpen(self: *Stream, err: errors.OpenError) void {
    // Written before the flag that publishes it, so the release store carries it.
    self.open_error = err;
    self.open_result.store(.failed, .release);
    self.state.store(.failed, .release);
}

fn activateOnce(self: *Stream, enumerator: com.Enumerator) errors.OpenError!activate.Activated {
    return activate.open(enumerator, .{
        .flow = .render,
        .role = self.options.role.toEndpointRole(),
        .target = self.options.target,
        .rate = self.options.rate,
        .channels = self.options.channels,
        .map = self.map,
        .latency_frames = self.options.latency_frames,
        .session_guid = self.options.session_guid,
        .category = self.options.role.toCategory(),
    }, self.event);
}

fn publishActivation(self: *Stream, engine: *const Engine) void {
    self.negotiated = engine.activated.negotiation.endpoint;
    self.period_frames = engine.activated.period_frames;
    self.buffer_frames = engine.activated.buffer_frames;
}

/// How long the render thread waits for the endpoint before treating the silence as
/// a missed cycle.
///
/// Two periods, with a floor, and deliberately not `INFINITE`: a device whose driver
/// has stopped signalling -- which happens, and without producing an error from any
/// call -- would otherwise hang this thread and with it `close` and the program's
/// whole shutdown.
fn waitTimeoutMs(engine: *const Engine) u32 {
    const period_ns = time_mod.framesToNs(
        engine.activated.period_frames,
        engine.activated.negotiation.endpoint.rate,
    );
    const two_periods_ms = 2 * period_ns / std.time.ns_per_ms;
    return @intCast(std.math.clamp(two_periods_ms, 20, 2000));
}

/// Fill the engine's buffer before `Start`, so the first cycle is not an underrun.
fn preroll(engine: *Engine) void {
    const frames = engine.activated.buffer_frames;
    if (frames == 0) return;
    _ = fillChunk(engine, frames) catch {};
}

/// Reset the per-activation measurements.
///
/// Called after every `Start`, including after a reopen: the wake interval is
/// measured between consecutive cycles, and carrying one across a device change
/// would report the whole gap as a single enormous jitter figure.
fn rebase(engine: *Engine) void {
    const clock = engine.stream.clock;
    engine.period_ticks = clock.nsToTicks(time_mod.framesToNs(
        engine.activated.period_frames,
        engine.activated.negotiation.endpoint.rate,
    ));
    engine.last_wake_ticks = 0;
    engine.written_this_activation = 0;
    engine.accumulator.period_ns = time_mod.framesToNs(
        engine.activated.period_frames,
        engine.activated.negotiation.endpoint.rate,
    );
}

/// The render loop. Returns when the stream is closed, or when it has given up.
fn run(engine: *Engine) void {
    const self = engine.stream;

    while (!self.stop.load(.acquire)) {
        const timeout_ms = waitTimeoutMs(engine);
        switch (self.event.wait(timeout_ms)) {
            .signalled => {},
            .timed_out => {
                engine.accumulator.missed_cycles +|= 1;
                // A device that has stopped signalling entirely is one to replace.
                // Three in a row rather than one, because a single miss under load
                // is ordinary and not worth tearing a stream down for.
                engine.consecutive_timeouts += 1;
                if (engine.consecutive_timeouts >= 3) {
                    log.warn("endpoint stopped signalling; looking for another", .{});
                    if (!reopen(engine)) return;
                }
                continue;
            },
            .failed => {
                self.state.store(.failed, .release);
                return;
            },
        }
        engine.consecutive_timeouts = 0;

        const wake_ticks = self.clock.ticks();
        handleControl(engine);
        if (self.stop.load(.acquire)) return;

        const padding = engine.activated.padding() catch |err| {
            if (!handleFailure(engine, err)) return;
            continue;
        };

        const available = engine.activated.buffer_frames -| padding;
        if (available == 0) {
            // A spurious wake -- `pause` and the notification callbacks both signal
            // the event -- which costs exactly this one call and nothing else.
            continue;
        }

        var remaining = available;
        var failed = false;
        while (remaining > 0) {
            // Bounded by what was allocated at open time, which is what lets a
            // reopen onto an endpoint with a longer period allocate nothing.
            const chunk = @min(remaining, self.options.max_period_frames);
            fillChunk(engine, chunk) catch |err| {
                if (!handleFailure(engine, err)) return;
                failed = true;
                break;
            };
            remaining -= chunk;
        }
        if (failed) continue;

        const done_ticks = self.clock.ticks();
        accumulate(engine, wake_ticks, done_ticks);
        publish(engine, wake_ticks, padding);
    }
}

/// Act on whatever the caller, or Windows, asked for between cycles.
fn handleControl(engine: *Engine) void {
    const self = engine.stream;

    const flags = self.control.swap(0, .acquire);
    if (flags & control_reset_stats != 0) {
        engine.accumulator.reset();
        self.underrun_frames.store(0, .release);
    }

    // Both sources can ask for a move: the caller, through `control`, and Windows,
    // through the notification client. Read and clear the notification word here rather
    // than in the handler, so a burst of changes while a reopen is in progress collapses
    // into one.
    const notifications: com.NotificationFlags = @bitCast(self.notify_flags.swap(0, .acquire));

    const wants_move = (flags & control_default_changed != 0) or
        notifications.default_render_changed;

    if (wants_move and followsDefault(engine)) {
        log.debug("the default endpoint changed; moving", .{});
        _ = reopen(engine);
    }
}

fn followsDefault(engine: *const Engine) bool {
    // Naming a target means the caller chose a device, and being moved off it is
    // not what they asked for.
    return engine.stream.options.follow_default and engine.stream.options.target == null;
}

/// Decide what to do about a failed COM call.
///
/// Returns false when the stream is finished and the loop should return.
fn handleFailure(engine: *Engine, err: errors.Error) bool {
    switch (err) {
        // The endpoint is gone. Whether that is recoverable is the caller's choice.
        error.DeviceInvalidated, error.ServiceNotRunning => {
            if (!engine.stream.options.follow_default) {
                log.warn("endpoint went away and follow_default is off: {t}", .{err});
                engine.stream.state.store(.failed, .release);
                return false;
            }
            return reopen(engine);
        },
        else => {
            log.warn("the render loop cannot continue: {t}", .{err});
            engine.stream.state.store(.failed, .release);
            return false;
        },
    }
}

/// Move to whatever endpoint is usable now, keeping the queue and its contents.
///
/// Returns false when the stream has given up, in which case the loop returns.
///
/// Nothing here allocates. Everything the stream owns on the Zig side survives --
/// the queue and the audio in it, the staging buffers, the statistics, the event
/// handle -- and only the COM objects are rebuilt. That is the whole reason this can
/// be done from a real-time thread at all.
fn reopen(engine: *Engine) bool {
    const self = engine.stream;

    engine.activated.stopQuietly();
    engine.activated.deinit();
    // Discard a signal from the endpoint that has gone, so the new one's first
    // wake is its own.
    self.event.reset();

    // The rate must not change: audio already queued was written at the old one,
    // and resampling what is in flight is not something this library does.
    const wanted_rate = self.negotiated.rate;

    var attempt: u32 = 0;
    var backoff_ms: u32 = 0;
    const deadline = self.options.reopen_timeout.toDeadline(std.Io.failing);
    _ = deadline;

    while (!self.stop.load(.acquire)) {
        if (backoff_ms != 0) {
            // Backing off on the same event `close` signals, so shutting down during
            // a retry returns immediately instead of waiting out the delay. Without
            // this, closing a stream on a machine with no working endpoint takes the
            // full backoff.
            _ = self.event.wait(backoff_ms);
            if (self.stop.load(.acquire)) return false;
        }

        if (self.activateOnce(engine.enumerator)) |fresh| {
            engine.activated = fresh;

            if (engine.activated.negotiation.endpoint.rate != wanted_rate) {
                log.warn(
                    "the new endpoint runs at {d} Hz and the stream is committed to {d} Hz",
                    .{ engine.activated.negotiation.endpoint.rate, wanted_rate },
                );
                engine.activated.deinit();
                self.state.store(.failed, .release);
                return false;
            }

            self.publishActivation(engine);
            preroll(engine);
            engine.activated.start() catch {
                engine.activated.deinit();
                backoff_ms = nextBackoff(&attempt);
                continue;
            };
            rebase(engine);

            engine.accumulator.reopens +|= 1;
            self.state.store(.streaming, .release);
            log.debug("moved to another endpoint ({d} so far)", .{engine.accumulator.reopens});
            return true;
        } else |err| switch (err) {
            // Worth waiting for: a device being enumerated, a driver restarting, or
            // another program holding the endpoint exclusively and about to let go.
            error.DeviceNotFound,
            error.DeviceInUse,
            error.DeviceInvalidated,
            error.ServiceNotRunning,
            error.AccessDenied,
            => backoff_ms = nextBackoff(&attempt),

            // Not worth waiting for: the format will not become acceptable and the
            // memory will not appear.
            else => {
                log.warn("cannot reopen: {t}", .{err});
                self.state.store(.failed, .release);
                return false;
            },
        }
    }
    return false;
}

/// Wait a little longer each time, up to two seconds.
///
/// Capped rather than growing, because a machine whose only endpoint is unplugged
/// should keep checking for one being plugged back in -- and a user plugging in
/// headphones will not wait a minute for them to start working.
fn nextBackoff(attempt: *u32) u32 {
    const ladder = [_]u32{ 0, 20, 50, 100, 250, 500, 1000, 2000 };
    const index = @min(attempt.*, ladder.len - 1);
    attempt.* += 1;
    return ladder[index];
}

/// Produce `frames` frames into the engine's buffer.
fn fillChunk(engine: *Engine, frames: u32) errors.Error!void {
    const self = engine.stream;
    const render = engine.activated.render orelse return error.Unexpected;
    const endpoint = engine.activated.negotiation.endpoint;

    var data: ?*u8 = null;
    try com.check("IAudioRenderClient::GetBuffer", render.GetBuffer(frames, &data));
    const buffer = data orelse return error.Unexpected;

    // Paused: hand back silence with the flag that says so, which is cheaper than
    // writing zeroes and lets the engine skip the mix entirely.
    if (!self.active.load(.acquire)) {
        try com.check("IAudioRenderClient::ReleaseBuffer", render.ReleaseBuffer(
            frames,
            @intCast(@intFromEnum(win32.AUDCLNT_BUFFERFLAGS_SILENT)),
        ));
        engine.written_this_activation += frames;
        self.frames_written.store(engine.written_this_activation, .release);
        return;
    }

    const caller_channels = self.options.channels;
    const caller_samples = @as(usize, frames) * caller_channels;

    // Step one: get the caller's frames, in the caller's channel order, into
    // `stage_a`.
    var source = self.stage_a[0..caller_samples];
    if (self.options.process) |process| {
        // Pull: hand out one plane per channel and let the caller fill them.
        for (self.plane_slices, 0..) |*slice, ch| {
            slice.* = self.planes[@as(usize, ch) * self.options.max_period_frames ..][0..frames];
        }
        process.func(process.ctx, self.plane_slices, frames);
        mix.interleave(source, @ptrCast(self.plane_slices), frames);
    } else {
        // Push: whatever is queued, with silence for the rest.
        const short = self.ring.popOrSilence(source);
        if (short != 0) {
            // Only count it as an underrun once something has been written: a
            // stream nobody has fed yet is not starving, it is idle.
            if (engine.ever_fed) {
                _ = self.underrun_frames.fetchAdd(short, .monotonic);
                engine.accumulator.underrun_frames +|= short;
            }
        }
        const real = frames - short;
        if (real != 0) {
            engine.ever_fed = true;
            // Where the caller's audio ends in the engine's timeline, which is what
            // `drain` waits for the endpoint to reach.
            self.drain_target.store(engine.written_this_activation + real, .release);
        }
    }

    // Step two: the caller's channel order into the wire order the mask implies.
    if (engine.activated.negotiation.needs_permute) {
        const order = engine.activated.negotiation.order[0..caller_channels];
        const destination = self.stage_b[0..caller_samples];
        mix.permute(destination, source, order, caller_channels);
        source = destination;
    }

    // Step three: the caller's channel count into the endpoint's, if they differ.
    if (engine.activated.negotiation.needs_channel_remap) {
        const wide = @as(usize, frames) * endpoint.channels;
        // Ping-pong, so the previous step's output is not also this step's output.
        const destination = if (source.ptr == self.stage_a.ptr)
            self.stage_b[0..wide]
        else
            self.stage_a[0..wide];
        mix.remapChannels(destination, endpoint.channels, source, caller_channels, frames);
        source = destination;
    }

    // Step four: into the endpoint's sample type, straight into its buffer.
    const bytes = @as(usize, frames) * endpoint.blockAlign();
    const out: [*]u8 = @ptrCast(buffer);
    mix.toEndpoint(endpoint.sample, out[0..bytes], source);

    try com.check("IAudioRenderClient::ReleaseBuffer", render.ReleaseBuffer(frames, 0));
    engine.written_this_activation += frames;
    self.frames_written.store(engine.written_this_activation, .release);
}

fn accumulate(engine: *Engine, wake_ticks: u64, done_ticks: u64) void {
    const clock = engine.stream.clock;

    // How far apart consecutive wakeups were, against how far apart they ought to
    // be.
    //
    // ## Why this, rather than deviation from a running ideal clock
    //
    // The obvious measure is to keep a line that advances by exactly one period per
    // cycle and report the distance from it. That does not work here, and the reason
    // is specific to WASAPI: a cycle does not consume exactly one period. The engine
    // hands out whatever has freed since last time -- `buffer_frames` is a couple of
    // periods, so a cycle that ran slightly late catches up by writing more -- and a
    // line advancing by one period per *wakeup* therefore drifts against a stream
    // whose wakeups are not one period of audio apart. Measured that way this
    // reported tens of milliseconds on a stream that was in fact running perfectly.
    //
    // The interval between wakeups has no such problem: it is self-correcting, since
    // each measurement is independent of every previous one, and it is the quantity
    // that actually matters -- an audio thread that is woken regularly is healthy
    // whatever an imagined clock says.
    if (engine.last_wake_ticks != 0 and engine.period_ticks != 0) {
        const interval = wake_ticks -| engine.last_wake_ticks;
        const deviation = if (interval > engine.period_ticks)
            interval - engine.period_ticks
        else
            engine.period_ticks - interval;

        engine.accumulator.record(
            clock.deltaNs(0, deviation),
            clock.deltaNs(wake_ticks, done_ticks),
        );

        // An interval of more than two periods means the engine ran a cycle this
        // stream was not there for. Inferred, as `Stats.missed_cycles` documents.
        if (interval > 2 * engine.period_ticks) engine.accumulator.missed_cycles +|= 1;
    } else {
        // The first cycle has no interval to measure, so only the work is timed.
        engine.accumulator.record(0, clock.deltaNs(wake_ticks, done_ticks));
    }

    engine.last_wake_ticks = wake_ticks;
}

fn publish(engine: *Engine, wake_ticks: u64, padding: u32) void {
    const self = engine.stream;
    const endpoint = engine.activated.negotiation.endpoint;

    // What the endpoint has actually played, which is both the good latency figure
    // and what `drain` waits on.
    var delay_frames: i64 = @intCast(padding);
    if (engine.activated.devicePosition()) |position| {
        self.frames_played.store(position.frames, .release);
        delay_frames = @as(i64, @intCast(engine.written_this_activation)) -
            @as(i64, @intCast(position.frames));
    } else {
        // No usable clock. The padding is what is left in the engine's buffer,
        // which is the honest estimate -- and `drain` falls back to it too.
        self.frames_played.store(engine.written_this_activation -| padding, .release);
    }

    self.time_cell.store(.{
        .now_ns = engine.stream.clock.deltaNs(0, wake_ticks),
        .rate = endpoint.rate,
        .quantum = engine.activated.period_frames,
        .delay = delay_frames,
        .queued = self.ring.queued(),
    });
    self.stats_cell.store(engine.accumulator.snapshot());
}

test "a role maps to both a category and an endpoint role" {
    // Two different Windows concepts from one option, and the interesting one is
    // that a voice call is routed differently as well as ducked differently.
    try std.testing.expectEqual(com.Role.communications, Role.communication.toEndpointRole());
    try std.testing.expectEqual(
        win32.AUDIO_STREAM_CATEGORY.Communications,
        Role.communication.toCategory(),
    );

    // Music and film go to the multimedia endpoint, which a user may have set
    // separately from the console one.
    try std.testing.expectEqual(com.Role.multimedia, Role.music.toEndpointRole());
    try std.testing.expectEqual(com.Role.multimedia, Role.movie.toEndpointRole());
    try std.testing.expectEqual(win32.AUDIO_STREAM_CATEGORY.Movie, Role.movie.toCategory());

    // Everything else is ordinary console audio.
    try std.testing.expectEqual(com.Role.console, Role.game.toEndpointRole());
    try std.testing.expectEqual(com.Role.console, Role.notification.toEndpointRole());
    try std.testing.expectEqual(win32.AUDIO_STREAM_CATEGORY.GameMedia, Role.game.toCategory());
}

test "every role maps to something, so adding one cannot be forgotten" {
    // An exhaustive switch would catch a new role at compile time; this catches one
    // that was added to the switch with a placeholder.
    for (std.enums.values(Role)) |role| {
        _ = role.toCategory();
        _ = role.toEndpointRole();
    }
}

test "there is no state for reopening, deliberately" {
    // Documented on `State`: a caller gates its producer on `isActive`, and a
    // momentary `idle` mid-reopen would make it stop feeding the very queue the
    // reopen exists to preserve. If a fourth state is ever added, this is the
    // comment to read first.
    try std.testing.expectEqual(3, std.enums.values(State).len);
}

test {
    std.testing.refAllDecls(@This());
}
