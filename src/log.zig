// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Optional diagnostics, for a caller who wants this library's warnings in
//! their own log rather than in `std.log`.
//!
//! ```zig
//! const stream = try wasapi.Stream.open(gpa, io, .{
//!     .log = .{ .ctx = &my_logger, .func = &myLogFunc },
//! });
//! ```
//!
//! ## Which thread calls this
//!
//! Whichever one hit the event. In particular the render thread does, which is
//! a real-time thread: a `Log` that allocates, takes a contended lock, or
//! writes to a file will cause a dropped buffer rather than a late log line.
//! The library's own render loop logs only on the paths that are already
//! failing -- a device going away, a reopen -- and never per cycle, so in
//! practice this is a warning about what a caller's implementation may do
//! rather than about how often it is called.

const std = @import("std");

/// A diagnostic sink.
///
/// Deliberately a context pointer and a function pointer rather than an
/// interface with a vtable: there is one method, and this way a caller can
/// point it at an existing logger without declaring a type.
pub const Log = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, level: Level, message: []const u8) void,

    /// How bad it is, in the four levels `std.log` also has -- so that a caller
    /// forwarding to `std.log` needs no mapping table.
    pub const Level = enum {
        /// Something failed and the library could not carry on.
        err,
        /// Something failed and the library worked around it: a device went
        /// away and was reopened, MMCSS declined to raise the render thread, a
        /// format was not accepted and the next tier was tried.
        warn,
        /// A thing worth knowing happened once: a stream opened, at this rate,
        /// on this endpoint.
        info,
        /// Per-call detail, off in any release build of a caller.
        debug,
    };

    /// Emit `message`. Borrowed for the duration of the call and not valid
    /// afterwards, so an implementation that keeps it must copy it.
    pub fn emit(self: Log, level: Level, message: []const u8) void {
        self.func(self.ctx, level, message);
    }
};

test "a Log can be pointed at a counter without declaring a type" {
    // The shape a caller is expected to use, asserted so that changing the
    // signature breaks here rather than in someone else's code.
    var seen: usize = 0;
    const sink: Log = .{
        .ctx = &seen,
        .func = &struct {
            fn f(ctx: *anyopaque, level: Log.Level, message: []const u8) void {
                _ = level;
                _ = message;
                const count: *usize = @ptrCast(@alignCast(ctx));
                count.* += 1;
            }
        }.f,
    };

    sink.emit(.warn, "something to say");
    sink.emit(.info, "something else");
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test {
    std.testing.refAllDecls(@This());
}
