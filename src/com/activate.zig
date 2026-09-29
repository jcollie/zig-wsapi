// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Turning an endpoint into a running audio client: which device, which format,
//! which period, and which of the three `IAudioClient` generations this system has.
//!
//! This is the part of the library most likely to need changing when it meets
//! unfamiliar hardware, so every decision it makes is logged at `debug` and every
//! fallback says why it was taken. When a user reports "44.1 kHz does not work on
//! my interface", the answer is in those lines.
//!
//! ## Shared mode only
//!
//! Everything here asks for `AUDCLNT_SHAREMODE_SHARED`, which mixes with every
//! other program's audio. Exclusive mode -- which takes the device away from
//! everything else, needs the format to match the hardware exactly, and has no
//! engine resampler to fall back on -- is out of scope for this version, and there
//! is deliberately no `share_mode` option rather than one that only accepts one
//! value.
//!
//! ## Everything here runs on the render thread
//!
//! Which is what lets it be this straightforward. No interface pointer created here
//! ever crosses a thread boundary, so there is no marshalling and no apartment
//! juggling; the thread puts itself in the multithreaded apartment once and owns
//! every object it makes for the life of the stream. `Session`, which is
//! synchronous on the caller's thread, is the only part of the library that has to
//! cope with an apartment it did not choose.

const std = @import("std");

const errors = @import("../errors.zig");
const channel = @import("../channel.zig");
const format_mod = @import("../format.zig");
const time = @import("../time.zig");
const Format = format_mod.Format;

const com = @import("com.zig");
const check = com.check;
const enumerator_mod = @import("enumerator.zig");
const Endpoint = enumerator_mod.Endpoint;
const Enumerator = enumerator_mod.Enumerator;
const Flow = enumerator_mod.Flow;
const Role = enumerator_mod.Role;

const log = std.log.scoped(.wasapi);

const win32 = @import("win32").everything;
const Guid = win32.Guid;

/// Which generation of `IAudioClient` an endpoint gave us.
///
/// The generations matter for exactly two things -- the stream category, which
/// needs the second, and the low-latency shared-mode period, which needs the third
/// -- and every other call is on the first. So this is a tagged pointer rather than
/// a wrapper per generation, and `base()` is what almost everything uses.
pub const Tier = enum {
    /// `IAudioClient`. Windows Vista. No stream category, no period control.
    one,
    /// `IAudioClient2`. Windows 8. Adds `SetClientProperties`, which is where the
    /// stream category and therefore the ducking behaviour lives.
    two,
    /// `IAudioClient3`. Windows 10 1703. Adds `GetSharedModeEnginePeriod` and
    /// `InitializeSharedAudioStream`, which is how a period shorter than the
    /// engine's default ten milliseconds is asked for.
    three,
};

/// An activated audio client, whichever generation it turned out to be.
pub const Client = struct {
    tier: Tier,
    /// The `IAudioClient` view, which every generation upcasts to for free through
    /// the bindings' `extern union`. Everything but the two generation-specific
    /// calls goes through this.
    ptr: *win32.IAudioClient,

    pub fn base(self: Client) *win32.IAudioClient {
        return self.ptr;
    }

    /// The `IAudioClient2` view, or null on Windows 7 and earlier.
    pub fn as2(self: Client) ?*win32.IAudioClient2 {
        return switch (self.tier) {
            .one => null,
            .two, .three => @ptrCast(self.ptr),
        };
    }

    /// The `IAudioClient3` view, or null before Windows 10 1703.
    pub fn as3(self: Client) ?*win32.IAudioClient3 {
        return switch (self.tier) {
            .one, .two => null,
            .three => @ptrCast(self.ptr),
        };
    }

    pub fn release(self: *Client) void {
        com.release(self.ptr);
        self.* = undefined;
    }
};

/// What to open.
pub const Request = struct {
    flow: Flow,
    role: Role,
    /// An endpoint id, or a substring of a friendly name, or null for the default.
    target: ?[]const u8 = null,
    /// The rate to ask for. The engine resamples if it differs from the mix rate.
    rate: u32,
    /// Channels the caller will supply.
    channels: u16,
    /// The caller's layout, for the mask. Empty means "use the convention".
    map: []const channel.Channel = &.{},
    /// A period in frames, or null for the engine's default.
    latency_frames: ?u32 = null,
    /// Groups several streams under one entry in the Windows volume mixer.
    session_guid: ?Guid = null,
    /// Capture what a *render* endpoint is playing rather than what a capture
    /// endpoint hears. Only meaningful when `flow` is `.render`.
    loopback: bool = false,
    /// What the audio is for, which decides ducking and the per-category volume.
    category: win32.AUDIO_STREAM_CATEGORY = .Media,
};

