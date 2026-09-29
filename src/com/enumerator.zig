// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Finding an audio endpoint, which everything else in this library starts by
//! doing.
//!
//! ```zig
//! var enumerator: Enumerator = try .create();
//! defer enumerator.deinit();
//!
//! var device = try enumerator.defaultEndpoint(.render, .console);
//! defer device.deinit();
//!
//! var name_buf: [Endpoint.max_name_len]u8 = undefined;
//! std.debug.print("{s}\n", .{try device.friendlyName(&name_buf)});
//! ```
//!
//! ## What an endpoint is, and what it is not
//!
//! An `IMMDevice` here is one *endpoint* -- the speakers, the headphones, one
//! line on one sound card -- and not the sound card itself. That is the right
//! grain for this library because it is what audio is played to and what has a
//! volume, and it is the closest thing Windows has to a PipeWire sink.
//!
//! The caller's thread must already be in an apartment; see `com.Apartment`.
//! Nothing here enters one, because whether that is this library's business
//! depends on which thread it is -- a render thread, which owns itself, or a
//! caller's, which does not.

const std = @import("std");

const errors = @import("../errors.zig");
const com = @import("com.zig");
const check = com.check;

const log = std.log.scoped(.wasapi);

const win32 = @import("win32").everything;

/// Which way audio moves through an endpoint.
///
/// Named for what a caller is looking for rather than transliterating
/// `EDataFlow`'s `eRender`/`eCapture`: a caller wants somewhere to play to or
/// something to record from, and `.render`/`.capture` says that in the words the
/// Core Audio documentation uses throughout.
pub const Flow = enum {
    /// An output: what audio is played to.
    render,
    /// An input: what audio is recorded from.
    capture,

    pub fn toEDataFlow(self: Flow) win32.EDataFlow {
        return switch (self) {
            .render => .eRender,
            .capture => .eCapture,
        };
    }

    pub fn fromEDataFlow(flow: win32.EDataFlow) ?Flow {
        return switch (flow) {
            .eRender => .render,
            .eCapture => .capture,
            // `eAll` is a query filter rather than a property an endpoint can
            // have, and the trailing `EDataFlow_enum_count` is an artefact of
            // the C enum. Neither describes a real endpoint.
            else => null,
        };
    }
};

/// Which of Windows' three default endpoints is wanted.
///
/// Windows keeps a separate default per purpose, which is why a headset can be
/// the default for a voice call while the speakers stay the default for music.
/// A program that plays audio almost always wants `.console`.
pub const Role = enum {
    /// What the user expects sound to come out of: games, system sounds, and
    /// anything that has not got an opinion.
    console,
    /// Where the user would rather hear music and films, if they have said.
    multimedia,
    /// The voice-call endpoint: usually a headset, and usually not where a
    /// program should play music.
    communications,

    pub fn toERole(self: Role) win32.ERole {
        return switch (self) {
            .console => .eConsole,
            .multimedia => .eMultimedia,
            .communications => .eCommunications,
        };
    }
};

/// What Windows thinks of an endpoint at the moment.
pub const State = enum {
    /// Present and usable.
    active,
    /// Present, but switched off in the Sound control panel. It cannot be
    /// opened until a person re-enables it.
    disabled,
    /// The driver is installed but the hardware is not there -- a dock that is
    /// not docked.
    not_present,
    /// The hardware is there but nothing is plugged into the jack.
    unplugged,

    pub fn fromMask(mask: u32) ?State {
        return switch (mask) {
            win32.DEVICE_STATE_ACTIVE => .active,
            win32.DEVICE_STATE_DISABLED => .disabled,
            win32.DEVICE_STATE_NOTPRESENT => .not_present,
            win32.DEVICE_STATE_UNPLUGGED => .unplugged,
            else => null,
        };
    }

    /// Whether a stream can be opened on an endpoint in this state.
    pub fn usable(self: State) bool {
        return self == .active;
    }
};

