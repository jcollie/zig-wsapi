// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Says which systems this library is for, and says so legibly when it is
//! built for another one.
//!
//! This is the only file that names an operating system. It is a file of its
//! own rather than a `comptime` block in the root so that someone who adds the
//! module to a build without copying this repository's `build.zig` -- and so
//! without the `win32` import wired up -- reads this explanation instead of a
//! missing-package error about a dependency they never asked for.

const std = @import("std");
const builtin = @import("builtin");

/// The systems this library has a backend for.
///
/// WASAPI arrived in Windows Vista and almost everything this library uses has
/// been there since. The parts that need something newer degrade at runtime
/// rather than at compile time, and `IAudioClient3` -- Windows 10 1703, for the
/// low-latency shared-mode path -- is the only such part.
pub const supported = [_]std.Target.Os.Tag{.windows};

comptime {
    if (builtin.os.tag != .windows) @compileError(unsupported);
}

const unsupported =
    "zig-windows-audio speaks WASAPI, which only Windows has, and this is a build for " ++
    @tagName(builtin.os.tag) ++ ".\n\n" ++
    "There is no portable audio API behind this one to fall back on: this module is " ++
    "the Windows half of a pair, and the Linux half is zig-pipewire " ++
    "(https://git.jcollie.dev/jeff/zig-pipewire). A program that wants both should " ++
    "select between them itself, on `builtin.os.tag`, and import only the one it is " ++
    "building for -- which also keeps the other's dependencies out of the build graph.\n\n" ++
    "The operating-system-independent parts -- the ring buffer, the channel maps, the " ++
    "format encoder, the sample converters -- are importable anywhere through " ++
    "`src/portable.zig`, which is what this repository's own tests use on a " ++
    "non-Windows host.";

test "the supported list and the compile error agree" {
    // If a system is ever added to `supported`, the `comptime` guard above has
    // to learn about it too, and this is what notices that it did not.
    var found = false;
    for (supported) |tag| {
        if (tag == builtin.os.tag) found = true;
    }
    try std.testing.expect(found);
}

test {
    std.testing.refAllDecls(@This());
}