/// How the format was settled, and what it costs per cycle.
pub const Negotiation = struct {
    /// What the client was initialised with: what the endpoint will receive.
    endpoint: Format,
    /// How it was arrived at, which is what a `debug` log line and a bug report
    /// both want.
    tier: Tier,
    /// Which of the three attempts succeeded.
    route: Route,
    /// Where each of the caller's channels belongs in an endpoint frame.
    order: [channel.max_channels]u8,
    /// Whether `order` is anything other than the identity. False for every
    /// conventional layout, which is worth not paying for once a cycle.
    needs_permute: bool,
    /// Whether the caller's channel count differs from the endpoint's, so frames
    /// have to be widened or narrowed on the way out.
    needs_channel_remap: bool,

    pub const Route = enum {
        /// The endpoint accepted exactly what was asked for. No conversion beyond
        /// the sample type.
        native,
        /// The endpoint refused, so the audio engine was asked to convert --
        /// `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM`. This is what makes an arbitrary
        /// rate work.
        engine_converted,
        /// Neither worked, so the endpoint's own mix format was adopted and this
        /// library converts. Covers a channel-count or sample-type mismatch; it
        /// cannot cover a rate mismatch, because there is no resampler here.
        adopted_mix,
    };
};

/// Everything a render thread needs, once activation has succeeded.
pub const Activated = struct {
    device: Endpoint,
    client: Client,
    negotiation: Negotiation,

    /// Frames the engine's buffer holds. Usually larger than the period, and it is
    /// this -- not the period -- that bounds how much a cycle may write.
    buffer_frames: u32,
    /// Frames in one engine period.
    period_frames: u32,

    /// Present for a playback stream.
    render: ?*win32.IAudioRenderClient = null,
    /// Present for a capture or loopback stream.
    capture: ?*win32.IAudioCaptureClient = null,

    /// The position clock, for `Time.delay` and for `drain`. `IAudioClock2` when
    /// the system has it, because it stamps positions with the performance counter.
    clock2: ?*win32.IAudioClock2 = null,
    clock1: ?*win32.IAudioClock = null,

    /// This stream's own per-channel volume: what `Stream.volume` reports.
    stream_volume: ?*win32.IAudioStreamVolume = null,
    /// The whole process's session volume: what the Windows volume mixer slider
    /// moves. A different thing from `stream_volume`, and conflating them would
    /// make `Stream.setVolume` change every other stream in the process.
    session_volume: ?*win32.ISimpleAudioVolume = null,

    pub fn deinit(self: *Activated) void {
        // Reverse order of acquisition, and every one optional, so a partially
        // built `Activated` from a failed activation tears down correctly.
        com.release(self.session_volume);
        com.release(self.stream_volume);
        com.release(self.clock1);
        com.release(self.clock2);
        com.release(self.capture);
        com.release(self.render);
        self.client.release();
        self.device.deinit();
        self.* = undefined;
    }

    pub fn start(self: Activated) errors.Error!void {
        try check("IAudioClient::Start", self.client.base().Start());
    }

    /// Stop and rewind, ignoring failures.
    ///
    /// Used on the teardown and reopen paths, where the client is very often
    /// already invalid -- that being why we are tearing down -- and an error from
    /// either call tells us nothing we did not know.
    pub fn stopQuietly(self: Activated) void {
        _ = self.client.base().Stop();
        _ = self.client.base().Reset();
    }

    /// Frames the engine has not played yet. `buffer_frames` minus this is what a
    /// cycle may write.
    pub fn padding(self: Activated) errors.Error!u32 {
        var frames: u32 = 0;
        try check(
            "IAudioClient::GetCurrentPadding",
            self.client.base().GetCurrentPadding(&frames),
        );
        return frames;
    }

    /// Frames the endpoint has actually played, and when that was true.
    ///
    /// The measurement `Time.delay` is built from. Null when the clock has stalled
    /// or when the system had neither interface, in which case the caller falls
    /// back to the padding.
    pub fn devicePosition(self: Activated) ?Position {
        if (self.clock2) |clock| {
            var frames: u64 = 0;
            var qpc_100ns: u64 = 0;
            const hr = clock.GetDevicePosition(&frames, &qpc_100ns);
            if (com.failed(hr)) return null;
            // `AUDCLNT_S_POSITION_STALLED` is a success that means the number is
            // not moving, which is not something to build a latency on.
            if (com.eql(hr, win32.AUDCLNT_S_POSITION_STALLED)) return null;
            return .{
                .frames = frames,
                // The second out-parameter is in hundred-nanosecond units on the
                // performance counter, which is the one unit conversion in this
                // file that is easy to forget and impossible to notice.
                .qpc_ns = qpc_100ns * 100,
            };
        }
        if (self.clock1) |clock| {
            var frequency: u64 = 0;
            var position: u64 = 0;
            if (com.failed(clock.GetFrequency(&frequency))) return null;
            if (frequency == 0) return null;
            const hr = clock.GetPosition(&position, null);
            if (com.failed(hr)) return null;
            if (com.eql(hr, win32.AUDCLNT_S_POSITION_STALLED)) return null;
            // `IAudioClock` counts in its own units; scaling by the rate turns it
            // into frames. `IAudioClock2` skips this, which is why it is preferred.
            const rate = self.negotiation.endpoint.rate;
            return .{
                .frames = @intCast(@as(u128, position) * rate / frequency),
                .qpc_ns = null,
            };
        }
        return null;
    }

    pub const Position = struct {
        /// Frames played since the stream started.
        frames: u64,
        /// When that was true, on the performance counter, in nanoseconds. Null
        /// from `IAudioClock`, which does not stamp its positions.
        qpc_ns: ?u64,
    };
};

