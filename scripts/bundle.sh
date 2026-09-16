#!/usr/bin/env bash
# Build ClaudeHeads in release mode and assemble a runnable ClaudeHeads.app in ./dist.
# Safe to re-run: the previous dist/ClaudeHeads.app is replaced each time.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="ClaudeHeads"
BUNDLE_ID="com.davenicoll.claude-heads"
VERSION="${CLAUDE_HEADS_VERSION:-1.0.0}"
BUILD_NUMBER="${CLAUDE_HEADS_BUILD:-1}"
MIN_OS="14.0"

DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

ICON_SRC="$ROOT/Sources/ClaudeHeads/Resources/AppIcon.icns"

echo "==> Building release binary"
swift build -c release

BUILD_DIR="$(swift build -c release --show-bin-path)"
BINARY="$BUILD_DIR/$APP_NAME"
if [[ ! -x "$BINARY" ]]; then
    echo "error: expected executable at $BINARY" >&2
    exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY" "$MACOS_DIR/$APP_NAME"
chmod 755 "$MACOS_DIR/$APP_NAME"

if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"
else
    echo "warning: $ICON_SRC not found; app will have no icon" >&2
fi

# SwiftPM resource bundles (e.g. ClaudeHeads_ClaudeHeadsCore.bundle, SwiftTerm_SwiftTerm.bundle).
# They go in Contents/Resources, which is the only signable location (anything else in the
# bundle root fails codesign with "unsealed contents present in the bundle root").
# Note: the SwiftPM-generated Bundle.module accessor only searches Bundle.main.bundleURL and
# the original .build path, not Contents/Resources, so app code must locate these bundles via
# Bundle.main.resourceURL rather than Bundle.module when running as an .app.
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
    name="$(basename "$bundle")"
    echo "    copying resource bundle $name"
    cp -R "$bundle" "$RESOURCES_DIR/$name"
    # codesign --deep refuses bundles without an Info.plist, so give them a minimal one.
    if [[ ! -f "$RESOURCES_DIR/$name/Info.plist" ]]; then
        bundle_base="${name%.bundle}"
        cat > "$RESOURCES_DIR/$name/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}.resources.${bundle_base}</string>
    <key>CFBundleName</key>
    <string>${bundle_base}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
</dict>
</plist>
PLIST
    fi
done
shopt -u nullglob

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Claude Heads</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Heads</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_OS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    open \"$APP_DIR\"   # or drag it into /Applications"
