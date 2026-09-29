// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What is playing, where, and how loudly: the control plane.
//!
//! ```zig
//! var session: wasapi.Session = try .open(io, .{});
//! defer session.close(io);
//!
//! var sinks = try session.sinks();
//! defer sinks.deinit();
//! while (try sinks.next()) |endpoint| {
//!     var device = endpoint;
//!     defer device.deinit();
//!     var buf: [wasapi.Endpoint.max_name_len]u8 = undefined;
//!     std.debug.print("{s} at {d:.0}%\n", .{
//!         try device.label(&buf),
//!         (try session.volume(device)).level * 100,
//!     });
//! }
//! ```
//!
//! ## How this differs from zig-pipewire's `Session`, and why
//!
//! PipeWire has a graph, so its `Session` is a *cache*: it subscribes to a registry,
//! keeps a copy of every object, and `roundTrip` brings the copy up to date. Windows
//! has no graph and no registry. What it has is two live queries -- enumerate the
//! endpoints, enumerate the audio sessions on an endpoint -- so this type is a handle
//! that runs them rather than a cache that mirrors them.
//!
//! That removes `roundTrip` (there is nothing to synchronise), `Object`,
//! `ObjectType` and `Filter` (the query takes the filter), and the whole idea of an
//! object id that stays valid (an `Endpoint` is a reference-counted COM object the
//! caller holds). It also means this type allocates nothing at all.
//!
//! Three things PipeWire can do that Windows simply cannot, each of which would
//! otherwise be a puzzling absence:
//!
//!   * **Ports and links.** There is no user-visible graph to wire up. Which
//!     endpoint a program plays to is chosen by the program (`Stream.Options.target`)
//!     or by Windows, and nothing rewires an existing stream.
//!   * **Setting the default endpoint.** See `setDefaultSink`.
//!   * **A metadata store.** Nothing corresponds to it.
//!
//! ## Two volumes, which are different things
//!
//! An **endpoint** volume is the device's own -- what the speaker icon in the system
//! tray moves, shared by everything playing to that device. An **audio session**
//! volume belongs to one process, and is what the per-application sliders in the
//! Volume Mixer move. `volume` and `setVolume` take an endpoint; `AppSession.level`
//! and `setLevel` take a session. Conflating them is how a program ends up turning
//! the whole machine down when it meant to turn itself down.

const Session = @This();

const std = @import("std");

const errors = @import("errors.zig");
const channel = @import("channel.zig");
const Log = @import("log.zig").Log;

const com = @import("com/com.zig");
const check = com.check;

const log = std.log.scoped(.wasapi);

const win32 = @import("win32").everything;

pub const Endpoint = com.Endpoint;
pub const Flow = com.Flow;
pub const Role = com.Role;
pub const EndpointState = com.EndpointState;
pub const Collection = com.enumerator.Collection;

/// How the session presents itself.
pub const Options = struct {
    /// Unused by Windows, which has nothing to show a control-plane client's name in.
    /// Kept so that the shape matches zig-pipewire's `Session.Options` and so a
    /// program moving between them does not have to delete the field.
    name: []const u8 = "zig-windows-audio",
    log: ?Log = null,
};

apartment: com.Apartment,
enumerator: com.Enumerator,
options: Options,

/// Open a control-plane session on the calling thread.
///
/// The thread is put in an apartment if it is not in one already -- and left alone if
/// the host application already chose a different one, which for a graphical program
/// it will have. See `com.Apartment`.
///
/// Every interface this session holds is used on the thread that opened it. A
/// `Session` is therefore **not** safe to share between threads; open one per thread
/// that needs it, which costs an apartment reference and a COM object.
pub fn open(io: std.Io, options: Options) errors.SessionError!Session {
    _ = io;
    var apartment: com.Apartment = try .enter(com.coinit_multithreaded);
    errdefer apartment.leave();

    const enumerator: com.Enumerator = try .create();
    return .{ .apartment = apartment, .enumerator = enumerator, .options = options };
}

pub fn close(self: *Session, io: std.Io) void {
    _ = io;
    self.enumerator.deinit();
    self.apartment.leave();
    self.* = undefined;
}