/// Find the endpoint a request names.
pub fn selectEndpoint(
    enumerator: Enumerator,
    request: Request,
) errors.Error!Endpoint {
    const target = request.target orelse {
        return enumerator.defaultEndpoint(request.flow, request.role);
    };

    // An endpoint id, which is what `Endpoint.id` reports and what a program should
    // save between runs. Recognised by shape rather than by trying and falling
    // back, so that a genuine id which has gone away is an error rather than
    // quietly opening some other device whose name happens to contain a brace.
    if (looksLikeEndpointId(target)) {
        return enumerator.byId(target) catch |err| switch (err) {
            error.NotFound, error.NameTooLong => {
                log.warn("no endpoint has id {s}", .{target});
                return error.DeviceNotFound;
            },
            else => |e| return e,
        };
    }

    return byNameSubstring(enumerator, request.flow, target);
}

/// Whether a target string is an endpoint id rather than a name to search for.
///
/// Ids look like `{0.0.0.00000000}.{ea2f2b17-d6b0-4ebb-a2f5-d773e023a687}`. Testing
/// for the leading brace is enough and cannot be confused with a friendly name,
/// which is a person-facing string that never starts with one.
fn looksLikeEndpointId(target: []const u8) bool {
    return target.len > 1 and target[0] == '{';
}

/// The first active endpoint whose friendly name contains `wanted`, ignoring case.
fn byNameSubstring(
    enumerator: Enumerator,
    flow: Flow,
    wanted: []const u8,
) errors.Error!Endpoint {
    var collection = try enumerator.collection(flow, win32.DEVICE_STATE_ACTIVE);
    defer collection.deinit();

    var found: ?Endpoint = null;
    var matches: u32 = 0;

    while (try collection.next()) |endpoint| {
        var device = endpoint;
        var name_buf: [Endpoint.max_name_len]u8 = undefined;
        const name = device.friendlyName(&name_buf) catch null;

        const hit = if (name) |n| containsIgnoreCase(n, wanted) else false;
        if (!hit) {
            device.deinit();
            continue;
        }

        matches += 1;
        if (found == null) {
            found = device; // keep the first
        } else {
            device.deinit();
        }
    }

    if (matches > 1) {
        // Not an error -- a caller who wrote "Speakers" on a machine with two sets
        // of them gets the first, which is better than refusing to play -- but it
        // is worth saying, because the one they got may not be the one they meant.
        log.warn("{d} endpoints match \"{s}\"; using the first", .{ matches, wanted });
    }

    return found orelse {
        log.warn("no active endpoint's name contains \"{s}\"", .{wanted});
        return error.DeviceNotFound;
    };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) continue :outer;
        }
        return true;
    }
    return false;
}

/// Activate the best `IAudioClient` an endpoint offers.
///
/// Tries newest first and falls back on `E_NOINTERFACE`, which is how a system too
/// old for an interface says so. A failure other than that is returned rather than
/// fallen back from: it means the endpoint is unusable, and trying an older
/// interface on it would only produce a less informative error.
pub fn activateClient(device: Endpoint) errors.Error!Client {
    if (device.activate(win32.IAudioClient3, win32.IID_IAudioClient3)) |ptr| {
        return .{ .tier = .three, .ptr = @ptrCast(ptr) };
    } else |err| if (err != error.Unsupported) return err;

    if (device.activate(win32.IAudioClient2, win32.IID_IAudioClient2)) |ptr| {
        log.debug("IAudioClient3 unavailable; using IAudioClient2", .{});
        return .{ .tier = .two, .ptr = @ptrCast(ptr) };
    } else |err| if (err != error.Unsupported) return err;

    const ptr = try device.activate(win32.IAudioClient, win32.IID_IAudioClient);
    log.debug("only IAudioClient is available on this endpoint", .{});
    return .{ .tier = .one, .ptr = ptr };
}

