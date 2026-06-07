#!/usr/bin/env bash
# Build qmanager_ping for Casa CFW-3212 (ARMv7 musl) into the vendored path.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CRATE_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="armv7-unknown-linux-musleabihf"
DEST="$REPO_ROOT/qmanager/casa_conversion/vendor/scripts/usr/bin/qmanager_ping"

cd "$CRATE_DIR"

if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: cargo not found. Install Rust (rustup) first." >&2
    exit 1
fi

if ! rustup target list --installed | grep -q "^${TARGET}\$"; then
    echo "Installing Rust target ${TARGET}..."
    rustup target add "$TARGET"
fi

if ! command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1; then
    echo "ERROR: arm-linux-gnueabihf-gcc not found. Install gcc-arm-linux-gnueabihf." >&2
    exit 1
fi

echo "Building qmanager_ping (release, target=${TARGET})..."
cargo build --release --target="$TARGET"
BIN="$CRATE_DIR/target/$TARGET/release/qmanager_ping"

if [ ! -f "$BIN" ]; then
    echo "ERROR: build did not produce $BIN" >&2
    exit 1
fi

if command -v arm-linux-gnueabihf-strip >/dev/null 2>&1; then
    arm-linux-gnueabihf-strip "$BIN"
fi

mkdir -p "$(dirname "$DEST")"
cp "$BIN" "$DEST"
chmod 755 "$DEST"

SIZE_KB=$(( $(stat -c %s "$DEST") / 1024 ))
echo "Installed vendored qmanager_ping: $DEST (${SIZE_KB} KB)"
sha256sum "$DEST"
