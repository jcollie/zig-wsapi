#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

# Run the Windows test suite under Wine, against an audio server of its own.
#
#   tools/wine-test.sh                      # Debug
#   tools/wine-test.sh -Doptimize=ReleaseFast
#
# Any arguments are passed to `zig build test`. Run it from the dev shell,
# which carries the 64-bit Wine and PulseAudio this needs.
#
# Wine plays audio through PulseAudio, so what the loopback test hears is what a
# PulseAudio server gives it. This starts a private one whose only sink is a
# null sink: nothing reaches the speakers, the result does not depend on
# whatever the machine's own audio happens to be doing, and a CI runner with no
# sound hardware gets a real endpoint to play to and record back from. Without
# any server at all Wine still offers an endpoint, but one whose
# `IAudioClient::Initialize` answers `E_NOTIMPL`, and the loopback test fails
# on it.
#
# The Wine prefix is private too, and thrown away afterwards, so a run neither
# uses nor disturbs `~/.wine`.

set -euo pipefail

scratch=$(mktemp -d)
cleanup() {
    pulseaudio --kill 2>/dev/null || true
    wineserver --kill 2>/dev/null || true
    rm -rf "$scratch"
}
trap cleanup EXIT

mkdir -m 700 "$scratch/runtime"
export XDG_RUNTIME_DIR="$scratch/runtime"
export WINEPREFIX="$scratch/wine"
export WINEDEBUG="${WINEDEBUG:--all}"
# So that PulseAudio and Wine find the private server rather than a session's.
unset PULSE_SERVER DBUS_SESSION_BUS_ADDRESS

# `-n` skips the system default.pa, which would try to load hardware modules.
pulseaudio \
    --daemonize=yes \
    --exit-idle-time=-1 \
    -n \
    --load=module-native-protocol-unix \
    --load="module-null-sink sink_name=wine_test" \
    --load=module-always-sink

zig build test -Dtarget=x86_64-windows-gnu -fwine --summary all "$@"