/// The endpoint's own mix format.
pub fn mixFormat(client: Client) errors.Error!Format {
    var ptr: ?*win32.WAVEFORMATEX = null;
    try check("IAudioClient::GetMixFormat", client.base().GetMixFormat(&ptr));
    const wfx = ptr orelse return error.Unexpected;
    defer win32.CoTaskMemFree(@ptrCast(wfx));

    // The structure is `align(1)` in these bindings, so reading it as bytes needs
    // no `@alignCast`. The length is the base structure plus whatever `cbSize`
    // claims, which is exactly how much of it is real.
    const bytes: [*]const u8 = @ptrCast(wfx);
    const total = format_mod.base_len + @as(usize, wfx.cbSize);

    return Format.decode(bytes[0..total]) catch |err| {
        log.warn("GetMixFormat returned a format this library cannot read: {t}", .{err});
        return error.UnsupportedFormat;
    };
}

/// Whether the endpoint will take a format as it stands.
///
/// `S_OK` means yes. `S_FALSE` means no, with a suggestion in the out-parameter --
/// which is logged, because that suggestion is the entire diagnosis when somebody
/// reports that one sample rate works and another does not.
fn isFormatSupported(client: Client, wanted: Format) bool {
    var bytes: [format_mod.extensible_len]u8 align(8) = undefined;
    _ = wanted.encodeExtensible(&bytes);

    var closest: ?*win32.WAVEFORMATEX = null;
    const hr = client.base().IsFormatSupported(
        .SHARED,
        @ptrCast(&bytes),
        &closest,
    );
    if (closest) |suggestion| {
        defer win32.CoTaskMemFree(@ptrCast(suggestion));
        const raw: [*]const u8 = @ptrCast(suggestion);
        const total = format_mod.base_len + @as(usize, suggestion.cbSize);
        if (Format.decode(raw[0..total])) |alternative| {
            log.debug("endpoint refused {f} and suggested {f}", .{ wanted, alternative });
        } else |_| {
            log.debug("endpoint refused {f} and suggested something unreadable", .{wanted});
        }
    }
    return com.succeeded(hr) and com.eql(hr, com.hresult.s_ok);
}

/// Work out what format to ask the endpoint for.
///
/// Three routes, tried in order. The first that works is taken, and which one it was
/// is recorded in the result so that a `debug` log line can say.
fn negotiate(client: Client, request: Request, mix: Format) errors.OpenError!Negotiation {
    const wanted_mask = if (request.map.len != 0)
        channel.maskFor(request.map)
    else if (channel.defaultChannelMap(request.channels)) |map|
        channel.maskFor(map)
    else
        return error.NoDefaultChannelMap;

    // What the caller asked for, in the sample type this library carries. Float is
    // what the shared-mode engine mixes in, so asking for it is asking for the
    // cheapest possible path.
    const wanted: Format = .{
        .rate = request.rate,
        .channels = request.channels,
        .sample = .f32,
        .mask = wanted_mask,
    };

    var result: Negotiation = .{
        .endpoint = wanted,
        .tier = client.tier,
        .route = .native,
        .order = @splat(0),
        .needs_permute = false,
        .needs_channel_remap = false,
    };

    // (a) Native. The endpoint takes exactly this, and nothing converts anything.
    if (isFormatSupported(client, wanted)) {
        log.debug("endpoint accepts {f} natively", .{wanted});
        result.endpoint = wanted;
        result.route = .native;
    } else if (request.rate != mix.rate) {
        // (b) Engine conversion. This is the route that makes an arbitrary rate
        // work: the audio engine inserts its own resampler. It has to go through
        // `Initialize` rather than `InitializeSharedAudioStream`, because the
        // low-latency path requires the format to match the engine's -- so taking
        // this route also gives up the shorter period.
        log.debug(
            "endpoint refused {f}; asking the engine to convert from its {f}",
            .{ wanted, mix },
        );
        result.endpoint = wanted;
        result.route = .engine_converted;
    } else {
        // (c) Adopt the endpoint's own format and convert here. Covers a channel
        // count or sample type this library can handle itself.
        //
        // It cannot cover a rate mismatch: there is no resampler in this library,
        // and inventing a poor one would be worse than saying so. Route (b) exists
        // precisely so that case does not arrive here -- but if the rates match and
        // route (a) still failed, adopting the mix format is the answer.
        log.debug("endpoint refused {f}; adopting its own {f} and converting", .{ wanted, mix });
        result.endpoint = mix;
        result.route = .adopted_mix;
    }

    // How the caller's channels land in an endpoint frame. Computed against the
    // caller's own map, because that is the order their samples arrive in.
    const caller_map = if (request.map.len != 0)
        request.map
    else
        channel.defaultChannelMap(request.channels) orelse return error.NoDefaultChannelMap;

    channel.validate(caller_map) catch |err| return switch (err) {
        error.TooManyChannels => error.TooManyChannels,
        error.DuplicateChannel, error.MonoWithOthers => error.ChannelMapMismatch,
    };

    const order = channel.wireOrder(caller_map, &result.order) catch
        return error.ChannelMapMismatch;
    result.needs_permute = !channel.isWireOrdered(caller_map);
    result.needs_channel_remap = result.endpoint.channels != request.channels;
    std.debug.assert(order.len == request.channels);

    return result;
}