// --- finding endpoints ---

/// Every endpoint in one direction, including the ones switched off.
///
/// The caller owns the collection and each endpoint it yields. `state_mask` is
/// `com.enumerator.state_mask_all` for everything, or `DEVICE_STATE_ACTIVE` for just
/// what can be played to.
pub fn endpoints(self: *const Session, flow: Flow, state_mask: u32) errors.SessionError!Collection {
    return self.enumerator.collection(flow, state_mask);
}

/// Every active output. The Windows counterpart of PipeWire's sinks.
pub fn sinks(self: *const Session) errors.SessionError!Collection {
    return self.enumerator.collection(.render, win32.DEVICE_STATE_ACTIVE);
}

/// Every active input.
pub fn sources(self: *const Session) errors.SessionError!Collection {
    return self.enumerator.collection(.capture, win32.DEVICE_STATE_ACTIVE);
}

/// The endpoint Windows would play this kind of audio to.
pub fn default(self: *const Session, flow: Flow, role: Role) errors.SessionError!Endpoint {
    return self.enumerator.defaultEndpoint(flow, role);
}

/// The default output, or null when the machine has none.
///
/// Null rather than an error, because a machine with no sound card is a normal thing
/// for a program to run on and not a failure it should report.
pub fn defaultSink(self: *const Session) errors.SessionError!?Endpoint {
    return self.enumerator.defaultEndpoint(.render, .console) catch |err| switch (err) {
        error.DeviceNotFound => null,
        else => |e| e,
    };
}

/// The default input, or null when the machine has none.
pub fn defaultSource(self: *const Session) errors.SessionError!?Endpoint {
    return self.enumerator.defaultEndpoint(.capture, .console) catch |err| switch (err) {
        error.DeviceNotFound => null,
        else => |e| e,
    };
}

/// One endpoint by the id `Endpoint.id` reported earlier.
pub fn byId(self: *const Session, id: []const u8) errors.SessionError!Endpoint {
    return self.enumerator.byId(id);
}

/// Change which endpoint Windows sends audio to. **Always fails.**
///
/// Windows exposes no public API for this. The Sound control panel does it through
/// `IPolicyConfig`, an undocumented interface that is not in the Windows metadata, has
/// changed shape between Windows versions, and would have to be declared by hand from
/// a reverse-engineered vtable. This library will not ship that: a program that got it
/// wrong would corrupt the audio policy store rather than merely fail.
///
/// This exists so the gap is documented where a reader will look for it, rather than
/// being an unexplained absence. What a program can do instead is choose its own
/// endpoint with `Stream.Options.target`, which needs no permission and affects
/// nothing else on the machine.
pub fn setDefaultSink(self: *const Session, id: []const u8) errors.SessionError!void {
    _ = self;
    _ = id;
    return error.Unsupported;
}

// --- endpoint volume ---

/// How loud an endpoint is.
pub const Volume = struct {
    /// The master level, 0 to 1, on the scale the volume slider uses -- which is
    /// perceptual rather than linear amplitude. This is the number to show a person.
    level: f32,
    /// Whether it is muted, which is independent of the level: unmuting restores
    /// whatever the level was.
    muted: bool,
    /// Per-channel levels, as linear amplitudes. `channels` of them are valid.
    channels: [channel.max_channels]f32 = @splat(0),
    channel_count: u16 = 0,

    /// The valid part of `channels`.
    pub fn channelLevels(self: *const Volume) []const f32 {
        return self.channels[0..self.channel_count];
    }

    pub fn format(self: Volume, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d:.0}%", .{self.level * 100});
        if (self.muted) try w.writeAll(" (muted)");
    }
};

fn endpointVolume(endpoint: Endpoint) errors.SessionError!*win32.IAudioEndpointVolume {
    return endpoint.activate(win32.IAudioEndpointVolume, win32.IID_IAudioEndpointVolume);
}

