#!/bin/zsh
# Builds Clyde.app without Xcode: `swift build` produces the executable, then this script
# assembles a standard .app bundle around it (Info.plist, entitlements, codesign) by hand.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Clyde"
CONFIGURATION="${1:-debug}"           # ./build.sh release for an optimized build
APP_BUNDLE="$ROOT/$APP_NAME.app"

echo "==> swift build (-c $CONFIGURATION)"
cd "$ROOT"
swift build -c "$CONFIGURATION"

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
EXECUTABLE="$BIN_PATH/$APP_NAME"

if [ ! -x "$EXECUTABLE" ]; then
    echo "error: built executable not found at $EXECUTABLE" >&2
    exit 1
fi

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# SPM resource bundles from dependencies (e.g. FluidAudio's) — Bundle.module resolves them
# relative to the app's Resources dir at runtime.
for bundle in "$BIN_PATH"/*.bundle(N); do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

echo "==> Codesigning"
# Prefer a stable self-signed "Developer" identity over ad-hoc (`-`): ad-hoc signatures are
# keyed to the binary's hash, so every rebuild looks like a brand-new app to TCC and
# mic/system-audio permission grants don't persist across builds. Create one once with:
#   Keychain Access > Certificate Assistant > Create a Certificate…
#     Name: Clyde Local Dev, Identity Type: Self Signed Root, Certificate Type: Code Signing
IDENTITY="${CLYDE_CODESIGN_IDENTITY:-Clyde Local Dev}"
# The identity lives in a dedicated keychain whose random password is stored in the login
# keychain (item "clyde-codesign-keychain"); unlock it non-interactively so codesign never prompts.
# The cert is self-signed and untrusted, so look it up without -v (codesign signs with it fine).
SIGN_KC="$HOME/Library/Keychains/clyde-codesign2.keychain-db"
if [ -f "$SIGN_KC" ] && KC_PW="$(security find-generic-password -a clyde -s clyde-codesign-keychain -w 2>/dev/null)"; then
    security unlock-keychain -p "$KC_PW" "$SIGN_KC"
fi
if ! security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "warning: codesigning identity '$IDENTITY' not found; falling back to ad-hoc (-)."
    echo "         TCC permission grants (mic, system audio) will NOT persist across rebuilds until you create one."
    echo "         See the comment above this line in build.sh for how to create it once."
    IDENTITY="-"
fi

codesign --force --deep --options runtime \
    --entitlements "$ROOT/Clyde.entitlements" \
    --sign "$IDENTITY" \
    "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
echo "    Run:  open \"$APP_BUNDLE\""
