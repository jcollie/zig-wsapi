// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Being told when the audio devices change, which means implementing a COM interface
//! rather than calling one.
//!
//! ```zig
//! var client = try NotificationClient.create(gpa, .{ .flags = &my_flags, .event = my_event });
//! try client.register(enumerator);
//! defer client.unregister(enumerator);   // releases our reference too
//! ```
//!
//! ## What a callback is allowed to do, which is almost nothing
//!
//! These methods are called by MMDevAPI on *its* worker thread, and the rules are
//! strict enough to be worth stating as rules:
//!
//!   * **Never call back into `IMMDeviceEnumerator`.** It is documented as a deadlock:
//!     the enumerator holds a lock while it notifies, and asking it anything from inside
//!     the notification waits for a lock the calling thread already owns.
//!   * **Never allocate.** Not because it is forbidden, but because a notification can
//!     arrive while the render thread is mid-cycle and an allocator lock shared with it
//!     would turn a device change into a dropped buffer.
//!   * **Never block.** A slow handler delays every other client's notifications.
//!
//! So each handler does exactly two things: set a bit, and signal an event. Everything
//! that needs doing happens later -- on the render thread, which reopens, or on the
//! caller's thread, which re-enumerates. The bit is the whole message.
//!
//! ## Why this is heap-allocated rather than embedded in the owner
//!
//! COM reference counting means the object is freed by its last `Release`, and there is
//! no documented guarantee about when MMDevAPI drops its reference relative to
//! `UnregisterEndpointNotificationCallback` returning. Embedding this in a `Stream` and
//! letting the stream's storage die would be correct only if that guarantee existed.
//!
//! So: one small allocation per client, `Release` frees at zero, and two belts on top --
//! `alive`, cleared before unregistering and checked at the top of every handler, and
//! `in_flight`, which the owner drains before dropping its own reference. The drain
//! exists precisely because the synchronisation is undocumented; if it were documented,
//! this would be four fewer fields.

const std = @import("std");

const Allocator = std.mem.Allocator;

const errors = @import("../errors.zig");
const com = @import("com.zig");
const check = com.check;
const enumerator_mod = @import("enumerator.zig");
const Flow = enumerator_mod.Flow;

const log = std.log.scoped(.wasapi);

const win32 = @import("win32").everything;
const Guid = win32.Guid;
const HRESULT = win32.HRESULT;

/// What happened, as a set of bits.
///
/// A bit set rather than a queue of events, because that is all a notification thread can
/// safely produce and all either consumer needs: the render thread wants to know *that*
/// the default changed, not the sequence of changes, and a listing wants to know *that*
/// something moved so it can look again.
pub const Flags = packed struct(u32) {
    /// The default render endpoint changed. What `Stream.Options.follow_default` acts on.
    default_render_changed: bool = false,
    /// The default capture endpoint changed.
    default_capture_changed: bool = false,
    /// An endpoint appeared.
    device_added: bool = false,
    /// An endpoint went away.
    device_removed: bool = false,
    /// An endpoint was enabled, disabled, plugged in or unplugged.
    device_state_changed: bool = false,
    /// A property changed -- usually a rename, occasionally a format change.
    property_changed: bool = false,
    _unused: u26 = 0,

    pub fn any(self: Flags) bool {
        return @as(u32, @bitCast(self)) != 0;
    }
};

/// Somewhere for a notification to land.
///
/// Both members are optional so that the two consumers can each take what they need: a
/// `Stream` wants the event, to break its render thread out of its wait; a listing wants
/// only the bits.
pub const Sink = struct {
    /// Bits are OR-ed into this. Read and cleared with an atomic exchange.
    flags: ?*std.atomic.Value(u32) = null,
    /// Signalled after the bits are set, so a thread waiting on it looks again. The one
    /// Win32 call a notification handler is allowed to make.
    event: ?com.Event = null,

    fn deliver(self: Sink, bits: Flags) void {
        if (self.flags) |cell| _ = cell.fetchOr(@bitCast(bits), .release);
        if (self.event) |event| event.set();
    }
};