/// Initialise the client, retrying once if the engine insists on an aligned buffer.
///
/// `client` may be released and re-activated in the course of this -- which is what
/// the alignment retry requires -- so it is taken by pointer.
fn initialise(
    device: Endpoint,
    client: *Client,
    negotiation: Negotiation,
    request: Request,
    event: com.Event,
) errors.OpenError!Layout {
    var attempt: u32 = 0;
    var duration_hns: i64 = 0;

    while (true) : (attempt += 1) {
        var bytes: [format_mod.extensible_len]u8 align(8) = undefined;
        _ = negotiation.endpoint.encodeExtensible(&bytes);
        const wfx: *const win32.WAVEFORMATEX = @ptrCast(&bytes);

        var flags: u32 = win32.AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
        if (request.loopback) flags |= win32.AUDCLNT_STREAMFLAGS_LOOPBACK;
        if (negotiation.route == .engine_converted) {
            flags |= win32.AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                win32.AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        }

        // The low-latency path, when everything lines up for it. Not available for
        // the engine-conversion route, and not for loopback.
        const want_shared_period = negotiation.route == .native and !request.loopback;
        if (want_shared_period) {
            if (client.as3()) |c3| {
                if (try initialiseSharedPeriod(c3, wfx, flags, request)) |layout| {
                    try setEventHandle(client.*, event);
                    return finishLayout(client.*, layout);
                }
                // Fell through: the engine's period is fixed by another program, or
                // the driver refused. `Initialize` below still works.
            }
        }

        if (duration_hns == 0) duration_hns = try defaultBufferDuration(client.*, request);

        const hr = client.base().Initialize(
            .SHARED,
            flags,
            duration_hns,
            // Must be zero in shared mode. A non-zero periodicity here is an
            // exclusive-mode thing and produces `AUDCLNT_E_INVALID_DEVICE_PERIOD`.
            0,
            wfx,
            if (request.session_guid) |*guid| guid else null,
        );

        if (com.succeeded(hr)) {
            try setEventHandle(client.*, event);
            return finishLayout(client.*, .{
                .period_frames = @intCast(@max(1, time.hnsToFrames(
                    duration_hns,
                    negotiation.endpoint.rate,
                ))),
            });
        }

        // The one failure worth retrying rather than reporting.
        //
        // Some drivers require the buffer to be a whole number of their own
        // alignment units. The documented recovery is to ask how big a buffer we
        // were given, compute the duration that many frames represent, throw the
        // client away -- an `Initialize` that failed this way cannot be called
        // again -- and start over with that duration. Vanishingly rare in shared
        // mode, and unrecoverable any other way when it does happen.
        if (com.eql(hr, win32.AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED) and attempt == 0) {
            var aligned_frames: u32 = 0;
            try check("IAudioClient::GetBufferSize", client.base().GetBufferSize(&aligned_frames));
            duration_hns = time.framesToHns(aligned_frames, negotiation.endpoint.rate);
            log.debug(
                "endpoint wants an aligned buffer; retrying with {d} frames",
                .{aligned_frames},
            );

            // A fresh client, because this one is spent.
            client.release();
            client.* = try activateClient(device);
            try applyCategory(client.*, request);
            continue;
        }

        try check("IAudioClient::Initialize", hr);
        unreachable; // `check` returns an error for a failing `hr`.
    }
}

/// What `initialise` settled on.
const Layout = struct {
    period_frames: u32,
    buffer_frames: u32 = 0,
};

/// The `IAudioClient3` low-latency path, or null if it is not available here.
fn initialiseSharedPeriod(
    c3: *win32.IAudioClient3,
    wfx: *const win32.WAVEFORMATEX,
    flags: u32,
    request: Request,
) errors.OpenError!?Layout {
    var default_frames: u32 = 0;
    var fundamental_frames: u32 = 0;
    var min_frames: u32 = 0;
    var max_frames: u32 = 0;

    const query = c3.GetSharedModeEnginePeriod(
        wfx,
        &default_frames,
        &fundamental_frames,
        &min_frames,
        &max_frames,
    );
    if (com.failed(query)) {
        log.debug("GetSharedModeEnginePeriod failed: {f}; using Initialize", .{query});
        return null;
    }

    const period = clampPeriod(.{
        .wanted = request.latency_frames orelse default_frames,
        .default_frames = default_frames,
        .fundamental = fundamental_frames,
        .min = min_frames,
        .max = max_frames,
    });

    const hr = c3.InitializeSharedAudioStream(
        flags,
        period,
        wfx,
        if (request.session_guid) |*guid| guid else null,
    );
    if (com.failed(hr)) {
        // `AUDCLNT_E_ENGINE_PERIODICITY_LOCKED` and `..._FORMAT_LOCKED` mean another
        // program got there first and fixed the engine's period or format. Not an
        // error: `Initialize` will still work at the default period.
        log.debug("InitializeSharedAudioStream({d} frames) failed: {f}; using Initialize", .{
            period,
            hr,
        });
        return null;
    }

    log.debug("shared-mode period {d} frames (min {d}, default {d}, max {d})", .{
        period,
        min_frames,
        default_frames,
        max_frames,
    });
    return .{ .period_frames = period };
}