/// Every state, for a listing that wants to show what is switched off as well as
/// what is not. `DEVICE_STATEMASK_ALL` by another name.
pub const state_mask_all: u32 = win32.DEVICE_STATE_ACTIVE |
    win32.DEVICE_STATE_DISABLED |
    win32.DEVICE_STATE_NOTPRESENT |
    win32.DEVICE_STATE_UNPLUGGED;

/// The `IMMDeviceEnumerator`: the root object of Core Audio's device half.
///
/// Worth holding for as long as there is any chance of wanting another endpoint,
/// rather than creating one per lookup. It survives devices coming and going --
/// including the endpoint it was used to find being unplugged -- so the reopen
/// path in `Stream` keeps one for the life of the stream and re-uses it.
pub const Enumerator = struct {
    ptr: *win32.IMMDeviceEnumerator,

    pub fn create() errors.Error!Enumerator {
        return .{ .ptr = try com.create(
            win32.IMMDeviceEnumerator,
            win32.CLSID_MMDeviceEnumerator,
            win32.IID_IMMDeviceEnumerator,
        ) };
    }

    pub fn deinit(self: *Enumerator) void {
        com.release(self.ptr);
        self.* = undefined;
    }

    /// The endpoint Windows would send this kind of audio to.
    ///
    /// `error.DeviceNotFound` when there is none -- a machine with no sound
    /// card, or one whose only output is disabled. That is a normal answer on a
    /// virtual machine and on a continuous-integration runner, so it is worth
    /// handling rather than treating as broken.
    pub fn defaultEndpoint(self: Enumerator, flow: Flow, role: Role) errors.Error!Endpoint {
        var device: ?*win32.IMMDevice = null;
        try check("IMMDeviceEnumerator::GetDefaultAudioEndpoint", self.ptr.GetDefaultAudioEndpoint(
            flow.toEDataFlow(),
            role.toERole(),
            &device,
        ));
        return .{ .ptr = device orelse return error.DeviceNotFound };
    }

    /// One endpoint by the id `Endpoint.id` reported earlier.
    ///
    /// The way to reopen the same endpoint across runs of a program, and the way
    /// `Stream.Options.target` names one exactly.
    pub fn byId(self: Enumerator, id: []const u8) errors.LookupError!Endpoint {
        var wide: [max_id_wide_len:0]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&wide, id) catch return error.NotFound;
        if (len >= wide.len) return error.NameTooLong;
        wide[len] = 0;

        var device: ?*win32.IMMDevice = null;
        const hr = self.ptr.GetDevice(wide[0..len :0].ptr, &device);
        if (com.failed(hr)) {
            // Not found is the expected answer for a saved id whose device has
            // since gone, so it is not worth a warning.
            log.debug("IMMDeviceEnumerator::GetDevice({s}): {f}", .{ id, hr });
            return error.NotFound;
        }
        return .{ .ptr = device orelse return error.NotFound };
    }

    /// Every endpoint in one direction, in whatever order Windows lists them.
    pub fn collection(self: Enumerator, flow: Flow, state_mask: u32) errors.Error!Collection {
        var ptr: ?*win32.IMMDeviceCollection = null;
        try check("IMMDeviceEnumerator::EnumAudioEndpoints", self.ptr.EnumAudioEndpoints(
            flow.toEDataFlow(),
            state_mask,
            &ptr,
        ));
        const devices = ptr orelse return error.Unexpected;
        var count: u32 = 0;
        try check("IMMDeviceCollection::GetCount", devices.GetCount(&count));
        return .{ .ptr = devices, .count = count };
    }
};

