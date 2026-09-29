// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Play audio on Windows, and manage what is playing, in Zig.
//!
//! Work in progress: the endpoint enumeration below works, and playback is
//! being built on top of it.

const std = @import("std");

comptime {
    // Referencing this is load-bearing: a container-scope `comptime` block in
    // another file is analysed only when something names the file, so without
    // this an unsupported target's first error would be whichever COM
    // declaration happened to be analysed first.
    _ = @import("support.zig");
}

/// The operating-system-independent half of the library, importable on any
/// host. Named here so that `refAllDecls` reaches it and its tests run.
pub const portable = @import("portable.zig");

pub const errors = @import("errors.zig");
pub const Error = errors.Error;
pub const AnyError = errors.AnyError;

/// Optional diagnostics. See `log.Log`.
pub const Log = @import("log.zig").Log;

/// A playback stream: the whole of the playback API.
pub const Stream = @import("Stream.zig");
pub const State = Stream.State;
pub const Options = Stream.Options;
pub const Process = Stream.Process;
pub const Role = Stream.Role;

/// The control plane: endpoints, their volumes, and what each program is playing.
pub const Session = @import("Session.zig");
pub const Endpoint = com.Endpoint;
pub const Flow = com.Flow;
pub const EndpointRole = com.Role;
pub const Volume = Session.Volume;
pub const AppSession = Session.AppSession;

/// Recording: from a microphone, or from what the machine is playing.
pub const Capture = @import("Capture.zig");
pub const Source = Capture.Source;

/// Speaker positions and channel-map ordering. See `channel`.
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

/// The COM seam: apartment handling, `HRESULT` mapping, and the endpoint
/// enumeration every other part of the library opens devices through.
///
/// Exported because a caller who needs to reach past `Stream` -- to activate an
/// interface this library does not wrap -- otherwise cannot, and because the
/// alternative is that they write their own `CoInitializeEx` and get the
/// apartment rules wrong.
pub const com = @import("com/com.zig");

test {
    std.testing.refAllDecls(@This());
}
