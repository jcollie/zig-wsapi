// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The one place an `HRESULT` becomes a Zig error.
//!
//! ```zig
//! try check("IAudioClient::Initialize", client.Initialize(...));
//! ```
//!
//! ## Success is the absence of a flag, not a zero
//!
//! This is the trap the whole file exists to avoid. `S_FALSE`,
//! `AUDCLNT_S_BUFFER_EMPTY` and `AUDCLNT_S_POSITION_STALLED` are *successes*
//! that carry information, and a helper written as `if (hr != 0) return error`
//! turns each of them into a failure the first time a driver returns one.
//!
//! These bindings make that harder to get wrong than the C headers do: their
//! `HRESULT` is a `packed struct(u32)` whose top bit is a `failed: bool`, so
//! `hr.failed` is the whole test and there is no sign-bit arithmetic to fumble.
//! The test at the bottom of this file pins it down anyway, because the cost of
//! being wrong is a library that fails only on unusual hardware.
//!
//! Codes that mean something specific to their caller are deliberately *not*
//! handled here: `check` is for "this must have worked", and a call site that
//! cares about `S_FALSE` -- `IsFormatSupported` does -- tests for it by name
//! before calling `check`.
//!
//! ## What the caller is told
//!
//! The kind of thing that went wrong, from `errors.Error`, and nothing else --
//! the code itself goes to the log on the way past. So the error says what
//! happened and the log says which number said so, and a caller's `switch` does
//! not have to know that `AUDCLNT_E_DEVICE_INVALIDATED` is `0x88890004`.
//!
//! ## Why the comparisons are on `u32`
//!
//! Zig has no `==` for a struct, packed or otherwise, and no `switch` over one.
//! Every `AUDCLNT_E_*` constant is an `HRESULT`, so each has to be bit-cast to
//! its `u32` to be compared or switched on. `int` does that in one place so the
//! `switch` below reads as a table rather than as a wall of `@bitCast`.

const std = @import("std");

const errors = @import("../errors.zig");

const log = std.log.scoped(.wasapi);

const win32 = @import("win32").everything;
const HRESULT = win32.HRESULT;

/// `S_OK`: success, with nothing further to say.
pub const s_ok: HRESULT = HRESULT.S_OK;

/// `S_FALSE`: also success.
///
/// Named because it is a common and *meaningful* answer -- `IsFormatSupported`
/// returns it to mean "no, but here is something close", and `CoInitializeEx`
/// to mean "this thread was already in that apartment" -- and a bare `1` at
/// those call sites would read as a mistake.
pub const s_false: HRESULT = .fromInt(1);

/// `E_NOTFOUND` as the Core Audio headers define it: `HRESULT_FROM_WIN32(
/// ERROR_NOT_FOUND)`, `0x80070490`. It is what `GetDefaultAudioEndpoint`
/// returns on a machine with no endpoint in that direction.
///
/// **Not** `win32.E_NOTFOUND`. The bindings have exactly one constant by that
/// name, and it is HTML Help's, `0x8000100D` -- a different code that no audio
/// interface returns. Matching on it made a machine with no sound card look
/// like an `Unexpected` failure rather than the ordinary answer it is.
pub const e_notfound: HRESULT = fromWin32(@intFromEnum(win32.ERROR_NOT_FOUND));

/// `HRESULT_FROM_WIN32`: a Win32 error code carried in an `HRESULT`, with the
/// failure bit set and `FACILITY_WIN32` (7) as the facility.
fn fromWin32(code: u32) HRESULT {
    return .fromInt(0x8007_0000 | (code & 0xFFFF));
}

/// An `HRESULT` as its underlying bit pattern, for comparison and `switch`.
pub fn int(hr: HRESULT) u32 {
    return @bitCast(hr);
}

/// Whether an `HRESULT` reports failure.
pub fn failed(hr: HRESULT) bool {
    return hr.failed;
}

/// Whether an `HRESULT` reports success, including the informational successes.
pub fn succeeded(hr: HRESULT) bool {
    return !hr.failed;
}

/// Whether two `HRESULT`s are the same code.
pub fn eql(a: HRESULT, b: HRESULT) bool {
    return int(a) == int(b);
}

/// Turn a failing `HRESULT` into an `errors.Error`, logging the code.
///
/// `what` names the call, in `Interface::Method` form, so that a log line
/// identifies the call site without a stack trace. `HRESULT` formats itself as
/// `0x88890004` under `{f}`, which is the spelling Microsoft's documentation
/// uses and therefore the one that can be searched for.
pub fn check(what: []const u8, hr: HRESULT) errors.Error!void {
    if (succeeded(hr)) return;
    const err = classify(hr);
    log.warn("{s} failed: {f} ({t})", .{ what, hr, err });
    return err;
}

/// The same mapping without the log line, for a call whose failure is expected
/// and handled.
///
/// Used on the paths that try something and fall back -- activating
/// `IAudioClient3` before `IAudioClient2` before `IAudioClient`, offering a
/// format before accepting the endpoint's own -- where a warning per attempt
/// would bury the one attempt that mattered.
pub fn classifyOnly(hr: HRESULT) errors.Error {
    std.debug.assert(failed(hr));
    return classify(hr);
}