/// Read an endpoint's volume.
pub fn volume(self: *const Session, endpoint: Endpoint) errors.SessionError!Volume {
    _ = self;
    const control = try endpointVolume(endpoint);
    defer com.release(control);

    var level: f32 = 0;
    try check(
        "IAudioEndpointVolume::GetMasterVolumeLevelScalar",
        control.GetMasterVolumeLevelScalar(&level),
    );

    var muted: win32.BOOL = 0;
    try check("IAudioEndpointVolume::GetMute", control.GetMute(&muted));

    var count: u32 = 0;
    try check("IAudioEndpointVolume::GetChannelCount", control.GetChannelCount(&count));

    var result: Volume = .{ .level = level, .muted = muted != 0 };
    result.channel_count = @intCast(@min(count, channel.max_channels));
    for (0..result.channel_count) |i| {
        var channel_level: f32 = 0;
        if (com.succeeded(control.GetChannelVolumeLevelScalar(@intCast(i), &channel_level))) {
            result.channels[i] = channel_level;
        }
    }
    return result;
}

/// Set an endpoint's master volume, 0 to 1.
///
/// This is the whole device: everything playing to it gets quieter. To change only
/// this program's contribution, use `Stream.setVolume` or an `AppSession`.
pub fn setVolume(self: *const Session, endpoint: Endpoint, level: f32) errors.SessionError!void {
    _ = self;
    const control = try endpointVolume(endpoint);
    defer com.release(control);

    try check(
        "IAudioEndpointVolume::SetMasterVolumeLevelScalar",
        control.SetMasterVolumeLevelScalar(std.math.clamp(level, 0, 1), null),
    );
}

/// Set each channel of an endpoint separately, as linear amplitudes, in the endpoint's
/// own channel order.
pub fn setChannelVolumes(
    self: *const Session,
    endpoint: Endpoint,
    levels: []const f32,
) errors.SessionError!void {
    _ = self;
    const control = try endpointVolume(endpoint);
    defer com.release(control);

    var count: u32 = 0;
    try check("IAudioEndpointVolume::GetChannelCount", control.GetChannelCount(&count));
    if (levels.len != count) {
        log.warn("endpoint has {d} channels and {d} levels were given", .{ count, levels.len });
        return error.Unexpected;
    }

    for (levels, 0..) |level, i| {
        try check(
            "IAudioEndpointVolume::SetChannelVolumeLevelScalar",
            control.SetChannelVolumeLevelScalar(
                @intCast(i),
                std.math.clamp(level, 0, 1),
                null,
            ),
        );
    }
}

pub fn setMute(self: *const Session, endpoint: Endpoint, muted: bool) errors.SessionError!void {
    _ = self;
    const control = try endpointVolume(endpoint);
    defer com.release(control);
    try check("IAudioEndpointVolume::SetMute", control.SetMute(if (muted) 1 else 0, null));
}

/// The loudest sample the endpoint has seen lately, 0 to 1.
///
/// What a level meter shows. It is a peak over an unspecified recent window rather
/// than over a period a caller chooses, which is all Windows offers -- so it is
/// suitable for a meter and not for measurement.
pub fn peak(self: *const Session, endpoint: Endpoint) errors.SessionError!f32 {
    _ = self;
    const meter = try endpoint.activate(
        win32.IAudioMeterInformation,
        win32.IID_IAudioMeterInformation,
    );
    defer com.release(meter);

    var value: f32 = 0;
    try check("IAudioMeterInformation::GetPeakValue", meter.GetPeakValue(&value));
    return value;
}

// --- per-application audio sessions ---

