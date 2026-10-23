#!/usr/bin/env bash
# install.sh: Build and install Remote Guardian for macOS

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Remote Guardian"
TARGET_DIR="$HOME/Applications"
APP_BUNDLE="$TARGET_DIR/$APP_NAME.app"
ARCH="$(uname -m)"

echo "=== Installing Remote Guardian ==="
echo "Target Architecture: $ARCH"

# Ensure swiftc is available
if ! command -v swiftc >/dev/null 2>&1; then
    echo "Error: swiftc compiler not found. Please install Xcode Command Line Tools via: xcode-select --install"
    exit 1
fi

# Stop any currently running instance of the menu bar app before replacing binary
pkill -f "Remote Guardian" 2>/dev/null || true

mkdir -p "$TARGET_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

echo "Compiling native Swift application..."
swiftc -target "${ARCH}-apple-macos13.0" -O "$SCRIPT_DIR/src/main.swift" -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "Copying Info.plist..."
cp "$SCRIPT_DIR/resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "Applying ad-hoc code signature..."
codesign --force --deep --sign - "$APP_BUNDLE"

# Install CLI tool into an active writable PATH directory
CLI_DEST=""
for candidate in "/opt/homebrew/bin" "/usr/local/bin" "$HOME/.local/bin" "$HOME/bin"; do
    if [ -d "$candidate" ] && [ -w "$candidate" ] && [[ ":$PATH:" == *":$candidate:"* ]]; then
        CLI_DEST="$candidate/remote-guardian"
        break
    fi
done

if [ -z "$CLI_DEST" ]; then
    mkdir -p "$HOME/.local/bin"
    CLI_DEST="$HOME/.local/bin/remote-guardian"
fi

cp "$SCRIPT_DIR/bin/remote-guardian" "$CLI_DEST"
chmod +x "$CLI_DEST"

echo "CLI tool installed to $CLI_DEST"

# Open the app
echo "Launching Menu Bar App..."
open "$APP_BUNDLE"

echo ""
echo "✓ Installation complete! Look for the bolt icon in your top menu bar."