/// A list of endpoints, and the index into it.
///
/// A handle onto a COM collection rather than a slice, because materialising it
/// would mean allocating and because a caller that only wants to print the list
/// never needs it materialised.
pub const Collection = struct {
    ptr: *win32.IMMDeviceCollection,
    count: u32,
    index: u32 = 0,

    pub fn deinit(self: *Collection) void {
        com.release(self.ptr);
        self.* = undefined;
    }

    /// The next endpoint, or null at the end. The caller owns what comes back
    /// and must `deinit` it.
    pub fn next(self: *Collection) errors.Error!?Endpoint {
        if (self.index >= self.count) return null;
        defer self.index += 1;
        var device: ?*win32.IMMDevice = null;
        try check("IMMDeviceCollection::Item", self.ptr.Item(self.index, &device));
        return .{ .ptr = device orelse return error.Unexpected };
    }
};

/// The longest endpoint id this library will carry, in UTF-16 code units.
///
/// Real ids look like
/// `{0.0.0.00000000}.{a1b2c3d4-...}` and run to about a hundred characters. A
/// larger one is not refused because it is implausible but because the buffers
/// that hold it are on stacks, including a render thread's, and an unbounded id
/// would have to be allocated on a path that must not allocate.
pub const max_id_wide_len = 256;

/// One audio endpoint.
///
/// `TitleCase` because the file it would live in is this type -- it is only here
/// in `enumerator.zig` because an endpoint and the thing that finds endpoints are
/// too small to separate and are always used together.
pub const Endpoint = struct {
    ptr: *win32.IMMDevice,

    /// Enough for any endpoint id, in UTF-8. Three bytes per UTF-16 code unit is
    /// the worst case for anything outside the supplementary planes, which an id
    /// -- being a pair of GUIDs -- will never reach.
    pub const max_id_len = max_id_wide_len * 3;

    /// Enough for any friendly name. Names are set by drivers and by people, so
    /// this is a generous guess rather than a documented limit; `utf8FromWide`
    /// reports `error.NameTooLong` rather than truncating if it is ever wrong.
    pub const max_name_len = 512;

    pub fn deinit(self: *Endpoint) void {
        com.release(self.ptr);
        self.* = undefined;
    }

    /// The stable identifier for this endpoint, written into `buf`.
    ///
    /// Stable across reboots and across the device being unplugged and plugged
    /// back in, which is what makes it the right thing to save in a
    /// configuration file and hand to `Enumerator.byId` later.
    pub fn id(self: Endpoint, buf: []u8) errors.LookupError![]const u8 {
        var wide: ?[*:0]u16 = null;
        try check("IMMDevice::GetId", self.ptr.GetId(&wide));
        const ptr = wide orelse return error.Unexpected;
        defer win32.CoTaskMemFree(@ptrCast(ptr));
        return try com.utf8FromWide(buf, ptr);
    }

    /// The name a person would recognise, written into `buf`.
    ///
    /// This is the whole string Windows shows, which includes the adapter in
    /// parentheses -- "Speakers (Realtek(R) Audio)" -- because that is what
    /// distinguishes two endpoints that are both called "Speakers".
    ///
    /// Null when the endpoint has no name property at all, which is rare but
    /// legal; a caller should fall back to the id rather than treat it as a
    /// failure, and `label` does exactly that.
    pub fn friendlyName(self: Endpoint, buf: []u8) errors.LookupError!?[]const u8 {
        var store: ?*win32.IPropertyStore = null;
        try check("IMMDevice::OpenPropertyStore", self.ptr.OpenPropertyStore(com.stgm_read, &store));
        const properties = store orelse return error.Unexpected;
        defer com.release(properties);

        return try com.propString(properties, &win32.PKEY_Device_FriendlyName, buf);
    }

    /// The best name to show a person: the friendly name if there is one, and
    /// the id if there is not.
    ///
    /// Always returns something, because a listing with a blank line in it is
    /// worse than a listing with an ugly line in it.
    pub fn label(self: Endpoint, buf: []u8) errors.LookupError![]const u8 {
        if (self.friendlyName(buf) catch null) |name| {
            if (name.len != 0) return name;
        }
        return self.id(buf);
    }

    /// What Windows thinks of this endpoint at the moment.
    pub fn state(self: Endpoint) errors.Error!State {
        var mask: u32 = 0;
        try check("IMMDevice::GetState", self.ptr.GetState(&mask));
        return State.fromMask(mask) orelse {
            log.warn("IMMDevice::GetState reported an unknown state mask 0x{X}", .{mask});
            return error.Unexpected;
        };
    }

    /// Which way this endpoint faces.
    pub fn flow(self: Endpoint) errors.Error!Flow {
        const endpoint = try com.queryInterface(win32.IMMEndpoint, self.ptr, win32.IID_IMMEndpoint);
        defer com.release(endpoint);

        var data_flow: win32.EDataFlow = .eRender;
        try check("IMMEndpoint::GetDataFlow", endpoint.GetDataFlow(&data_flow));
        return Flow.fromEDataFlow(data_flow) orelse error.Unexpected;
    }

    /// Activate an interface on this endpoint.
    ///
    /// The one call that turns an endpoint into something that can carry audio:
    /// `activate(IAudioClient, IID_IAudioClient)` is how a stream begins.
    /// Exported rather than kept private so that a caller who needs an interface
    /// this library does not wrap can still reach it.
    pub fn activate(self: Endpoint, comptime T: type, iid: *const win32.Guid) errors.Error!*T {
        var ptr: ?*T = null;
        const hr = self.ptr.Activate(iid, com.clsctx_all, null, @ptrCast(&ptr));
        if (com.failed(hr)) return com.classifyOnly(hr);
        return ptr orelse error.Unexpected;
    }
};

