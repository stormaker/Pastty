#!/bin/bash
set -euo pipefail

ROOT=$(cd -P "$(dirname "$0")/.." && pwd)
cd "$ROOT"
[[ $(uname -s) == Darwin ]] || { echo "Build Pastty on macOS." >&2; exit 1; }
CARGO=${CARGO:-cargo}
RUSTC=${RUSTC:-rustc}
if ! command -v "$CARGO" >/dev/null 2>&1 && [[ -x "$HOME/.cargo/bin/cargo" ]]; then
    CARGO="$HOME/.cargo/bin/cargo"
    RUSTC="$HOME/.cargo/bin/rustc"
fi
TARGET=${1:-$("$RUSTC" -vV | awk '/^host:/ {print $2}')}
case "$TARGET" in
    aarch64-apple-darwin|x86_64-apple-darwin) ;;
    *) echo "Supported targets: aarch64-apple-darwin, x86_64-apple-darwin." >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: scripts/build-app.sh [target-triple]" >&2; exit 1; }
BUNDLE_ID=${BUNDLE_ID:-com.stormaker.pastty}
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { echo "Invalid BUNDLE_ID." >&2; exit 1; }
BUILD_NUMBER=${BUILD_NUMBER:-1}
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "Invalid BUILD_NUMBER." >&2; exit 1; }
VERSION=$("$CARGO" metadata --no-deps --format-version 1 | python3 -c 'import json,sys; d=json.load(sys.stdin); p=next(p for p in d["packages"] if p["name"]=="pastty"); print(p["version"])')
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Bundle builds require a numeric X.Y.Z package version." >&2; exit 1; }

# Build outputs and cleanup stay inside this repository, never /Applications.
[[ ! -L "$ROOT/dist" && ! -L "$ROOT/.release-tmp" ]] || { echo "Output directories must not be symlinks." >&2; exit 1; }
mkdir -p "$ROOT/dist" "$ROOT/.release-tmp"
STAGING=$(mktemp -d "$ROOT/.release-tmp/app.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
export MACOSX_DEPLOYMENT_TARGET=14.0
"$CARGO" build --release --locked --target "$TARGET"
BINARY="$ROOT/target/$TARGET/release/pastty"
[[ -x "$BINARY" ]] || { echo "Missing release executable: $BINARY" >&2; exit 1; }
APP="$STAGING/Pastty.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BINARY" "$APP/Contents/MacOS/pastty"
cp packaging/Info.plist "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp packaging/Pastty.icns packaging/MenuIconTemplate.png "$APP/Contents/Resources/"
if [[ -n ${SIGNING_IDENTITY:-} ]]; then
    CARGO="$CARGO" python3 "$ROOT/scripts/collect-licenses.py" \
        --target "$TARGET" --output "$APP/Contents/Resources/DEPENDENCY-LICENSES.txt" --strict
else
    CARGO="$CARGO" python3 "$ROOT/scripts/collect-licenses.py" \
        --target "$TARGET" --output "$APP/Contents/Resources/DEPENDENCY-LICENSES.txt"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$PLIST"
if [[ -n ${SIGNING_IDENTITY:-} ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
    printf '%s\n' 'Development preview: ad-hoc signed; not Developer ID signed or notarized.' > "$APP/Contents/Resources/DEVELOPMENT-PREVIEW.txt"
    codesign --force --sign - "$APP"
fi
"$ROOT/scripts/verify-release.sh" "$APP"
# Replace only this script's generated app after the new app passes verification.
[[ ! -L "$ROOT/dist/Pastty.app" ]] || { echo "Refusing to replace an app symlink." >&2; exit 1; }
if [[ -e "$ROOT/dist/Pastty.app" ]]; then
    mv "$ROOT/dist/Pastty.app" "$STAGING/previous-Pastty.app"
fi
mv "$APP" "$ROOT/dist/Pastty.app"
echo "Built $ROOT/dist/Pastty.app ($VERSION, $TARGET)."
echo "No app installed, launched, or registered for login."
