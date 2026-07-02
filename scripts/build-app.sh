#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Codex Keeper"
BINARY_NAME="CodexWake"
CLI_BINARY_NAME="codex-keeper"
CONFIGURATION="${1:-release}"
SCRATCH_PATH="${CODEX_WAKE_SCRATCH_PATH:-}"
SWIFT_SIZE_FLAGS=()
if [[ "$CONFIGURATION" == "release" && "${CODEX_WAKE_OPTIMIZE_FOR_SIZE:-1}" != "0" ]]; then
  SWIFT_SIZE_FLAGS=(-Xswiftc -Osize)
fi

cd "$ROOT_DIR"

if [[ -n "$SCRATCH_PATH" ]]; then
  swift build -c "$CONFIGURATION" "${SWIFT_SIZE_FLAGS[@]}" --scratch-path "$SCRATCH_PATH" --product "$BINARY_NAME"
  swift build -c "$CONFIGURATION" "${SWIFT_SIZE_FLAGS[@]}" --scratch-path "$SCRATCH_PATH" --product "$CLI_BINARY_NAME"
  BUILD_DIR="$SCRATCH_PATH/$(uname -m)-apple-macosx/$CONFIGURATION"
else
  swift build -c "$CONFIGURATION" "${SWIFT_SIZE_FLAGS[@]}" --product "$BINARY_NAME"
  swift build -c "$CONFIGURATION" "${SWIFT_SIZE_FLAGS[@]}" --product "$CLI_BINARY_NAME"
  BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
fi

APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$BUILD_DIR/$BINARY_NAME" "$MACOS_DIR/$BINARY_NAME"
cp "$BUILD_DIR/$CLI_BINARY_NAME" "$MACOS_DIR/$CLI_BINARY_NAME"
if [[ "$CONFIGURATION" == "release" && "${CODEX_WAKE_STRIP:-1}" != "0" ]]; then
  /usr/bin/strip -S -x "$MACOS_DIR/$BINARY_NAME" "$MACOS_DIR/$CLI_BINARY_NAME"
fi
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

/usr/bin/codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
