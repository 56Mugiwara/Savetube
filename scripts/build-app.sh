#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-1.0.0}"
# Prefer the installed stable SDK when preview Command Line Tools are selected.
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
CACHE="$ROOT/.cache/helpers"
APP="$ROOT/dist/SaveTube.app"
mkdir -p "$CACHE" "$ROOT/dist"

# Validate existing cache entries as well as newly downloaded files.
fetch() {
  local url="$1" name="$2" sha="$3"
  if [[ ! -f "$CACHE/$name" ]]; then
    curl --fail --location --retry 3 "$url" --output "$CACHE/$name.partial"
    mv "$CACHE/$name.partial" "$CACHE/$name"
  fi
  local actual
  actual="$(shasum -a 256 "$CACHE/$name" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    echo "Checksum mismatch for $name. Remove $CACHE/$name and rebuild." >&2
    exit 1
  fi
}

swift build --build-system native -c release
BIN_DIR="$(swift build --build-system native -c release --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/SaveTube" "$APP/Contents/MacOS/SaveTube"
cp Resources/SaveTube.icns "$APP/Contents/Resources/SaveTube.icns"
[[ ! -f LICENSE ]] || cp LICENSE "$APP/Contents/Resources/LICENSE"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>SaveTube</string>
<key>CFBundleDisplayName</key><string>Savetube</string>
<key>CFBundleIdentifier</key><string>com.56mugiwara.savetube</string>
<key>CFBundleExecutable</key><string>SaveTube</string>
<key>CFBundleIconFile</key><string>SaveTube</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

