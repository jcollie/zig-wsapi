// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! COM, reduced to what this library needs from it: apartments, object
//! creation, reference counting, and getting a string out of a property store.
//!
//! ```zig
//! var apartment: com.Apartment = try .enter(com.coinit_multithreaded);
//! defer apartment.leave();
//!
//! const enumerator = try com.create(
//!     audio.IMMDeviceEnumerator,
//!     audio.CLSID_MMDeviceEnumerator,
//!     audio.IID_IMMDeviceEnumerator,
//! );
//! defer com.release(enumerator);
//! ```
//!
//! ## Apartments, which are the thing to get right
//!
//! Every thread that touches COM has to be in an apartment, and a library does
//! not get to choose the caller's. `Apartment.enter` therefore treats three
//! different answers from `CoInitializeEx` as success and remembers which one
//! it got, because what `leave` must do differs in each case -- see
//! `Apartment.State`. Getting this wrong is the most likely way for this
//! library to fail inside somebody else's application, and it fails in the
//! worst way: not at the call that was wrong, but later, somewhere else.
//!
//! The library's own threads sidestep all of it. A `Stream`'s COM objects are
//! created, used and released entirely on its render thread, which is a thread
//! this library made and put in the multithreaded apartment itself, so no
//! interface pointer ever crosses a thread boundary and no marshalling is ever
//! needed. Only `Session`, which is synchronous on the caller's thread by
//! nature, has to cope with an apartment it did not choose.

const std = @import("std");

const errors = @import("../errors.zig");

pub const hresult = @import("hresult.zig");
pub const check = hresult.check;
pub const classifyOnly = hresult.classifyOnly;
pub const eql = hresult.eql;
pub const failed = hresult.failed;
pub const succeeded = hresult.succeeded;

pub const missing = @import("missing.zig");
pub const sys = @import("sys.zig");
pub const Event = sys.Event;
pub const Clock = sys.Clock;
pub const ProAudio = sys.ProAudio;

pub const enumerator = @import("enumerator.zig");
pub const activate = @import("activate.zig");
pub const notify = @import("notify.zig");
pub const NotificationClient = notify.NotificationClient;
pub const NotificationFlags = notify.Flags;
pub const Enumerator = enumerator.Enumerator;
pub const Endpoint = enumerator.Endpoint;
pub const Flow = enumerator.Flow;
pub const Role = enumerator.Role;
/// Named `EndpointState` rather than `State` because `Apartment.State` is also
/// here and a bare `State` in this namespace would be ambiguous -- which the
/// compiler says outright, and which a reader would have to guess about.
pub const EndpointState = enumerator.State;

const log = std.log.scoped(.wasapi);

const win32 = @import("win32").everything;
const Guid = win32.Guid;
const HRESULT = win32.HRESULT;

/// `COINIT_MULTITHREADED`.
///
/// Spelled as a named constant because it is the all-zeroes value of a packed
/// struct whose only named low bit is `APARTMENTTHREADED`, so the obvious
/// "explicit" spelling is a bug: `.{ .APARTMENTTHREADED = 1 }` asks for a
/// single-threaded apartment, quietly, and everything still appears to work
/// until a notification arrives on the wrong thread.
pub const coinit_multithreaded: win32.COINIT = .{};

/// `COINIT_APARTMENTTHREADED`, for completeness and for the test below. This
/// library never asks for an STA.
pub const coinit_apartmentthreaded: win32.COINIT = .{ .APARTMENTTHREADED = 1 };

/// `CLSCTX_ALL`. Every audio object this library creates is in-process, so this
/// is broader than strictly needed, but it is what the Core Audio samples pass
/// and there is no benefit in differing from them.
pub const clsctx_all: win32.CLSCTX = .{
    .INPROC_SERVER = 1,
    .INPROC_HANDLER = 1,
    .LOCAL_SERVER = 1,
    .REMOTE_SERVER = 1,
};

/// `STGM_READ`, which -- like `coinit_multithreaded` -- is the all-zeroes value
/// of a flags struct and so deserves a name rather than a `.{}` at the call
/// site that a reader would have to look up.
pub const stgm_read: win32.STGM = .{};

