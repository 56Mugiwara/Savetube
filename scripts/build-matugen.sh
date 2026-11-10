#!/bin/bash
# Build a native Matugen without installing Rust or Cargo globally.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache/helpers"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64)
    TARGET=aarch64-apple-darwin
    RUSTC_SHA=a68e3ada151e6eee10374529161d35dc26e8a185bddb14eabe6133f37144e02f
    CARGO_SHA=2f50ee5fe07c2a8df9f67726aad0fd30d343ba52485f76d57c4d0ca1113b2343
    STD_SHA=d2e1cbce8dda7a9f16df1393d003f6eb145b3b152a883a8791db326ebc03b549 ;;
  x86_64)
    TARGET=x86_64-apple-darwin
    RUSTC_SHA=de5afa548daca986e428728cf66e16cb5a9560e6bda2f61d0e55874b74811af5
    CARGO_SHA=f8935229479bb5d76378e768a4cbf868daa1264fd2ea7635b353fe0d93c0cda8
    STD_SHA=fd490b52577ac1ba1aa3e420e9bee0099e3c2fbba613b8c3d9b10553cbd0c6ff ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
mkdir -p "$CACHE"
fetch() {
  local url="$1" name="$2" expected="$3"
  if [[ ! -f "$CACHE/$name" ]]; then
    curl --fail --location --retry 3 "$url" --output "$CACHE/$name.partial"
    mv "$CACHE/$name.partial" "$CACHE/$name"
  fi
  [[ "$(shasum -a 256 "$CACHE/$name" | awk '{print $1}')" == "$expected" ]] || {
    echo "Checksum mismatch for $name" >&2; exit 1;
  }
}
fetch https://github.com/InioX/matugen/archive/refs/tags/v4.2.0.tar.gz matugen-v4.2.0.tar.gz 82044ab8ac3e793b2b94f8f75917b348b4038585133a77c07f5de59c88d65244
RUST="$CACHE/rust-$ARCH"
for component in rustc cargo rust-std; do
  case "$component" in rustc) SHA="$RUSTC_SHA" ;; cargo) SHA="$CARGO_SHA" ;; rust-std) SHA="$STD_SHA" ;; esac
  NAME="$component-1.91.0-$TARGET"
  fetch "https://static.rust-lang.org/dist/$NAME.tar.xz" "$NAME.tar.xz" "$SHA"
done
if [[ ! -x "$RUST/bin/cargo" || ! -d "$RUST/lib/rustlib/$TARGET/lib" ]]; then
  mkdir -p "$CACHE/rust-components-$ARCH"
  for component in rustc cargo rust-std; do
    NAME="$component-1.91.0-$TARGET"
    tar -xJf "$CACHE/$NAME.tar.xz" -C "$CACHE/rust-components-$ARCH"
    "$CACHE/rust-components-$ARCH/$NAME/install.sh" --prefix="$RUST" --disable-ldconfig
  done
fi
WORK="$CACHE/matugen-build-$ARCH"
SOURCE="$WORK/matugen-4.2.0"
mkdir -p "$WORK"
if [[ ! -f "$SOURCE/Cargo.lock" ]]; then tar -xzf "$CACHE/matugen-v4.2.0.tar.gz" -C "$WORK"; fi
export PATH="$RUST/bin:$PATH"
export CARGO_HOME="$CACHE/cargo-home"
export MACOSX_DEPLOYMENT_TARGET=13.0
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
if [[ ! -x "$SOURCE/target/release/matugen" ]]; then
  (cd "$SOURCE" && cargo build --release --locked --no-default-features --features dump-json) > "$WORK/build.log" 2>&1 || {
    tail -60 "$WORK/build.log" >&2; exit 1;
  }
fi
if otool -L "$SOURCE/target/release/matugen" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/)' >/dev/null; then
  echo "Matugen has an unexpected external runtime dependency" >&2; exit 1
fi
SOURCE_ARCHIVE="$CACHE/matugen-4.2.0-source-with-dependencies.tar.xz"
if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  # Cargo verifies each downloaded crate against the committed Cargo.lock.
  # Keep vendored source and licenses with the distributed GPL executable.
  (cd "$SOURCE" && cargo vendor --locked --versioned-dirs vendor) > "$WORK/vendor-config.toml" 2> "$WORK/vendor.log" || {
    tail -60 "$WORK/vendor.log" >&2; exit 1;
  }
  mkdir -p "$SOURCE/.cargo"
  sed 's|directory = ".*"|directory = "vendor"|' "$WORK/vendor-config.toml" > "$SOURCE/.cargo/config.toml"
  cat > "$SOURCE/SAVETUBE-BUILD.txt" <<EOF
Upstream: https://github.com/InioX/matugen/tree/v4.2.0
Tag commit: ef0a0820f486920bbdb6705246ad11edd2a47a86
Toolchain: official Rust/Cargo 1.91.0, native Apple architecture.
Rebuild from this directory with Rust/Cargo 1.91.0 on macOS:
MACOSX_DEPLOYMENT_TARGET=13.0 cargo build --release --locked --offline --no-default-features --features dump-json
The vendor directory contains the locked crates and their license notices.
Matugen is GPL-2.0-or-later; see LICENSE. No source-code patches are applied.
EOF
  tar -cJf "$SOURCE_ARCHIVE.partial" --exclude='./matugen-4.2.0/target' --exclude='matugen-4.2.0/target' -C "$WORK" matugen-4.2.0
  mv "$SOURCE_ARCHIVE.partial" "$SOURCE_ARCHIVE"
fi
"$SOURCE/target/release/matugen" --version
echo "Built native Matugen: $SOURCE/target/release/matugen"