test "a flow survives the round trip through EDataFlow" {
    // The mapping is small enough to write by hand and therefore small enough
    // to get backwards, which would open a microphone to play music into.
    try std.testing.expectEqual(Flow.render, Flow.fromEDataFlow(Flow.render.toEDataFlow()).?);
    try std.testing.expectEqual(Flow.capture, Flow.fromEDataFlow(Flow.capture.toEDataFlow()).?);
    try std.testing.expectEqual(win32.EDataFlow.eRender, Flow.render.toEDataFlow());
    try std.testing.expectEqual(win32.EDataFlow.eCapture, Flow.capture.toEDataFlow());
}

test "eAll is not a flow an endpoint can have" {
    // It is a filter for `EnumAudioEndpoints`, and treating it as a property
    // would make `Endpoint.flow` claim an endpoint faces both ways.
    try std.testing.expectEqual(@as(?Flow, null), Flow.fromEDataFlow(.eAll));
}

test "only an active endpoint is usable" {
    try std.testing.expect(State.active.usable());
    try std.testing.expect(!State.disabled.usable());
    try std.testing.expect(!State.not_present.usable());
    try std.testing.expect(!State.unplugged.usable());
}

test "every documented state mask maps to a state, and the combined mask does not" {
    for ([_]u32{
        win32.DEVICE_STATE_ACTIVE,
        win32.DEVICE_STATE_DISABLED,
        win32.DEVICE_STATE_NOTPRESENT,
        win32.DEVICE_STATE_UNPLUGGED,
    }) |mask| {
        try std.testing.expect(State.fromMask(mask) != null);
    }

    // `GetState` reports exactly one state, so a combination is a sign that
    // something has been misread rather than a state to invent a name for.
    try std.testing.expectEqual(@as(?State, null), State.fromMask(state_mask_all));
    try std.testing.expectEqual(@as(?State, null), State.fromMask(0));
}

test "roles map to the three Windows keeps separately" {
    try std.testing.expectEqual(win32.ERole.eConsole, Role.console.toERole());
    try std.testing.expectEqual(win32.ERole.eMultimedia, Role.multimedia.toERole());
    try std.testing.expectEqual(win32.ERole.eCommunications, Role.communications.toERole());
}

test {
    std.testing.refAllDecls(@This());
}