/// Fit a wanted period into what the engine permits.
///
/// The period has to be a multiple of the fundamental and within the range, and
/// getting either wrong is an `AUDCLNT_E_INVALID_DEVICE_PERIOD` rather than a
/// rounded answer. Pulled out as a pure function so it can be tested without an
/// audio device.
fn clampPeriod(args: struct {
    wanted: u32,
    default_frames: u32,
    fundamental: u32,
    min: u32,
    max: u32,
}) u32 {
    if (args.min == 0 or args.max < args.min) return args.default_frames;

    var period = std.math.clamp(args.wanted, args.min, args.max);
    if (args.fundamental > 1) {
        // Round up to a multiple, then back inside the range -- rounding up can
        // walk past the maximum when the maximum is itself not a multiple.
        const remainder = period % args.fundamental;
        if (remainder != 0) period += args.fundamental - remainder;
        while (period > args.max) period -= args.fundamental;
        if (period < args.min) return args.default_frames;
    }
    return period;
}

fn defaultBufferDuration(client: Client, request: Request) errors.Error!i64 {
    var default_hns: i64 = 0;
    var minimum_hns: i64 = 0;
    try check(
        "IAudioClient::GetDevicePeriod",
        client.base().GetDevicePeriod(&default_hns, &minimum_hns),
    );

    if (request.latency_frames) |frames| {
        const wanted = time.framesToHns(frames, request.rate);
        // Never below the engine's own period: a shorter buffer than one cycle
        // cannot be filled in time and the engine refuses it anyway.
        return @max(wanted, default_hns);
    }
    return default_hns;
}

fn setEventHandle(client: Client, event: com.Event) errors.Error!void {
    try check("IAudioClient::SetEventHandle", client.base().SetEventHandle(event.handle));
}

fn finishLayout(client: Client, partial: Layout) errors.Error!Layout {
    var buffer_frames: u32 = 0;
    try check("IAudioClient::GetBufferSize", client.base().GetBufferSize(&buffer_frames));
    return .{
        .period_frames = @max(1, partial.period_frames),
        .buffer_frames = buffer_frames,
    };
}

/// Tell Windows what the audio is for, which is what drives ducking and the
/// per-category volume. Needs `IAudioClient2`, and must happen before `Initialize`.
fn applyCategory(client: Client, request: Request) errors.Error!void {
    const c2 = client.as2() orelse return;
    var properties: win32.AudioClientProperties = .{
        .cbSize = @sizeOf(win32.AudioClientProperties),
        .bIsOffload = 0,
        .eCategory = request.category,
        .Options = .{},
    };
    const hr = c2.SetClientProperties(&properties);
    if (com.failed(hr)) {
        // Not fatal: the stream plays, it just does not participate in ducking.
        log.debug("SetClientProperties({t}) failed: {f}", .{ request.category, hr });
    }
}