/// The apartment this library put a thread into, and what leaving it requires.
///
/// A `CoInitializeEx`/`CoUninitialize` pair has to balance per *call*, not per
/// thread, and the third case below must not be balanced at all -- so the
/// outcome has to be remembered rather than recomputed.
pub const Apartment = struct {
    state: State,

    pub const State = enum {
        /// `S_OK`: this call initialised the apartment. `CoUninitialize` on the
        /// way out.
        initialised,

        /// `S_FALSE`: the thread was already in the apartment we asked for.
        /// `CoUninitialize` on the way out anyway -- the reference count is per
        /// call, and skipping it here leaks an apartment reference that keeps
        /// COM loaded for the life of the process.
        already,

        /// `RPC_E_CHANGED_MODE`: the thread is in a *different* apartment,
        /// which for a library means the host application got there first --
        /// any GUI application's main thread is in a single-threaded apartment.
        ///
        /// This is a success, not a failure. Every object this library creates
        /// is in-process and usable from an STA; what is not allowed is
        /// `CoUninitialize`, because this call added no reference and undoing
        /// somebody else's initialisation would break them.
        ///
        /// This is the *common* case for `Session.open` in a GUI application,
        /// so it is emphatically not an edge case to be rejected.
        borrowed,
    };

    /// Put the current thread in an apartment, or note that it is already in
    /// one.
    pub fn enter(which: win32.COINIT) errors.Error!Apartment {
        const hr = win32.CoInitializeEx(null, which);
        if (eql(hr, hresult.s_ok)) return .{ .state = .initialised };
        if (eql(hr, hresult.s_false)) return .{ .state = .already };
        if (eql(hr, win32.RPC_E_CHANGED_MODE)) return .{ .state = .borrowed };
        try check("CoInitializeEx", hr);
        unreachable; // `check` returns an error for every `hr` not handled above.
    }

    /// Undo `enter`, if there is anything to undo.
    pub fn leave(self: *Apartment) void {
        switch (self.state) {
            .initialised, .already => win32.CoUninitialize(),
            .borrowed => {},
        }
        self.* = undefined;
    }
};

/// `CoCreateInstance`, typed.
///
/// Wraps the `**anyopaque` out-parameter, which is the shape every COM creation
/// and activation function has in these bindings and which is easy to get
/// subtly wrong -- `@ptrCast(&ptr)` where `ptr` is already a pointer is not the
/// same as `&ptr`, and the compiler accepts both.
pub fn create(comptime T: type, clsid: *const Guid, iid: *const Guid) errors.Error!*T {
    var ptr: ?*T = null;
    try check("CoCreateInstance", win32.CoCreateInstance(
        clsid,
        null,
        clsctx_all,
        iid,
        @ptrCast(&ptr),
    ));
    return ptr orelse {
        // A COM object that reports success and hands back null is broken, but
        // the type system cannot rule it out and a null dereference in a render
        // loop is a poor way to find out.
        log.warn("CoCreateInstance succeeded but returned null", .{});
        return error.Unexpected;
    };
}

/// `QueryInterface`, typed, for casting an interface this library holds to
/// another it implements.
pub fn queryInterface(comptime T: type, obj: anytype, iid: *const Guid) errors.Error!*T {
    var ptr: ?*T = null;
    const hr = obj.IUnknown.QueryInterface(iid, @ptrCast(&ptr));
    if (failed(hr)) return classifyOnly(hr);
    return ptr orelse error.Unexpected;
}

/// `Release`, for any of these bindings' interfaces.
///
/// Takes a nullable so that a teardown path can release whatever it managed to
/// acquire without a null check per interface, which is the shape the reopen
/// path in `Stream` wants.
pub fn release(obj: anytype) void {
    switch (@typeInfo(@TypeOf(obj))) {
        .optional => if (obj) |o| {
            _ = o.IUnknown.Release();
        },
        else => _ = obj.IUnknown.Release(),
    }
}

/// Whether two GUIDs are the same.
///
/// These bindings' `Guid` is an `extern union` of an integer layout and sixteen
/// bytes, with no equality function of its own, so this compares the bytes --
/// which is well defined for a union where both members are the same sixteen
/// bytes read two ways.
pub fn guidEql(a: *const Guid, b: *const Guid) bool {
    return std.mem.eql(u8, &a.Bytes, &b.Bytes);
}

/// A string COM allocated and this library must free.
///
/// A type rather than a bare pointer so that `defer s.deinit()` is available
/// and so that the `CoTaskMemFree` cannot be forgotten -- every endpoint id and
/// every device format comes back this way, and the leak is silent.
pub const TaskMem = struct {
    ptr: ?*anyopaque,

    pub fn deinit(self: *TaskMem) void {
        if (self.ptr) |p| win32.CoTaskMemFree(p);
        self.* = undefined;
    }
};

