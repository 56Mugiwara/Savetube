#!/bin/bash
# Generates real local media and exercises the native in-app AVPlayer.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/savetube-playback.XXXXXX")"
trap 'rm -rf "$CHECK_ROOT"' EXIT
export SAVETUBE_TEST_ROOT="$CHECK_ROOT"

ffmpeg -nostdin -loglevel error -f lavfi -i 'sine=frequency=440:duration=6' \
  -c:a libmp3lame -q:a 5 -metadata title="Fixture Track" -metadata artist="Fixture Artist" "$CHECK_ROOT/first.mp3"
ffmpeg -nostdin -loglevel error -f lavfi -i 'color=c=black:s=320x180:r=15:d=6' \
  -f lavfi -i 'anullsrc=channel_layout=stereo:sample_rate=44100' -t 6 \
  -c:v mpeg4 -q:v 5 -c:a aac -shortest "$CHECK_ROOT/second.mp4"

swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  "$PROJECT_DIR/Sources/SaveTube/PlaybackStore.swift" \
  "$PROJECT_DIR/Tests/PlaybackChecks/main.swift" \
  -o "$CHECK_ROOT/playback-checks"
"$CHECK_ROOT/playback-checks"
