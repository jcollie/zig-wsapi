// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The half of this library with no operating system in it.
//!
//! The ring buffer, the channel maps, the `WAVEFORMATEX` encoder, the sample
//! converters and the clock arithmetic are all pure functions over plain data,
//! and they are where most of the bugs in an audio library live: an off-by-one
//! in a ring's wraparound, a channel permutation that is self-consistent and
//! wrong, a `dwChannelMask` with the wrong bit set, a nanosecond conversion
//! that overflows after a day of uptime.
//!
//! None of that needs a sound card to test, and none of it needs Windows. This
//! file is the compile and test root for it, so that:
//!
//!   * `zig build test` on a Linux host runs a real suite rather than nothing;
//!   * `zig build check` compiles this for Linux, which turns "no file in here
//!     imports `win32`" from a convention into a compile error.
//!
//! Nothing here may `@import("win32")`, directly or transitively. That is the
//! whole point of the file.

const std = @import("std");

pub const errors = @import("errors.zig");
pub const Log = @import("log.zig").Log;
pub const channel = @import("channel.zig");
pub const Channel = channel.Channel;
pub const format = @import("format.zig");
pub const Format = format.Format;
pub const Sample = format.Sample;
pub const Ring = @import("Ring.zig");
pub const mix = @import("mix.zig");
pub const time = @import("time.zig");
pub const Time = time.Time;
pub const stats = @import("stats.zig");
pub const Stats = stats.Stats;
pub const Summary = stats.Summary;
pub const wait = @import("wait.zig");
pub const defaultChannelMap = channel.defaultChannelMap;
pub const max_channels = channel.max_channels;

test {
    std.testing.refAllDecls(@This());
}
