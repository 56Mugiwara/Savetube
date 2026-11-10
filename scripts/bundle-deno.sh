#!/bin/bash
# Installs the pinned official runtime needed by yt-dlp's bundled EJS solver.
# Usage: bundle-deno.sh CACHE_DIRECTORY APP_BUNDLE ARCHITECTURE
set -euo pipefail
CACHE="${1:?Missing helper cache directory}"
APP="${2:?Missing app bundle path}"
ARCH="${3:-$(uname -m)}"
VERSION=2.9.8
case "$ARCH" in
  arm64) TARGET=aarch64-apple-darwin; SHA=9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e ;;
  x86_64) TARGET=x86_64-apple-darwin; SHA=4b2f5edd2639b7470f034238b321d7002d8dfb4726d8558f52c17afac370eb2c ;;
  *) echo "Unsupported Deno architecture: $ARCH" >&2; exit 1 ;;
esac
mkdir -p "$CACHE" "$APP/Contents/Helpers" "$APP/Contents/Resources/Sources"
fetch() {
  local url="$1" name="$2" sha="$3" actual
  if [[ ! -f "$CACHE/$name" ]]; then
    curl --fail --location --retry 3 "$url" --output "$CACHE/$name.partial"
    mv "$CACHE/$name.partial" "$CACHE/$name"
  fi
  actual="$(shasum -a 256 "$CACHE/$name" | awk '{print $1}')"
  [[ "$actual" == "$sha" ]] || { echo "Checksum mismatch for $name" >&2; exit 1; }
}
ZIP="deno-v$VERSION-$TARGET.zip"
SOURCE="https://raw.githubusercontent.com/denoland/deno/v$VERSION"
fetch "https://github.com/denoland/deno/releases/download/v$VERSION/deno-$TARGET.zip" "$ZIP" "$SHA"
fetch "$SOURCE/LICENSE.md" "deno-v$VERSION-LICENSE.md" f62497fffecc0852960c8d3e6934b9db86d16396e9b604072e923892cae3a588
fetch "$SOURCE/Cargo.lock" "deno-v$VERSION-Cargo.lock" 36aab78913808a9fb2e5a3a3a27a74a1a1045011133f28beaac6eabf57fc9895
fetch "https://raw.githubusercontent.com/denoland/rusty_v8/v150.4.0/LICENSE" rusty-v8-v150.4.0-LICENSE 1c6356fb751d45f0c53093ebf8a7f5e580e802f51999178e19d60f3ec39e147d
fetch "https://raw.githubusercontent.com/denoland/v8/ac1e23989121713ca642f6650b34deff7b686896/LICENSE" v8-ac1e2398-LICENSE 6ab33af8774a0f396ee3aeeb761e3229057682d6f9fa7f572e390c2cb3a6e509
unzip -p "$CACHE/$ZIP" deno > "$APP/Contents/Helpers/deno"
chmod +x "$APP/Contents/Helpers/deno"
cp "$CACHE/deno-v$VERSION-LICENSE.md" "$APP/Contents/Resources/Deno-LICENSE.md"
cp "$CACHE/rusty-v8-v150.4.0-LICENSE" "$APP/Contents/Resources/Deno-rusty-v8-LICENSE"
cp "$CACHE/v8-ac1e2398-LICENSE" "$APP/Contents/Resources/Deno-V8-LICENSE"
cp "$CACHE/deno-v$VERSION-Cargo.lock" "$APP/Contents/Resources/Sources/Deno-Cargo.lock"
cp "$0" "$APP/Contents/Resources/Sources/bundle-deno.sh"
cat > "$APP/Contents/Resources/Deno-PROVENANCE.txt" <<PROVENANCE
Deno $VERSION ($TARGET), unmodified official release executable.
Release: https://github.com/denoland/deno/releases/tag/v$VERSION
Binary: https://github.com/denoland/deno/releases/download/v$VERSION/deno-$TARGET.zip
SHA256: $SHA
Deno source revision: fe7ed012d92c642fd8e5607ac5a45d517538b5c5
Source: https://github.com/denoland/deno/tree/v$VERSION
Deno is MIT-licensed; see Deno-LICENSE.md.

Deno embeds V8 and Rust dependencies. Exact Rust versions, source registries and
checksums are retained in Sources/Deno-Cargo.lock from the same Deno release.
V8 binding: https://github.com/denoland/rusty_v8/tree/v150.4.0
V8 source: https://github.com/denoland/v8/tree/ac1e23989121713ca642f6650b34deff7b686896
See Deno-rusty-v8-LICENSE and Deno-V8-LICENSE for their notices and V8's
third-party component provenance. Upstream Deno source retains dependency notices.

Used only as yt-dlp's restricted JavaScript challenge runtime. The EJS solver
scripts are already included in the official yt-dlp_macos executable.
Setup: https://github.com/yt-dlp/yt-dlp/wiki/EJS
PROVENANCE
"$APP/Contents/Helpers/deno" --version