fn classify(hr: HRESULT) errors.Error {
    return switch (int(hr)) {
        int(win32.AUDCLNT_E_DEVICE_INVALIDATED),
        int(win32.AUDCLNT_E_RESOURCES_INVALIDATED),
        => error.DeviceInvalidated,

        int(win32.AUDCLNT_E_DEVICE_IN_USE),
        int(win32.AUDCLNT_E_EXCLUSIVE_MODE_ONLY),
        => error.DeviceInUse,

        int(win32.AUDCLNT_E_SERVICE_NOT_RUNNING) => error.ServiceNotRunning,

        int(win32.AUDCLNT_E_UNSUPPORTED_FORMAT),
        int(win32.AUDCLNT_E_WRONG_ENDPOINT_TYPE),
        => error.UnsupportedFormat,

        int(win32.AUDCLNT_E_ENDPOINT_CREATE_FAILED),
        int(e_notfound),
        => error.DeviceNotFound,

        // How a system too old for an interface says so, which every fallback
        // path in this library depends on being distinguishable.
        int(win32.E_NOINTERFACE),
        int(win32.E_NOTIMPL),
        => error.Unsupported,

        int(win32.E_ACCESSDENIED) => error.AccessDenied,
        int(win32.E_OUTOFMEMORY) => error.SystemResources,

        // Each of these means this library called something in the wrong order
        // or with the wrong argument -- a bug here, not a condition out in the
        // world. They are still errors rather than assertions, because a driver
        // is entitled to disagree with the documentation and taking down the
        // caller's process over it would be worse.
        int(win32.E_POINTER),
        int(win32.E_INVALIDARG),
        int(win32.AUDCLNT_E_OUT_OF_ORDER),
        int(win32.AUDCLNT_E_BUFFER_OPERATION_PENDING),
        int(win32.AUDCLNT_E_INVALID_STREAM_FLAG),
        int(win32.AUDCLNT_E_EVENTHANDLE_NOT_EXPECTED),
        => error.Unexpected,

        else => error.Unexpected,
    };
}

test "informational successes are successes" {
    // The bug this file exists to prevent. Every one of these is a code a real
    // driver returns, and every one of them means the call worked.
    try std.testing.expect(succeeded(s_ok));
    try std.testing.expect(succeeded(s_false));
    try std.testing.expect(succeeded(win32.AUDCLNT_S_BUFFER_EMPTY));
    try std.testing.expect(succeeded(win32.AUDCLNT_S_POSITION_STALLED));

    try check("a call that worked", s_false);
    try check("a call with an empty buffer", win32.AUDCLNT_S_BUFFER_EMPTY);
}

test "S_OK is zero and S_FALSE is not" {
    try std.testing.expectEqual(@as(u32, 0), int(s_ok));
    try std.testing.expectEqual(@as(u32, 1), int(s_false));
    try std.testing.expect(!eql(s_ok, s_false));
}

test "the failures a running program has to cope with are distinguished" {
    // Each of these drives different behaviour: reopen on another endpoint,
    // back off and retry, or give up and tell the user there is no sound card.
    // Collapsing any pair would lose that.
    try std.testing.expectError(
        error.DeviceInvalidated,
        check("unplugged", win32.AUDCLNT_E_DEVICE_INVALIDATED),
    );
    try std.testing.expectError(
        error.DeviceInUse,
        check("taken exclusively", win32.AUDCLNT_E_DEVICE_IN_USE),
    );
    try std.testing.expectError(
        error.ServiceNotRunning,
        check("audio service stopped", win32.AUDCLNT_E_SERVICE_NOT_RUNNING),
    );
    try std.testing.expectError(
        error.UnsupportedFormat,
        check("a format the endpoint refused", win32.AUDCLNT_E_UNSUPPORTED_FORMAT),
    );
    try std.testing.expectError(
        error.Unsupported,
        check("too old a Windows", win32.E_NOINTERFACE),
    );
}

test "no endpoint is DeviceNotFound, by the code Windows actually returns" {
    // 0x80070490 is what `GetDefaultAudioEndpoint` said on a hosted Windows
    // runner with no sound card. Written out as a number rather than through
    // `e_notfound`, so that this checks the constant as well as the mapping.
    try std.testing.expectEqual(@as(u32, 0x8007_0490), int(e_notfound));
    try std.testing.expectError(
        error.DeviceNotFound,
        check("no sound card", HRESULT.fromInt(0x8007_0490)),
    );
}

test "the bindings' E_NOTFOUND is HTML Help's, not the one audio returns" {
    // Pins the trap `e_notfound` exists to avoid. If this ever fails, the
    // bindings have changed what the name means and the choice can be revisited.
    try std.testing.expect(!eql(win32.E_NOTFOUND, e_notfound));
}

test "an unrecognised code is Unexpected rather than a wrong guess" {
    try std.testing.expectError(
        error.Unexpected,
        check("something new", HRESULT.fromInt(0x8000_4005)),
    );
}

test "a code renders as findable hexadecimal" {
    // `0x88890004` can be searched for; `-2004287484` cannot. The rendering
    // comes from the bindings' own `HRESULT.format`, so this asserts that this
    // library gets to rely on it.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "0x88890004",
        try std.fmt.bufPrint(&buf, "{f}", .{win32.AUDCLNT_E_DEVICE_INVALIDATED}),
    );
}

test {
    std.testing.refAllDecls(@This());
}
