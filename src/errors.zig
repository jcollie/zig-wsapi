// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What can go wrong, named once for the whole library.
//!
//! These sets are explicit rather than inferred. An inferred set changes shape
//! when an implementation detail changes, which for a library means a caller's
//! `switch` can stop compiling because a COM call somewhere grew a failure
//! mode; it also means the published reference lists whatever set the machine
//! that built the documentation happened to produce. Naming them fixes both.
//!
//! ## What is not here
//!
//! An `HRESULT`. Every Windows error code is collapsed into one of the members
//! of `Error` below, and the code itself is written to the log at warning level
//! on the way through -- so the error says what happened and the log says which
//! number said so. A caller that needs to branch on a code rather than on a
//! kind is a caller this library has not anticipated, and the right answer then
//! is a new member here rather than a leaked `i32`.

const std = @import("std");

/// The failures any call that reaches the audio stack can produce.
///
/// Every one of these is something a running program has to cope with rather
/// than a programming mistake: a device is unplugged, another application holds
/// the endpoint exclusively, the audio service is restarted.
pub const Error = error{
    /// The process may not use this endpoint. Group-policy restrictions and,
    /// for a capture endpoint, the microphone privacy setting both land here --
    /// the latter is the common one, and it is a setting rather than a bug.
    AccessDenied,

    /// Nothing answers to that endpoint, or there is no endpoint at all in the
    /// direction asked for. A machine with no sound card, a machine whose only
    /// output is disabled, and an endpoint id from a previous run that has
    /// since gone away all arrive here.
    DeviceNotFound,

    /// The endpoint stopped existing while it was in use: unplugged, disabled,
    /// or its driver restarted. `Stream` handles this itself by reopening --
    /// see `Stream.Options.follow_default` -- so a caller normally sees this
    /// only from `Session` and from a stream that was told not to follow.
    DeviceInvalidated,

    /// Another application holds the endpoint in exclusive mode, so a shared
    /// mode client cannot have it. Nothing this library can do about it; the
    /// other application has to let go.
    DeviceInUse,

    /// The endpoint will not accept the format asked for, and the closest match
    /// it offered instead was not usable either. In shared mode this is rare
    /// enough to be worth investigating: the audio engine converts almost
    /// anything.
    UnsupportedFormat,

    /// The Windows Audio service is not running. It is set to start
    /// automatically, so this usually means it crashed or was stopped by hand,
    /// and it will not recover on its own.
    ServiceNotRunning,

    /// The system would not give up what the call needed -- memory, or one of
    /// the audio engine's own fixed resources. Distinct from
    /// `std.mem.Allocator.Error.OutOfMemory`, which is this library's own
    /// allocator failing rather than the kernel's.
    SystemResources,

    /// Windows does not offer this. Either the interface is too old a system's
    /// to have (`IAudioClient3` before Windows 10 1703), or there is no public
    /// API for what was asked at all -- see `Session.setDefaultSink`.
    Unsupported,

    /// An `HRESULT` this library has no member for. The code is in the log.
    ///
    /// Reaching this is not necessarily a bug, but it is always worth a look:
    /// the mapping in `com.check` is meant to be exhaustive for the calls this
    /// library makes.
    Unexpected,
};

/// `Stream.open` and `Capture.open`.
pub const OpenError = Error || std.mem.Allocator.Error || error{
    /// More channels were asked for than `channels.max_channels`.
    TooManyChannels,

    /// `Options.channel_map` was given but its length is not `Options.channels`.
    ChannelMapMismatch,

    /// `Options.channels` has no conventional layout and no `channel_map` was
    /// given to supply one. See `channels.defaultChannelMap`.
    NoDefaultChannelMap,

    /// `Options.rate` is zero, or beyond what any endpoint will resample to.
    InvalidRate,

    /// The data thread could not be started. The stream is not usable; nothing
    /// was left running.
    ThreadSpawnFailed,
};

/// `Stream.writeAll`.
pub const WriteError = Error || std.Io.Cancelable || error{
    /// The stream is `.failed`: the endpoint went away and either it was told
    /// not to follow the default or no replacement could be found.
    NotConnected,

    /// The stream was opened with a `Process` callback, so it has no queue to
    /// write into. Pulling and pushing are exclusive, and which one a stream
    /// does is fixed at `open`.
    WrongMode,
};

/// `Capture.readAll`.
pub const ReadError = Error || std.Io.Cancelable || error{
    NotConnected,

    /// The capture was opened with a `Process` callback, so it delivers audio
    /// rather than queueing it.
    WrongMode,
};

/// Everything `Stream` and `Capture` can return once open: setting a volume,
/// reading a state, and the two above.
pub const StreamError = WriteError || ReadError;

/// Looking an endpoint up, and reading its names.
///
/// Narrower than `SessionError` on purpose: none of these calls allocates or waits,
/// so neither `OutOfMemory` nor `Canceled` can come out of one. A caller who has
/// only looked a device up should not have to handle either, and the activation
/// path -- which returns `Error` -- could not propagate them at all.
pub const LookupError = Error || error{
    /// No endpoint or audio session answers to that id or name.
    NotFound,

    /// An endpoint id or name longer than the buffer offered for it. See
    /// `com.Endpoint.max_id_len`.
    NameTooLong,
};

/// Every `Session` call.
/// Everything a `Session` call can return: the lookups above, plus the allocation
/// a listing does and the waiting a refresh does.
pub const SessionError = LookupError || std.mem.Allocator.Error || std.Io.Cancelable;

/// Every error any call in this library can return, for a caller that wants one
/// `catch` for the lot.
pub const AnyError = OpenError || WriteError || ReadError || SessionError;

test "the per-operation sets are all subsets of AnyError" {
    // If this stops compiling, a set above gained a member that `AnyError` does
    // not name, and a caller switching exhaustively on `AnyError` would
    // silently stop seeing it.
    inline for (.{ Error, OpenError, WriteError, ReadError, StreamError, SessionError }) |Set| {
        inline for (@typeInfo(Set).error_set.?) |e| {
            const member: AnyError = @field(anyerror, e.name);
            _ = member catch {};
        }
    }
}

test "a device that vanished is distinct from one that was never there" {
    // Two different things a caller does two different things about: reopen on
    // another endpoint, versus tell the user there is no sound card. Collapsing
    // them into one member would make that impossible.
    try std.testing.expect(Error.DeviceInvalidated != Error.DeviceNotFound);
}

test {
    std.testing.refAllDecls(@This());
}