/// Open an endpoint and get it ready to carry audio.
///
/// The whole activation, in the order WASAPI requires it: choose the device, take
/// the newest client interface it has, declare the category, read its mix format,
/// negotiate, initialise, hand over the event handle, and fetch the services.
///
/// On any failure everything acquired so far is released, so a caller that gets an
/// error has nothing to clean up.
pub fn open(
    enumerator: Enumerator,
    request: Request,
    event: com.Event,
) errors.OpenError!Activated {
    if (request.channels == 0 or request.channels > channel.max_channels) {
        return error.TooManyChannels;
    }
    if (request.map.len != 0 and request.map.len != request.channels) {
        return error.ChannelMapMismatch;
    }
    if (request.rate == 0) return error.InvalidRate;

    var device = try selectEndpoint(enumerator, request);
    errdefer device.deinit();

    // Refuse a device that cannot carry audio now, rather than letting `Initialize`
    // say something less clear about it.
    const state = try device.state();
    if (!state.usable()) {
        log.warn("endpoint is {t} rather than active", .{state});
        return error.DeviceNotFound;
    }

    var client = try activateClient(device);
    errdefer client.release();

    try applyCategory(client, request);

    const mix = try mixFormat(client);
    log.debug("endpoint mixes at {f}", .{mix});

    const negotiation = try negotiate(client, request, mix);
    const layout = try initialise(device, &client, negotiation, request, event);

    // The services go into a local with its own teardown, and ownership is handed to
    // an `Activated` only once nothing can fail any more.
    //
    // ## Why not construct the `Activated` here and `errdefer` its `deinit`
    //
    // Because Zig does not cancel an `errdefer` when ownership moves. The two above --
    // for `device` and `client` -- stay armed for the rest of the function, so a
    // failure after an `Activated` had been built would release the device and the
    // client twice: once through the `Activated` and once through each earlier
    // `errdefer`. That is a double `Release` on a live COM object, and it crashes
    // inside `MMDevApi` rather than anywhere near here.
    var services: Services = .{};
    errdefer services.release();

    // A loopback client is activated on a *render* endpoint and then read from, so it
    // has the capture service and not the render one -- despite the endpoint facing the
    // other way. Asking such a client for `IAudioRenderClient` fails, so the direction
    // of the *endpoint* is not what decides this: the direction of the *data* is.
    const reads = request.loopback or request.flow == .capture;
    if (reads) {
        services.capture = try getService(
            client,
            win32.IAudioCaptureClient,
            win32.IID_IAudioCaptureClient,
        );
    } else {
        services.render = try getService(
            client,
            win32.IAudioRenderClient,
            win32.IID_IAudioRenderClient,
        );
    }

    // The position clock, preferring the one that stamps its answers with the
    // performance counter. Both are optional: without either, `Time.delay` falls back
    // to the padding and `drain` to a period of grace.
    services.clock2 = getService(client, win32.IAudioClock2, win32.IID_IAudioClock2) catch null;
    if (services.clock2 == null) {
        services.clock1 = getService(client, win32.IAudioClock, win32.IID_IAudioClock) catch null;
        if (services.clock1 == null) {
            log.debug("no position clock; latency figures will be estimates", .{});
        }
    }

    // Both volumes are optional, and they are different things -- see the fields.
    services.stream_volume = getService(
        client,
        win32.IAudioStreamVolume,
        win32.IID_IAudioStreamVolume,
    ) catch null;
    services.session_volume = getService(
        client,
        win32.ISimpleAudioVolume,
        win32.IID_ISimpleAudioVolume,
    ) catch null;

    log.debug("opened {f}: {d} frame buffer, {d} frame period, route {t}, tier {t}", .{
        negotiation.endpoint,
        layout.buffer_frames,
        layout.period_frames,
        negotiation.route,
        negotiation.tier,
    });

    // Nothing below can fail, so every `errdefer` above is now moot and the ownership
    // transfer is safe.
    return .{
        .device = device,
        .client = client,
        .negotiation = negotiation,
        .buffer_frames = layout.buffer_frames,
        .period_frames = @min(layout.period_frames, layout.buffer_frames),
        .render = services.render,
        .capture = services.capture,
        .clock2 = services.clock2,
        .clock1 = services.clock1,
        .stream_volume = services.stream_volume,
        .session_volume = services.session_volume,
    };
}

/// The interfaces fetched off an initialised client, held apart from the `Activated`
/// they will belong to so that a failure part-way releases each exactly once.
const Services = struct {
    render: ?*win32.IAudioRenderClient = null,
    capture: ?*win32.IAudioCaptureClient = null,
    clock2: ?*win32.IAudioClock2 = null,
    clock1: ?*win32.IAudioClock = null,
    stream_volume: ?*win32.IAudioStreamVolume = null,
    session_volume: ?*win32.ISimpleAudioVolume = null,

    fn release(self: *Services) void {
        com.release(self.session_volume);
        com.release(self.stream_volume);
        com.release(self.clock1);
        com.release(self.clock2);
        com.release(self.capture);
        com.release(self.render);
        self.* = .{};
    }
};

fn getService(client: Client, comptime T: type, iid: *const Guid) errors.Error!*T {
    var ptr: ?*T = null;
    const hr = client.base().GetService(iid, @ptrCast(&ptr));
    if (com.failed(hr)) return com.classifyOnly(hr);
    return ptr orelse error.Unexpected;
}

test "an endpoint id is told apart from a name to search for" {
    // The distinction decides whether a missing device is an error or a search, so
    // getting it wrong means a saved id silently opens the wrong speakers.
    try std.testing.expect(looksLikeEndpointId(
        "{0.0.0.00000000}.{ea2f2b17-d6b0-4ebb-a2f5-d773e023a687}",
    ));
    try std.testing.expect(!looksLikeEndpointId("Speakers (High Definition Audio Device)"));
    try std.testing.expect(!looksLikeEndpointId("Headphones"));
    try std.testing.expect(!looksLikeEndpointId(""));
    try std.testing.expect(!looksLikeEndpointId("{"));
}

