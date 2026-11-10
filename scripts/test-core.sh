#!/bin/bash
# Standalone regression checks for the Swift library and both background helpers.
# All media, metadata, outputs, and generated binaries stay under a temporary root.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/savetube-core.XXXXXX")"
trap 'rm -rf "$CHECK_ROOT"' EXIT
export SAVETUBE_TEST_ROOT="$CHECK_ROOT"
export SAVETUBE_DOWNLOADS_DIR="$CHECK_ROOT/Downloads"
swiftc -swift-version 5 \
  "$PROJECT_DIR/Sources/SaveTube/LibraryStore.swift" \
  "$PROJECT_DIR/Sources/SaveTube/BackgroundCopier.swift" \
  "$PROJECT_DIR/Tests/LibraryChecks/main.swift" \
  -o "$CHECK_ROOT/core-checks"
"$CHECK_ROOT/core-checks"
