// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The root of `zig build check`, whose only job is to make the compiler look at
//! everything.
//!
//! Compiling `src/wasapi.zig` straight to an object does far less than it appears to.
//! Zig analyses declarations lazily and a library exports no symbols, so almost nothing
//! is reachable and almost nothing is checked: an entire file could contain a type error
//! and the object would still build.
//!
//! That matters more here than in most libraries, because `check` is the *only* thing
//! that compiles the COM half on a machine that is not Windows. A Linux
//! continuous-integration runner cannot run any of it; what it can do is type-check every
//! vtable signature, every GUID namespace and every `@ptrCast` shape against the real
//! bindings, cross-compiled for two Windows architectures. An object that silently
//! checked nothing would make that guarantee worthless.
//!
//! `std.testing.refAllDecls` is no help: its first line is `if (!builtin.is_test)
//! return;`, so outside a test build it does nothing at all.
//!
//! So this does both halves by hand. Taking the address of a declaration forces a
//! function's body to be analysed, and asking for a type's size forces its fields to be
//! resolved -- which is the half that catches a field whose type is legal on one target
//! and not on another.

const std = @import("std");
const wasapi = @import("wasapi");

comptime {
    force(wasapi);
}

/// Reference every declaration of `T`, and recurse one level into the container types
/// among them.
///
/// One level rather than all the way down: everything this library exposes is reachable
/// from the root or from one of the types it names, and an unbounded walk wanders into
/// `std` by way of a re-export and takes a long time to come back.
fn force(comptime T: type) void {
    @setEvalBranchQuota(200_000);
    inline for (comptime std.meta.declarations(T)) |decl| {
        _ = &@field(T, decl.name);
        if (@TypeOf(@field(T, decl.name)) == type) {
            forceType(@field(T, decl.name));
        }
    }
}

fn forceType(comptime T: type) void {
    @setEvalBranchQuota(200_000);
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => {
            // Resolving the size resolves every field, which is what an object build
            // otherwise never does.
            _ = @sizeOf(T);
            inline for (comptime std.meta.declarations(T)) |decl| {
                _ = &@field(T, decl.name);
            }
        },
        else => {},
    }
}
