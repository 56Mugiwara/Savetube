#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
HELPER="$ROOT/.cache/helpers/matugen-build-$ARCH/matugen-4.2.0/target/release/matugen"
if [[ ! -x "$HELPER" ]]; then "$ROOT/scripts/build-matugen.sh"; fi
HARNESS="$ROOT/.cache/theme-check/ThemeChecks.app"
mkdir -p "$HARNESS/Contents/MacOS" "$HARNESS/Contents/Helpers"
cat > "$HARNESS/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.savetube.themechecks</string><key>CFBundleExecutable</key><string>ThemeChecks</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
EOF
ln -sf "$HELPER" "$HARNESS/Contents/Helpers/matugen"
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swiftc -parse-as-library -swift-version 5 "$ROOT/Sources/SaveTube/ThemeStore.swift" \
  "$ROOT/Tests/ThemeChecks/main.swift" -o "$HARNESS/Contents/MacOS/ThemeChecks"
"$HARNESS/Contents/MacOS/ThemeChecks"