/// An `IMMNotificationClient` implemented in Zig.
pub const NotificationClient = struct {
    /// The pointer MMDevAPI holds, and the first field so that `@fieldParentPtr` from it
    /// is a no-op -- which is worth having when it is reached from a callback on a thread
    /// this library does not own.
    interface: win32.IMMNotificationClient,
    /// COM's count, not ours: MMDevAPI adds a reference when registering.
    refs: std.atomic.Value(u32),
    /// Cleared before unregistering, so a callback already in flight does nothing.
    alive: std.atomic.Value(bool),
    /// Callbacks currently executing, drained by `unregister`.
    in_flight: std.atomic.Value(u32),
    sink: Sink,
    gpa: Allocator,

    const vtable: win32.IMMNotificationClient.VTable = .{
        .base = .{
            .QueryInterface = queryInterface,
            .AddRef = addRef,
            .Release = release,
        },
        .OnDeviceStateChanged = onDeviceStateChanged,
        .OnDeviceAdded = onDeviceAdded,
        .OnDeviceRemoved = onDeviceRemoved,
        .OnDefaultDeviceChanged = onDefaultDeviceChanged,
        .OnPropertyValueChanged = onPropertyValueChanged,
    };

    /// `IID_IUnknown`, which `zigwin32` does not name.
    const iid_iunknown = Guid.initString("00000000-0000-0000-c000-000000000046");

    pub fn create(gpa: Allocator, sink: Sink) Allocator.Error!*NotificationClient {
        const self = try gpa.create(NotificationClient);
        self.* = .{
            // An `IMMNotificationClient` is one pointer wide -- a union of the vtable
            // pointer and the `IUnknown` view of it -- so this is the whole object as
            // far as COM is concerned.
            .interface = .{ .vtable = &vtable },
            .refs = .init(1),
            .alive = .init(true),
            .in_flight = .init(0),
            .sink = sink,
            .gpa = gpa,
        };
        return self;
    }

    /// Start receiving notifications.
    pub fn register(self: *NotificationClient, enumerator: com.Enumerator) errors.Error!void {
        try check(
            "IMMDeviceEnumerator::RegisterEndpointNotificationCallback",
            enumerator.ptr.RegisterEndpointNotificationCallback(&self.interface),
        );
    }

    /// Stop receiving notifications, wait for any in flight to finish, and drop our
    /// reference.
    ///
    /// The object may outlive this call if MMDevAPI still holds a reference; it frees
    /// itself when the last one goes. Either way the sink is never touched again, because
    /// `alive` is cleared first.
    pub fn unregister(self: *NotificationClient, enumerator: com.Enumerator) void {
        // Before unregistering, so that a callback which has already started but not yet
        // read this does nothing.
        self.alive.store(false, .release);

        const hr = enumerator.ptr.UnregisterEndpointNotificationCallback(&self.interface);
        if (com.failed(hr)) {
            log.warn("UnregisterEndpointNotificationCallback failed: {f}", .{hr});
        }

        // Drain. Bounded, because a handler here does two atomic operations and cannot
        // block -- so this either returns immediately or after a handler finishes the
        // few instructions it was in the middle of.
        var spins: u32 = 0;
        while (self.in_flight.load(.acquire) != 0 and spins < 100_000) : (spins += 1) {
            std.atomic.spinLoopHint();
        }
        if (self.in_flight.load(.acquire) != 0) {
            // Should not happen, and leaking one small allocation is a far better
            // outcome than freeing memory a foreign thread is still reading.
            log.warn("a device notification is still running; leaking the client", .{});
            return;
        }

        _ = self.interface.IUnknown.Release();
    }

    /// Recover the object from the interface pointer COM hands back.
    fn from(iface: *const win32.IMMNotificationClient) *NotificationClient {
        // `@constCast` because every method in these bindings takes `self: *const T`,
        // while the object behind it is ours and mutable.
        return @constCast(@fieldParentPtr("interface", iface));
    }

    /// Guard every handler: returns null when the owner has finished with us.
    fn enter(iface: *const win32.IMMNotificationClient) ?*NotificationClient {
        const self = from(iface);
        if (!self.alive.load(.acquire)) return null;
        _ = self.in_flight.fetchAdd(1, .acquire);
        // Checked again after claiming, so a client that was retired between the two does
        // not deliver.
        if (!self.alive.load(.acquire)) {
            _ = self.in_flight.fetchSub(1, .release);
            return null;
        }
        return self;
    }

    fn leave(self: *NotificationClient) void {
        _ = self.in_flight.fetchSub(1, .release);
    }

    /// Recover the object from the `IUnknown` view of it.
    ///
    /// The three `IUnknown` slots are typed against `IUnknown` rather than against the
    /// derived interface, so they arrive with a differently-typed pointer to the same
    /// address -- `IMMNotificationClient` being a union of pointer-sized views of one
    /// vtable pointer, exactly so that this cast is free.
    fn fromUnknown(iface: *const win32.IUnknown) *NotificationClient {
        const derived: *const win32.IMMNotificationClient = @ptrCast(iface);
        return from(derived);
    }

    fn queryInterface(
        iface: *const win32.IUnknown,
        riid: *const Guid,
        ppv: **anyopaque,
    ) callconv(.winapi) HRESULT {
        const self = fromUnknown(iface);

        if (com.guidEql(riid, win32.IID_IMMNotificationClient) or
            com.guidEql(riid, &iid_iunknown))
        {
            _ = self.refs.fetchAdd(1, .monotonic);
            ppv.* = @ptrCast(&self.interface);
            return com.hresult.s_ok;
        }

        nullOut(ppv);
        return win32.E_NOINTERFACE;
    }

    /// Write null through the out-parameter.
    ///
    /// COM requires `*ppvObject == NULL` when `QueryInterface` fails, and `zigwin32`
    /// types the parameter as a non-optional `**anyopaque`, which cannot express that.
    /// A caller that checks the pointer instead of the `HRESULT` -- and they exist --
    /// would otherwise read whatever was there.
    fn nullOut(ppv: **anyopaque) void {
        @as(*?*anyopaque, @ptrCast(ppv)).* = null;
    }

    fn addRef(iface: *const win32.IUnknown) callconv(.winapi) u32 {
        return fromUnknown(iface).refs.fetchAdd(1, .monotonic) + 1;
    }

    fn release(iface: *const win32.IUnknown) callconv(.winapi) u32 {
        const self = fromUnknown(iface);
        const previous = self.refs.fetchSub(1, .release);
        if (previous == 1) {
            // Acquire, so that everything every other holder did before its own release
            // is visible before the memory is reused.
            _ = self.refs.load(.acquire);
            const gpa = self.gpa;
            self.* = undefined;
            gpa.destroy(self);
        }
        return previous - 1;
    }

    fn onDefaultDeviceChanged(
        iface: *const win32.IMMNotificationClient,
        flow: win32.EDataFlow,
        role: win32.ERole,
        id: ?[*:0]const u16,
    ) callconv(.winapi) HRESULT {
        _ = role;
        _ = id;
        const self = enter(iface) orelse return com.hresult.s_ok;
        defer self.leave();

        self.sink.deliver(switch (flow) {
            .eRender => .{ .default_render_changed = true },
            .eCapture => .{ .default_capture_changed = true },
            else => .{},
        });
        return com.hresult.s_ok;
    }

    fn onDeviceAdded(
        iface: *const win32.IMMNotificationClient,
        id: ?[*:0]const u16,
    ) callconv(.winapi) HRESULT {
        _ = id;
        const self = enter(iface) orelse return com.hresult.s_ok;
        defer self.leave();
        self.sink.deliver(.{ .device_added = true });
        return com.hresult.s_ok;
    }

    fn onDeviceRemoved(
        iface: *const win32.IMMNotificationClient,
        id: ?[*:0]const u16,
    ) callconv(.winapi) HRESULT {
        _ = id;
        const self = enter(iface) orelse return com.hresult.s_ok;
        defer self.leave();
        self.sink.deliver(.{ .device_removed = true });
        return com.hresult.s_ok;
    }

    fn onDeviceStateChanged(
        iface: *const win32.IMMNotificationClient,
        id: ?[*:0]const u16,
        new_state: u32,
    ) callconv(.winapi) HRESULT {
        _ = id;
        _ = new_state;
        const self = enter(iface) orelse return com.hresult.s_ok;
        defer self.leave();
        self.sink.deliver(.{ .device_state_changed = true });
        return com.hresult.s_ok;
    }

    fn onPropertyValueChanged(
        iface: *const win32.IMMNotificationClient,
        id: ?[*:0]const u16,
        key: win32.PROPERTYKEY,
    ) callconv(.winapi) HRESULT {
        _ = id;
        _ = key;
        const self = enter(iface) orelse return com.hresult.s_ok;
        defer self.leave();
        self.sink.deliver(.{ .property_changed = true });
        return com.hresult.s_ok;
    }
};

