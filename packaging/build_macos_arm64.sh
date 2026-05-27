#!/usr/bin/env bash
# Build iMessage Archiver.app for macOS arm64 using PyInstaller.
# Run from the repo root:
#   ./packaging/build_macos_arm64.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
APP_NAME="iMessage Archiver"
SPEC="$REPO_ROOT/packaging/imessage_archiver.spec"

echo "==> Building $APP_NAME (arm64)"
echo "    Repo root : $REPO_ROOT"
echo "    Dist dir  : $DIST_DIR"
echo ""

# Activate venv if present
if [ -f "$REPO_ROOT/.venv/bin/activate" ]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.venv/bin/activate"
fi

# Ensure PyInstaller + GUI extras are installed
pip install --quiet "pyinstaller>=6.0" "PySide6>=6.8"

# Clean previous build artefacts
rm -rf "$DIST_DIR/$APP_NAME.app" "$REPO_ROOT/build"

# Run PyInstaller
pyinstaller \
    --noconfirm \
    --clean \
    --distpath "$DIST_DIR" \
    --workpath "$REPO_ROOT/build" \
    "$SPEC"

APP_PATH="$DIST_DIR/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Build failed — $APP_PATH not found" >&2
    exit 1
fi

# Verify the binary is arm64
MAIN_BIN="$APP_PATH/Contents/MacOS/$APP_NAME"
echo ""
echo "==> Verifying architecture"
lipo -archs "$MAIN_BIN"
ARCHS=$(lipo -archs "$MAIN_BIN")
if [[ "$ARCHS" != *"arm64"* ]]; then
    echo "ERROR: arm64 not present in binary (got: $ARCHS)" >&2
    exit 1
fi
echo "    OK — $ARCHS"

echo ""
echo "==> Build complete"
echo "    App : $APP_PATH"
echo "    Size: $(du -sh "$APP_PATH" | cut -f1)"
