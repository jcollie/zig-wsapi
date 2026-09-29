<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-wsapi

Play and record audio on Windows, from Zig, without linking a C library.

It speaks WASAPI — the Windows Audio Session API — through COM directly, using
[zigwin32](https://github.com/marlersoft/zigwin32) for the bindings and nothing else. No
miniaudio, no PortAudio, no libc. This is the Windows half of a pair; the Linux half is
[zig-pipewire](https://git.jcollie.dev/jeff/zig-pipewire), and the two have deliberately
similar APIs.

The API reference is generated from the doc comments and published at
<https://jeff.jcollie.page/zig-wsapi/>.

```zig
const stream = try wasapi.Stream.open(gpa, io, .{ .name = "my app", .channels = 2 });
defer stream.close(io);

_ = try stream.waitStreaming(io, five_seconds);
try stream.writeAll(io, interleaved_f32_samples, .none);
stream.drain(io, two_seconds);
```

## What it does

| | |
|---|---|
| **`Stream`** | Playback. Push frames with `write`/`writeAll`, or supply them from a `Process` callback once per graph cycle. Shared mode, float samples, `IAudioClient3` low-latency periods where the hardware allows. |
| **`Capture`** | Recording, from a microphone or — with `.source = .loopback` — from whatever the machine is playing. |
| **`Session`** | The control plane: enumerate endpoints, read and set their volumes and mute, and list what each program is playing, which is what the Volume Mixer shows. |
| **Follows the default** | When the user changes their output device, or unplugs it, a stream moves itself to the new one and the queued audio plays on. |

## Requirements

- Zig 0.16
- Windows Vista or later. `IAudioClient3`'s low-latency path needs Windows 10 1703 and
  falls back gracefully without it.
- Nothing else. No libc, and no `linkSystemLibrary` calls: Zig links `ole32` and `avrt`
  from the `extern` declarations in the bindings.

## Installation

```sh
zig fetch --save git+https://git.jcollie.dev/jeff/zig-wsapi.git
```

Then wire the module up in `build.zig`:

```zig
const wasapi = b.dependency("wasapi", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("wasapi", wasapi.module("wasapi"));
```

The Win32 bindings are a lazy dependency of this package, so they are fetched when you
first build for Windows and never otherwise.

## Usage

### Playing a tone

The push API. A queue sits between your loop and the audio engine, which is what lets an
irregular producer play cleanly.

```zig
const stream = try wasapi.Stream.open(gpa, io, .{
    .name = "my app",
    .channels = 2,
    .rate = 48000,
});
defer stream.close(io);

_ = try stream.waitStreaming(io, timeout);

var block: [960 * 2]f32 = undefined;
var phase: f32 = 0;
const step = 2.0 * std.math.pi * 440.0 / @as(f32, @floatFromInt(stream.rate()));

while (playing) {
    for (0..block.len / 2) |i| {
        const sample = @sin(phase) * 0.2;
        block[i * 2 + 0] = sample;
        block[i * 2 + 1] = sample;
        phase += step;
    }
    try stream.writeAll(io, &block, timeout);
}

// So the tail is heard rather than cut off.
stream.drain(io, timeout);
```

### Supplying audio on demand

The pull API. Lower latency, and the right shape for a synthesiser — at the cost of
producing audio on the engine's schedule, inside a real-time deadline.

```zig
fn fill(ctx: *anyopaque, planes: []const []f32, frames: u32) void {
    const synth: *Synth = @ptrCast(@alignCast(ctx));
    for (0..frames) |i| {
        const sample = synth.next();
        for (planes) |plane| plane[i] = sample;
    }
}

const stream = try wasapi.Stream.open(gpa, io, .{
    .channels = 2,
    .process = .{ .ctx = &synth, .func = &fill },
});
```

### Recording

```zig
const capture = try wasapi.Capture.open(gpa, io, .{ .source = .microphone });
defer capture.close(io);

var frames: [4800 * 2]f32 = undefined;
while (recording) {
    const got = try capture.readAll(io, &frames, timeout);
    try file.write(frames[0 .. got * capture.channels()]);
}
```

`.source = .loopback` records the output instead, which is how you capture system audio
without a virtual cable.

### Listing and changing volumes

```zig
var session: wasapi.Session = try .open(io, .{});
defer session.close(io);

var sinks = try session.sinks();
defer sinks.deinit();

while (try sinks.next()) |endpoint| {
    var device = endpoint;
    defer device.deinit();

    var buf: [wasapi.Endpoint.max_name_len]u8 = undefined;
    std.debug.print("{s}: {f}\n", .{
        try device.label(&buf),
        try session.volume(device),
    });
}
```

## Mapping from PipeWire

If you know `zig-pipewire`, this is what moves and what does not. Windows has no
user-visible audio graph, and most of the differences follow from that.

| zig-pipewire | zig-wsapi | |
|---|---|---|
| `Stream.open` / `close` | same | `io` is threaded through, as in zig-hidapi |
| `write` / `writeAll` / `writable` / `queued` | same | |
| `Process` callback, planes per channel | same | one transpose more here: a WASAPI buffer is always interleaved |
| `pause` / `unpause` / `isActive` | same | |
| `rate` / `quantum` / `time` / `stats` | same | `quantum` is the engine period; see below |
| `graphChannels` | `endpointChannels` | there is no graph to belong to |
| `Session` sinks and sources | `Session.sinks` / `sources` | a live query, not a cached registry — so no `roundTrip` |
| `Session` streams | `Session.appSessions` | one entry per process, as in the Volume Mixer |
| `setVolume` / `setMute` | same, per endpoint | plus `AppSession.setLevel` for one program's own |
| `Options.environ` / `runtime_dir` / `remote` | *gone* | there is no socket to find |
| `Options.autoconnect` | *gone* | WASAPI always connects |
| `createLink` / `linkNodes` / `destroy` | *gone* | no ports, no links, nothing to wire |
| metadata store | *gone* | no counterpart |
| `setDefaultSink` | present, always `error.Unsupported` | see below |
| — | `Capture` with `.loopback` | Windows does this more simply than PipeWire does |
| — | `Options.follow_default`, `Stats.reopens` | PipeWire moves a node for you; here the library has to reopen |

Three things are worth reading the doc comments for rather than guessing at:

- **`setDefaultSink` cannot work.** Windows exposes no public API for choosing the
  default endpoint; the Sound control panel uses `IPolicyConfig`, which is undocumented,
  absent from the Windows metadata, and has changed shape between releases. The call
  exists so the gap is documented where you would look for it. Choose your own endpoint
  with `Stream.Options.target` instead.
- **`Stats.wake` is not PipeWire's WAIT.** PipeWire gets a timestamp from the driver
  saying when the node was marked ready. WASAPI has no such timestamp, so this is the
  deviation of the interval between wakeups from the period — a good jitter measure and
  not a scheduling latency.
- **`Stats.missed_cycles` is inferred**, not reported: there is no glitch counter.
  `underrun_frames` is exact and is usually the number you want.

## API overview

### `wasapi.Stream`

`open` `close` `write` `writeAll` `writable` `queued` `underruns` `pause` `unpause`
`isActive` `rate` `quantum` `endpointChannels` `endpointFormat` `getState` `time` `stats`
`resetStats` `waitStreaming` `drain`

### `wasapi.Capture`

`open` `close` `read` `readAll` `available` `overruns` `rate` `channels`
`capturedFormat` `quantum` `getState` `stats` `waitStreaming`

### `wasapi.Session`

`open` `close` `endpoints` `sinks` `sources` `default` `defaultSink` `defaultSource`
`byId` `volume` `setVolume` `setChannelVolumes` `setMute` `peak` `appSessions`
`setDefaultSink`

### Lower layers

`wasapi.com` is exported for callers who need to reach past the three types above:
apartment handling, `HRESULT` mapping, endpoint enumeration, and the activation path. The
operating-system-independent half — `Ring`, `channel`, `format`, `mix`, `time`, `stats`,
`wait` — is exported too, and is importable on any host through `src/portable.zig`.

## Errors

Every error set is explicit and lives in `src/errors.zig`; none is inferred. A `HRESULT`
never reaches a caller: it is collapsed into one of the members of `wasapi.Error` and
written to the log on the way past, so the error says what happened and the log says which
number said so.

The members worth handling specifically are `DeviceInvalidated` (the endpoint went away —
usually handled for you, see `follow_default`), `DeviceInUse` (another program holds it
exclusively), `AccessDenied` (the microphone privacy setting, most often) and
`ServiceNotRunning`.

## Where this lives

The canonical repository is on Forgejo at
[git.jcollie.dev/jeff/zig-wsapi](https://git.jcollie.dev/jeff/zig-wsapi):

```sh
git clone https://git.jcollie.dev/jeff/zig-wsapi.git
```

It is mirrored to:

- **Tangled**, at <https://tangled.org/jcollie.dev/zig-wsapi>.
- **Radicle**, as `rad:z2sCVUCXDvVqYFrE4UsDk8J9fTXje`:

  ```sh
  rad clone rad:z2sCVUCXDvVqYFrE4UsDk8J9fTXje
  ```

- **GitHub**, which exists for its `windows-latest` runner.

The API reference, generated from the doc comments, is published at
<https://jeff.jcollie.page/zig-wsapi/>.

## Development

```sh
zig build                # the examples into zig-out/bin
zig build test           # the test suite
zig build check          # compile for every supported target, without linking
zig build docs           # API reference into zig-out/docs
zig build docs-serve     # ...and serve it at http://127.0.0.1:8000/
zig build fuzz           # the fuzz targets, once each
tools/wine-test.sh       # the Windows suite under Wine, on x86-64 Linux

zig build run-devices    # list endpoints, volumes and sessions
zig build run-tone -- 440 2
zig build run-callback -- 2
zig build run-record -- 5 voice.wav
zig build run-loopback -- 5 output.wav
```

`zig build docs` needs a Windows target, because the module it documents is
Windows-only -- on another host, `zig build docs -Dtarget=x86_64-windows-gnu`. And
`--fuzz` is not implemented for Windows in Zig 0.16, so the fuzz targets run once each
here and are actually fuzzed on the Linux runner, which is why they live in the portable
half.

and the lint trio:

```sh
reuse lint
typos
zig fmt --check --exclude zig-pkg .
```

### What the tests cover, and what they cannot

`zig build test` on **any host** runs the operating-system-independent suite: the ring
buffer under two-thread torture, the channel permutations against a table of real
`dwChannelMask` values, the `WAVEFORMATEXTENSIBLE` encoder against byte-exact golden
headers, every sample conversion round trip, the performance-counter arithmetic across ten
years of uptime, the statistics handoff under concurrent readers, and the wait loop.

`zig build check` type-checks **every line of the COM half** from any host, cross-compiled
for two Windows architectures — vtable signatures, GUID namespaces, cast shapes — and
compiles the portable half for Linux, which is what keeps it free of Win32.

On **Windows** the suite adds the COM tests, the apartment handling, and
`tests/loopback.zig`: it plays a 440 Hz tone, records it back through a loopback capture,
and asserts with a Goertzel filter that the energy came back at the right pitch. That one
test exercises the whole library at once.

Under **Wine**, on x86-64 Linux, `tools/wine-test.sh` runs that same Windows suite. It
gives Wine a private PulseAudio server whose only sink is a null sink, so nothing reaches
the speakers and the loopback test still has an endpoint to play to and record back from.
Wine's audio path is not Windows', but it is the one place the loopback test runs on every
push, since the Forgejo workflow runs it there in every optimize mode. The script uses a
throwaway Wine prefix and leaves `~/.wine` alone. The dev shell carries the 64-bit build
of Wine it needs; the plain `wine` package is 32-bit only and rejects the test binaries
with "Bad EXE format".

A hosted Windows runner generally has **no audio endpoint**, so the playback and capture
tests report `SkipZigTest` there. What the GitHub Windows job actually buys is that every
symbol exists in real Windows DLLs, the structure layouts are right, and the apartment
handling is correct. The audible half needs a real machine, which means before a release:

- that a tone is clean and not clicking, and that a chord sounds the same through the pull
  API;
- that surround channels come out of the right speakers — the golden tables prove the
  permutation is self-consistent, not that it is correct;
- that changing the default output device mid-tone migrates without a stoppage, and that
  `Stats.reopens` counts it;
- that the program appears in the Volume Mixer under the expected name and that its slider
  works.

## References cited

- [About WASAPI](https://learn.microsoft.com/en-us/windows/win32/coreaudio/wasapi) and the
  Core Audio APIs documentation, for the interfaces and their ordering rules.
- `mmdeviceapi.h`, `audioclient.h`, `mmreg.h` and `ksmedia.h`, for the constants and the
  `WAVEFORMATEXTENSIBLE` layout the golden tests assert.
- [Low latency audio](https://learn.microsoft.com/en-us/windows/win32/coreaudio/low-latency-audio),
  for `IAudioClient3` and the shared-mode period.
- [zigwin32](https://github.com/marlersoft/zigwin32), which is where every Win32
  declaration here comes from.
- [zig-pipewire](https://git.jcollie.dev/jeff/zig-pipewire), whose API this one mirrors.

## License

MIT. See `LICENSES/MIT.txt`.