test "the flag set fits in a word and starts empty" {
    // It is OR-ed into an atomic `u32` from a notification thread, so its width is
    // load-bearing rather than incidental.
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Flags));
    try std.testing.expect(!(Flags{}).any());
    try std.testing.expect((Flags{ .default_render_changed = true }).any());
    try std.testing.expectEqual(
        @as(u32, 1),
        @as(u32, @bitCast(Flags{ .default_render_changed = true })),
    );
}

test "a client can be created, registered, and unregistered" {
    // Exercises the whole lifetime against the real MMDevAPI, which is the only thing
    // that can say whether the vtable layout is right: a wrong one would be a crash
    // inside `RegisterEndpointNotificationCallback` rather than a compile error.
    var apartment: com.Apartment = try .enter(com.coinit_multithreaded);
    defer apartment.leave();

    var enumerator: com.Enumerator = try .create();
    defer enumerator.deinit();

    var flags: std.atomic.Value(u32) = .init(0);
    const client = try NotificationClient.create(std.testing.allocator, .{ .flags = &flags });

    try client.register(enumerator);
    client.unregister(enumerator);

    // Nothing was plugged in during the test, so nothing should have been reported --
    // which also says the handlers were not called spuriously.
    try std.testing.expectEqual(@as(u32, 0), flags.load(.acquire));
}