/// Copy a null-terminated UTF-16 string into `out` as UTF-8.
///
/// Returns the prefix of `out` that was written. `error.NameTooLong` rather than
/// a truncation: an endpoint id that does not fit is one this library cannot
/// later hand back to `IMMDeviceEnumerator.GetDevice`, and half an id is worse
/// than an error because it would silently name a different device -- or none,
/// which the caller would then report as the device having gone away.
///
/// Encodes a code point at a time rather than calling
/// `std.unicode.utf16LeToUtf8`, which documents that it *asserts* the output
/// buffer is big enough and so crashes rather than failing when it is not. The
/// alternative would be to size `out` at three bytes per code unit and never be
/// wrong, which for a 256-character endpoint id means a 768-byte buffer on a
/// render thread's stack to hold a name that is almost always ASCII.
pub fn utf8FromWide(out: []u8, wide: [*:0]const u16) error{NameTooLong}![]const u8 {
    var written: usize = 0;
    var units: std.unicode.Utf16LeIterator = .init(wide[0..std.mem.len(wide)]);
    while (units.nextCodepoint() catch return error.NameTooLong) |codepoint| {
        const need = std.unicode.utf8CodepointSequenceLength(codepoint) catch
            return error.NameTooLong;
        if (written + need > out.len) return error.NameTooLong;
        written += std.unicode.utf8Encode(codepoint, out[written..]) catch
            return error.NameTooLong;
    }
    return out[0..written];
}

/// Read one string property out of a device's property store.
///
/// Null when the device has no value for that key, which is a real answer: not
/// every endpoint has a friendly name, and the caller should fall back to
/// another key rather than treat it as a failure.
///
/// ## Why this is the only place `PROPVARIANT` appears
///
/// These bindings represent it as three levels of anonymous union, so the tag
/// is at `pv.Anonymous.Anonymous.vt` and the string at
/// `pv.Anonymous.Anonymous.Anonymous.pwszVal`. Worse, it must be zeroed before
/// the call -- `GetValue` does not fully initialise it, and reading the union
/// of an uninitialised one is how the upstream zigwin32 WASAPI example crashes.
/// One helper, zeroing and clearing correctly, is cheaper than remembering that
/// at four call sites.
pub fn propString(
    store: *win32.IPropertyStore,
    key: *const win32.PROPERTYKEY,
    out: []u8,
) (errors.Error || error{NameTooLong})!?[]const u8 {
    var pv: win32.PROPVARIANT = std.mem.zeroes(win32.PROPVARIANT);
    try check("IPropertyStore::GetValue", store.GetValue(key, &pv));
    defer _ = win32.PropVariantClear(&pv);

    if (pv.Anonymous.Anonymous.vt != win32.VT_LPWSTR) return null;
    const wide = pv.Anonymous.Anonymous.Anonymous.pwszVal orelse return null;
    return try utf8FromWide(out, wide);
}

test "the multithreaded apartment is the all-zeroes COINIT" {
    // The bug this constant exists to prevent: `COINIT` names
    // `APARTMENTTHREADED` as a bit, so an "explicit" multithreaded literal is
    // an STA. If these two ever compare equal, something has renamed a field
    // and every thread in this library is in the wrong apartment.
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(coinit_multithreaded)));
    try std.testing.expect(
        @as(u32, @bitCast(coinit_multithreaded)) != @as(u32, @bitCast(coinit_apartmentthreaded)),
    );
}

test "a borrowed apartment is not uninitialised on the way out" {
    // The distinction that keeps this library from breaking a GUI host: three
    // states, and only two of them balance the call.
    var borrowed: Apartment = .{ .state = .borrowed };
    borrowed.leave(); // Must not call CoUninitialize; reaching here is the test.

    // And the two that do are distinguishable from it.
    try std.testing.expect(Apartment.State.initialised != Apartment.State.borrowed);
    try std.testing.expect(Apartment.State.already != Apartment.State.borrowed);
}

test "entering and leaving the multithreaded apartment works on a fresh thread" {
    // The test runner's thread may already be in an apartment, so this says
    // nothing about which state comes back -- only that every state `enter` can
    // return is one `leave` accepts.
    var apartment: Apartment = try .enter(coinit_multithreaded);
    apartment.leave();
}

test "guids compare by value" {
    const a = Guid.initString("00000003-0000-0010-8000-00aa00389b71");
    const b = Guid.initString("00000003-0000-0010-8000-00aa00389b71");
    const c = Guid.initString("00000001-0000-0010-8000-00aa00389b71");
    try std.testing.expect(guidEql(&a, &b));
    try std.testing.expect(!guidEql(&a, &c));
}

test "a wide string too long for the buffer is an error rather than a truncation" {
    // Half an endpoint id would name a different device, or no device, and
    // `GetDevice` would be asked for it in either case.
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("a rather long endpoint identifier");
    var small: [8]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, utf8FromWide(&small, wide));

    var big: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "a rather long endpoint identifier",
        try utf8FromWide(&big, wide),
    );
}

test {
    std.testing.refAllDecls(@This());
}