/// What one process is playing to an endpoint, and how loudly.
///
/// The Windows counterpart of a PipeWire stream node: one entry in the Volume Mixer.
/// The caller owns it and must `deinit` it.
pub const AppSession = struct {
    control: *win32.IAudioSessionControl2,
    volume: *win32.ISimpleAudioVolume,

    /// Enough for any session display name. Names come from executables and from
    /// applications' own strings, so this is a generous guess rather than a limit
    /// Windows documents.
    pub const max_name_len = 512;

    pub fn deinit(self: *AppSession) void {
        com.release(self.volume);
        com.release(self.control);
        self.* = undefined;
    }

    /// The process this audio belongs to, or zero for the system sounds session.
    pub fn processId(self: AppSession) errors.SessionError!u32 {
        var pid: u32 = 0;
        try check("IAudioSessionControl2::GetProcessId", self.control.GetProcessId(&pid));
        return pid;
    }

    /// Whether this is Windows' own notification-sound session rather than an
    /// application's.
    ///
    /// Worth telling apart: it has no process to name, and a mixer that lists it as a
    /// nameless entry looks broken.
    pub fn isSystemSounds(self: AppSession) bool {
        // `S_OK` for yes and `S_FALSE` for no -- both successes, which is why this
        // cannot go through `check`.
        return com.eql(self.control.IsSystemSoundsSession(), com.hresult.s_ok);
    }

    /// The name the application set for itself, if it set one.
    ///
    /// Very often empty: most programs never call `SetDisplayName`, and the Volume
    /// Mixer shows their executable's name instead -- which it gets from the process,
    /// not from here. A caller wanting a name to show should fall back to looking up
    /// `processId`.
    pub fn displayName(self: AppSession, buf: []u8) errors.SessionError!?[]const u8 {
        var wide: ?[*:0]u16 = null;
        try check(
            "IAudioSessionControl2::GetDisplayName",
            self.control.IAudioSessionControl.GetDisplayName(&wide),
        );
        const ptr = wide orelse return null;
        defer win32.CoTaskMemFree(@ptrCast(ptr));
        const name = try com.utf8FromWide(buf, ptr);
        return if (name.len == 0) null else name;
    }

    /// The identifier that stays the same across runs of the same application, for a
    /// program that remembers a per-application setting.
    pub fn identifier(self: AppSession, buf: []u8) errors.SessionError![]const u8 {
        var wide: ?[*:0]u16 = null;
        try check(
            "IAudioSessionControl2::GetSessionIdentifier",
            self.control.GetSessionIdentifier(&wide),
        );
        const ptr = wide orelse return error.Unexpected;
        defer win32.CoTaskMemFree(@ptrCast(ptr));
        return com.utf8FromWide(buf, ptr);
    }

    /// Whether this session is making sound right now.
    pub fn state(self: AppSession) errors.SessionError!State {
        var value: win32.AudioSessionState = .Inactive;
        try check(
            "IAudioSessionControl::GetState",
            self.control.IAudioSessionControl.GetState(&value),
        );
        return switch (value) {
            .Active => .active,
            .Inactive => .inactive,
            .Expired => .expired,
        };
    }

    pub const State = enum {
        /// Playing audio now.
        active,
        /// Open but silent: the program has a stream and is not feeding it.
        inactive,
        /// The program has gone. The entry lingers briefly so a mixer does not flicker.
        expired,
    };

    /// This session's own volume, 0 to 1: the per-application slider.
    pub fn level(self: AppSession) errors.SessionError!f32 {
        var value: f32 = 0;
        try check("ISimpleAudioVolume::GetMasterVolume", self.volume.GetMasterVolume(&value));
        return value;
    }

    pub fn setLevel(self: AppSession, value: f32) errors.SessionError!void {
        try check("ISimpleAudioVolume::SetMasterVolume", self.volume.SetMasterVolume(
            std.math.clamp(value, 0, 1),
            null,
        ));
    }

    pub fn muted(self: AppSession) errors.SessionError!bool {
        var value: win32.BOOL = 0;
        try check("ISimpleAudioVolume::GetMute", self.volume.GetMute(&value));
        return value != 0;
    }

    pub fn setMuted(self: AppSession, value: bool) errors.SessionError!void {
        try check("ISimpleAudioVolume::SetMute", self.volume.SetMute(if (value) 1 else 0, null));
    }
};