if [[ "${SKIP_HELPERS:-0}" != 1 ]]; then
  ./scripts/build-matugen.sh
  YTDLP_BASE=https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26
  fetch "$YTDLP_BASE/yt-dlp_macos" yt-dlp_macos 0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa
  fetch https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz ffmpeg-8.0.1.tar.xz 05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41
  fetch https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz lame-3.100.tar.gz ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
  TOOLCHAIN="$CACHE/build-$ARCH-v1"
  if [[ ! -x "$TOOLCHAIN/bin/ffmpeg" || ! -x "$TOOLCHAIN/bin/ffprobe" ]]; then
    mkdir -p "$TOOLCHAIN/src" "$TOOLCHAIN/bin"
    tar -xzf "$CACHE/lame-3.100.tar.gz" -C "$TOOLCHAIN/src"
    tar -xJf "$CACHE/ffmpeg-8.0.1.tar.xz" -C "$TOOLCHAIN/src"
    JOBS="$(sysctl -n hw.logicalcpu)"
    (
      cd "$TOOLCHAIN/src/lame-3.100"
      CFLAGS="-O2 -mmacosx-version-min=13.0" ./configure --prefix="$TOOLCHAIN" --disable-shared --enable-static --disable-frontend --disable-dependency-tracking
      make -j"$JOBS"
      make install
    ) > "$TOOLCHAIN/lame-build.log" 2>&1 || { tail -60 "$TOOLCHAIN/lame-build.log"; exit 1; }
    (
      cd "$TOOLCHAIN/src/ffmpeg-8.0.1"
      export PKG_CONFIG_LIBDIR="$TOOLCHAIN/lib/pkgconfig"
      export PKG_CONFIG_PATH="$TOOLCHAIN/lib/pkgconfig"
      ./configure --prefix="$TOOLCHAIN" --cc=clang --disable-autodetect --disable-shared --enable-static --disable-doc --disable-debug --disable-ffplay --disable-x86asm --enable-gpl --enable-version3 --enable-libmp3lame --extra-cflags="-I$TOOLCHAIN/include -mmacosx-version-min=13.0" --extra-ldflags="-L$TOOLCHAIN/lib -mmacosx-version-min=13.0" --disable-everything --enable-ffmpeg --enable-ffprobe --enable-swresample --enable-avfilter --enable-decoder=aac,aac_fixed,mp3,mp3float,opus,vorbis,flac,pcm_s16le,pcm_s24le,pcm_f32le,alac --enable-parser=aac,mpegaudio,opus,vorbis,flac,h264,hevc --enable-demuxer=mov,matroska,mp3,aac,ogg,wav,flac,hls,dash,mpegts,concat --enable-muxer=mp4,mp3,ipod,adts,null --enable-encoder=libmp3lame,aac,pcm_s16le --enable-filter=aresample,anull,aformat --enable-protocol=file,pipe,http,https,tcp,tls,crypto,httpproxy --enable-securetransport --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata
      make -j"$JOBS"
      cp ffmpeg ffprobe "$TOOLCHAIN/bin/"
    ) > "$TOOLCHAIN/ffmpeg-build.log" 2>&1 || { tail -60 "$TOOLCHAIN/ffmpeg-build.log"; exit 1; }
  fi
  for media_helper in "$TOOLCHAIN/bin/ffmpeg" "$TOOLCHAIN/bin/ffprobe"; do
    if otool -L "$media_helper" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/)' >/dev/null; then
      echo "Unexpected external runtime dependency in $media_helper" >&2
      exit 1
    fi
  done
  fetch "https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.10.26/THIRD_PARTY_LICENSES.txt" yt-dlp-THIRD_PARTY_LICENSES.txt 472aefe951c7db35e1657c1d13fd337140511ed6f2b329205105ad441c5a02b7
  cp "$CACHE/yt-dlp_macos" "$APP/Contents/Helpers/yt-dlp"
  cp "$TOOLCHAIN/bin/ffmpeg" "$APP/Contents/Helpers/ffmpeg"
  cp "$TOOLCHAIN/bin/ffprobe" "$APP/Contents/Helpers/ffprobe"
  cp "$CACHE/matugen-build-$ARCH/matugen-4.2.0/target/release/matugen" "$APP/Contents/Helpers/matugen"
  cp "$TOOLCHAIN/src/ffmpeg-8.0.1/COPYING.GPLv3" "$APP/Contents/Resources/FFmpeg-LICENSE"
  cp "$TOOLCHAIN/src/lame-3.100/COPYING" "$APP/Contents/Resources/LAME-LICENSE"
  cp "$CACHE/matugen-build-$ARCH/matugen-4.2.0/LICENSE" "$APP/Contents/Resources/Matugen-LICENSE"
  mkdir -p "$APP/Contents/Resources/Sources"
  cp "$CACHE/ffmpeg-8.0.1.tar.xz" "$CACHE/lame-3.100.tar.gz" "$APP/Contents/Resources/Sources/"
  cp scripts/build-app.sh "$APP/Contents/Resources/Sources/build-app.sh"
  cp scripts/build-matugen.sh "$APP/Contents/Resources/Sources/build-matugen.sh"
  cp "$CACHE/matugen-4.2.0-source-with-dependencies.tar.xz" "$APP/Contents/Resources/Sources/"
  cp "$CACHE/yt-dlp-THIRD_PARTY_LICENSES.txt" "$APP/Contents/Resources/yt-dlp-THIRD_PARTY_LICENSES.txt"
  cat > "$APP/Contents/Resources/THIRD-PARTY.txt" <<EOF
yt-dlp 2026.10.26: https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26
Source and licenses: https://github.com/yt-dlp/yt-dlp/tree/2026.10.26
The macOS standalone executable includes third-party components; see yt-dlp's
THIRD_PARTY_LICENSES.txt at the source link.

FFmpeg 8.0.1 and LAME 3.100: built locally from unmodified official source.
https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz
https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
Source archives and exact build commands are bundled in Resources/Sources.
FFmpeg is GPLv3 in this build; LAME is LGPL. See adjacent license files.
No nonfree components or external non-system dynamic libraries are enabled.

Matugen 4.2.0: https://github.com/InioX/matugen/tree/v4.2.0
GPL-2.0-or-later. Built with Rust 1.91.0 and the upstream Cargo.lock.
Full Matugen source, locked vendored dependency source and license notices,
and offline rebuild instructions ship in Resources/Sources.
EOF
  ./scripts/bundle-deno.sh "$CACHE" "$APP" "$ARCH"
  chmod +x "$APP/Contents/Helpers/"*
  for helper in "$APP/Contents/Helpers/"*; do
    if [[ "$(basename "$helper")" == deno ]]; then
      # Preserve upstream JIT/unsigned-executable-memory entitlements.
      codesign --verify --strict "$helper"
    else
      codesign --force --sign - "$helper"
    fi
  done
fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ZIP="$ROOT/dist/SaveTube-$VERSION-macos-$ARCH.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Built $APP"
echo "Packaged $ZIP"
