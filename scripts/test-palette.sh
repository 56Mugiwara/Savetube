#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_ROOT="$(mktemp -d)"
trap 'rm -rf "$CHECK_ROOT"' EXIT
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=red:s=64x64 -frames:v 1 "$CHECK_ROOT/artwork.png"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=blue:s=64x64 -frames:v 1 "$CHECK_ROOT/wallpaper.png"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=green:s=64x64 -frames:v 1 "$CHECK_ROOT/no-artwork.png"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=0x808080:s=64x64 -frames:v 1 "$CHECK_ROOT/grayscale.png"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=64x64 -frames:v 1 "$CHECK_ROOT/black.png"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=white:s=64x64 -frames:v 1 "$CHECK_ROOT/white.png"
ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=44100:cl=mono -t 1 -c:a libmp3lame "$CHECK_ROOT/no-artwork.mp3"
ffmpeg -hide_banner -loglevel error -i "$CHECK_ROOT/no-artwork.mp3" -i "$CHECK_ROOT/artwork.png" -map 0:a -map 1:v -c copy -id3v2_version 3 -disposition:v attached_pic "$CHECK_ROOT/artwork.mp3"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swiftc -parse-as-library -swift-version 5 -sdk "$SDK" "$ROOT/Sources/SaveTube/LibraryStore.swift" "$ROOT/Sources/SaveTube/ArtworkOverrides.swift" "$ROOT/Sources/SaveTube/MediaPaletteStore.swift" "$ROOT/Sources/SaveTube/ThemeStore.swift" "$ROOT/Tests/PaletteChecks/main.swift" -o "$CHECK_ROOT/palette-checks"
SAVETUBE_DATA_DIR="$CHECK_ROOT/library" SAVETUBE_TEST_ROOT="$CHECK_ROOT" "$CHECK_ROOT/palette-checks"