/// The audio sessions on one endpoint.
pub const AppSessions = struct {
    manager: *win32.IAudioSessionManager2,
    list: *win32.IAudioSessionEnumerator,
    count: i32,
    index: i32 = 0,

    pub fn deinit(self: *AppSessions) void {
        com.release(self.list);
        com.release(self.manager);
        self.* = undefined;
    }

    /// The next session, or null at the end. The caller owns what comes back.
    pub fn next(self: *AppSessions) errors.SessionError!?AppSession {
        while (self.index < self.count) {
            const at = self.index;
            self.index += 1;

            var control1: ?*win32.IAudioSessionControl = null;
            try check("IAudioSessionEnumerator::GetSession", self.list.GetSession(at, &control1));
            const base = control1 orelse continue;

            // Everything worth knowing about a session -- its process, its
            // identifier, whether it is the system sounds -- is on the second
            // version of the interface, so a session that has only the first is one
            // this library cannot describe.
            const control = com.queryInterface(
                win32.IAudioSessionControl2,
                base,
                win32.IID_IAudioSessionControl2,
            ) catch {
                com.release(base);
                continue;
            };
            com.release(base);

            const simple = com.queryInterface(
                win32.ISimpleAudioVolume,
                control,
                win32.IID_ISimpleAudioVolume,
            ) catch {
                com.release(control);
                continue;
            };

            return .{ .control = control, .volume = simple };
        }
        return null;
    }
};

/// Every application playing to an endpoint: what the Volume Mixer lists.
pub fn appSessions(self: *const Session, endpoint: Endpoint) errors.SessionError!AppSessions {
    _ = self;
    const manager = try endpoint.activate(
        win32.IAudioSessionManager2,
        win32.IID_IAudioSessionManager2,
    );
    errdefer com.release(manager);

    var list: ?*win32.IAudioSessionEnumerator = null;
    try check(
        "IAudioSessionManager2::GetSessionEnumerator",
        manager.GetSessionEnumerator(&list),
    );
    const sessions = list orelse return error.Unexpected;
    errdefer com.release(sessions);

    var count: i32 = 0;
    try check("IAudioSessionEnumerator::GetCount", sessions.GetCount(&count));

    return .{ .manager = manager, .list = sessions, .count = count };
}

test "setting the default endpoint reports that Windows will not allow it" {
    // Asserted rather than merely documented, because the temptation to "fix" this by
    // declaring `IPolicyConfig` by hand will recur -- and the reason not to is in the
    // doc comment above.
    var session: Session = undefined;
    try std.testing.expectError(
        error.Unsupported,
        session.setDefaultSink("{0.0.0.00000000}.{whatever}"),
    );
}

test "a volume prints as a percentage a person can read" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "50%",
        try std.fmt.bufPrint(&buf, "{f}", .{Volume{ .level = 0.5, .muted = false }}),
    );
    // Muting is independent of the level, so both are shown: a muted endpoint at
    // 80% is a different thing from one turned down to zero.
    try std.testing.expectEqualStrings(
        "80% (muted)",
        try std.fmt.bufPrint(&buf, "{f}", .{Volume{ .level = 0.8, .muted = true }}),
    );
}

test "only the reported channels of a volume are valid" {
    // The array is fixed at `max_channels`; reading past `channel_count` would report
    // zeroes as though the endpoint had silent channels.
    var v: Volume = .{ .level = 1, .muted = false, .channel_count = 2 };
    v.channels[0] = 0.5;
    v.channels[1] = 0.25;
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.25 }, v.channelLevels());
}

test "a session opens on this thread and closes cleanly" {
    // Exercises the apartment handling against whatever apartment the test runner's
    // thread is already in, which is the case a library actually meets.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var session: Session = try .open(io, .{});
    defer session.close(io);

    // A machine with no sound card is a valid machine, so null is a pass.
    if (try session.defaultSink()) |endpoint| {
        var device = endpoint;
        defer device.deinit();
        try std.testing.expect((try device.state()).usable());
    }
}

test "enumerating endpoints yields as many as the collection claims" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var session: Session = try .open(io, .{});
    defer session.close(io);

    var outputs = try session.sinks();
    defer outputs.deinit();

    var seen: u32 = 0;
    while (try outputs.next()) |endpoint| {
        var device = endpoint;
        defer device.deinit();
        // Every endpoint the enumerator lists has an id, which is what makes it
        // reopenable later.
        var buf: [Endpoint.max_id_len]u8 = undefined;
        try std.testing.expect((try device.id(&buf)).len > 0);
        seen += 1;
    }
    try std.testing.expectEqual(outputs.count, seen);
}

test {
    std.testing.refAllDecls(@This());
}
