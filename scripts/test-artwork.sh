#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=red:s=4096x4096 -frames:v 1 "$test_root/cover.png"
ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=44100:cl=mono -t 1 -c:a libmp3lame "$test_root/artwork.mp3"
cp "$test_root/artwork.mp3" "$test_root/coalesced.mp3"
swiftc -parse-as-library -swift-version 5 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos13 \
  Sources/SaveTube/LibraryStore.swift Sources/SaveTube/ArtworkOverrides.swift Sources/SaveTube/MediaArtwork.swift \
  Tests/ArtworkChecks/main.swift -o "$test_root/artwork-checks"
SAVETUBE_DATA_DIR="$test_root/library" SAVETUBE_TEST_ROOT="$test_root" "$test_root/artwork-checks"