test "a name search ignores case and matches inside the string" {
    // Which is what makes `.target = \"headphones\"` find
    // \"Headphones (WH-1000XM4 Stereo)\".
    try std.testing.expect(containsIgnoreCase("Speakers (High Definition Audio)", "speakers"));
    try std.testing.expect(containsIgnoreCase("Headphones (WH-1000XM4)", "wh-1000"));
    try std.testing.expect(containsIgnoreCase("Line In", "LINE"));
    try std.testing.expect(containsIgnoreCase("anything", ""));

    try std.testing.expect(!containsIgnoreCase("Speakers", "microphone"));
    try std.testing.expect(!containsIgnoreCase("Mic", "microphone"));
    try std.testing.expect(!containsIgnoreCase("", "x"));
}

test "a period is clamped into the range and snapped to the fundamental" {
    // A period outside the range, or not a multiple of the fundamental, is an
    // `AUDCLNT_E_INVALID_DEVICE_PERIOD` rather than a rounded answer -- so this
    // arithmetic is what stands between a caller's `latency_frames` and a refusal.
    // Numbers here are the shape a real endpoint reports: a 480-frame default with
    // 128-frame granularity.
    const shape = .{ .default_frames = 480, .fundamental = 128, .min = 128, .max = 1024 };

    // Exactly on a multiple, inside the range: taken as is.
    try std.testing.expectEqual(@as(u32, 256), clampPeriod(.{
        .wanted = 256,
        .default_frames = shape.default_frames,
        .fundamental = shape.fundamental,
        .min = shape.min,
        .max = shape.max,
    }));

    // Between multiples: rounded up, because rounding down could go below the
    // minimum and a slightly longer period is always safe.
    try std.testing.expectEqual(@as(u32, 256), clampPeriod(.{
        .wanted = 200,
        .default_frames = shape.default_frames,
        .fundamental = shape.fundamental,
        .min = shape.min,
        .max = shape.max,
    }));

    // Below the minimum: raised to it.
    try std.testing.expectEqual(@as(u32, 128), clampPeriod(.{
        .wanted = 1,
        .default_frames = shape.default_frames,
        .fundamental = shape.fundamental,
        .min = shape.min,
        .max = shape.max,
    }));

    // Above the maximum: lowered to the largest multiple that fits.
    try std.testing.expectEqual(@as(u32, 1024), clampPeriod(.{
        .wanted = 100_000,
        .default_frames = shape.default_frames,
        .fundamental = shape.fundamental,
        .min = shape.min,
        .max = shape.max,
    }));
}

test "rounding up past the maximum walks back rather than overshooting" {
    // The case the naive version gets wrong: a maximum that is not itself a
    // multiple of the fundamental. Rounding 900 up to 1024 exceeds the 1000
    // maximum, so it has to come back down to 896.
    try std.testing.expectEqual(@as(u32, 896), clampPeriod(.{
        .wanted = 900,
        .default_frames = 480,
        .fundamental = 128,
        .min = 128,
        .max = 1000,
    }));
}

test "a nonsensical range falls back to the default period" {
    // A driver reporting a zero minimum or an inverted range is not one to do
    // arithmetic with; the engine's own default is always valid.
    try std.testing.expectEqual(@as(u32, 480), clampPeriod(.{
        .wanted = 256,
        .default_frames = 480,
        .fundamental = 128,
        .min = 0,
        .max = 1024,
    }));
    try std.testing.expectEqual(@as(u32, 480), clampPeriod(.{
        .wanted = 256,
        .default_frames = 480,
        .fundamental = 128,
        .min = 1024,
        .max = 128,
    }));

    // And a range too narrow to hold any multiple of the fundamental.
    try std.testing.expectEqual(@as(u32, 480), clampPeriod(.{
        .wanted = 200,
        .default_frames = 480,
        .fundamental = 128,
        .min = 200,
        .max = 250,
    }));
}

test "a fundamental of one leaves the period alone within the range" {
    // Some endpoints report no granularity requirement at all.
    try std.testing.expectEqual(@as(u32, 333), clampPeriod(.{
        .wanted = 333,
        .default_frames = 480,
        .fundamental = 1,
        .min = 128,
        .max = 1024,
    }));
}

test "a tier upcasts to the views its generation has and no further" {
    // The fallback paths depend on these being null at the right tiers: a tier-one
    // client asked for `SetClientProperties` would call through a vtable slot that
    // does not exist.
    const fake: *win32.IAudioClient = @ptrFromInt(0x1000);

    const one: Client = .{ .tier = .one, .ptr = fake };
    try std.testing.expect(one.as2() == null);
    try std.testing.expect(one.as3() == null);

    const two: Client = .{ .tier = .two, .ptr = fake };
    try std.testing.expect(two.as2() != null);
    try std.testing.expect(two.as3() == null);

    const three: Client = .{ .tier = .three, .ptr = fake };
    try std.testing.expect(three.as2() != null);
    try std.testing.expect(three.as3() != null);
}

test {
    std.testing.refAllDecls(@This());
}