test "QueryInterface answers for the interfaces it implements and refuses the rest" {
    // The COM contract, asserted directly: the two identities it must claim, a null
    // out-parameter on refusal, and a reference taken on success.
    var flags: std.atomic.Value(u32) = .init(0);
    const client = try NotificationClient.create(std.testing.allocator, .{ .flags = &flags });
    defer _ = client.interface.IUnknown.Release();

    var out: ?*anyopaque = null;
    try std.testing.expect(com.succeeded(client.interface.IUnknown.QueryInterface(
        win32.IID_IMMNotificationClient,
        @ptrCast(&out),
    )));
    try std.testing.expect(out != null);
    // That query took a reference, so give it back.
    _ = client.interface.IUnknown.Release();

    // And something it is not.
    out = @ptrFromInt(0xDEAD);
    const unrelated = Guid.initString("11111111-2222-3333-4444-555555555555");
    try std.testing.expect(com.failed(client.interface.IUnknown.QueryInterface(
        &unrelated,
        @ptrCast(&out),
    )));
    // Cleared on failure, which is what the contract requires and what the binding's
    // non-optional parameter type cannot say.
    try std.testing.expectEqual(@as(?*anyopaque, null), out);
}

test "a retired client delivers nothing" {
    // The guard that makes the lifetime safe: once `alive` is false, a callback that was
    // already on its way does nothing rather than touching a sink whose owner has gone.
    var flags: std.atomic.Value(u32) = .init(0);
    const client = try NotificationClient.create(std.testing.allocator, .{ .flags = &flags });
    defer _ = client.interface.IUnknown.Release();

    // Alive: the notification lands.
    _ = NotificationClient.onDeviceAdded(&client.interface, null);
    try std.testing.expect((@as(Flags, @bitCast(flags.load(.acquire)))).device_added);

    flags.store(0, .release);
    client.alive.store(false, .release);

    // Retired: it does not.
    _ = NotificationClient.onDeviceAdded(&client.interface, null);
    _ = NotificationClient.onDefaultDeviceChanged(&client.interface, .eRender, .eConsole, null);
    try std.testing.expectEqual(@as(u32, 0), flags.load(.acquire));

    // And nothing was left claimed, so an `unregister` would not spin.
    try std.testing.expectEqual(@as(u32, 0), client.in_flight.load(.acquire));
}

test "a default change is reported per direction" {
    // The render thread only cares about one of the two, and conflating them would make
    // a microphone change restart a playback stream.
    var flags: std.atomic.Value(u32) = .init(0);
    const client = try NotificationClient.create(std.testing.allocator, .{ .flags = &flags });
    defer _ = client.interface.IUnknown.Release();

    _ = NotificationClient.onDefaultDeviceChanged(&client.interface, .eCapture, .eConsole, null);
    var seen: Flags = @bitCast(flags.load(.acquire));
    try std.testing.expect(seen.default_capture_changed);
    try std.testing.expect(!seen.default_render_changed);

    _ = NotificationClient.onDefaultDeviceChanged(&client.interface, .eRender, .eConsole, null);
    seen = @bitCast(flags.load(.acquire));
    try std.testing.expect(seen.default_render_changed);
}

test "reference counting frees exactly once" {
    // A leak or a double free here is a use-after-free in somebody else's process, so
    // the counting is worth asserting rather than assuming.
    var flags: std.atomic.Value(u32) = .init(0);
    const client = try NotificationClient.create(std.testing.allocator, .{ .flags = &flags });

    try std.testing.expectEqual(@as(u32, 1), client.refs.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), client.interface.IUnknown.AddRef());
    try std.testing.expectEqual(@as(u32, 1), client.interface.IUnknown.Release());
    // The last release frees it, which the testing allocator checks for us.
    try std.testing.expectEqual(@as(u32, 0), client.interface.IUnknown.Release());
}

test {
    std.testing.refAllDecls(@This());
}
