#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=44100:cl=mono -t 2 -c:a libmp3lame "$test_root/silent.mp3"
ffmpeg -hide_banner -loglevel error -f lavfi -i sine=frequency=1000:sample_rate=44100 -t 2 -c:a libmp3lame "$test_root/tone.mp3"
ffmpeg -hide_banner -loglevel error -f lavfi -i sine=frequency=1000:sample_rate=44100 -t 120 -c:a libmp3lame "$test_root/long-tone.mp3"
ffmpeg -hide_banner -loglevel error -f lavfi -i sine=frequency=1000:sample_rate=44100 -t 2 -c:a aac "$test_root/tone.mp4"
ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=44100:cl=mono -f lavfi -i sine=frequency=1000:sample_rate=44100 -filter_complex '[0:a]atrim=duration=1[a];[1:a]atrim=duration=1[b];[a][b]concat=n=2:v=0:a=1[out]' -map '[out]' -c:a libmp3lame "$test_root/pulse.mp3"
swiftc -parse-as-library -swift-version 5 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos13 Sources/SaveTube/AudioVisualizationStore.swift Tests/VisualizationChecks/main.swift -o "$test_root/visualization-checks"
SAVETUBE_TEST_ROOT="$test_root" "$test_root/visualization-checks"
