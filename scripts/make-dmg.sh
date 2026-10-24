#!/bin/bash
set -euo pipefail

ROOT=$(cd -P "$(dirname "$0")/.." && pwd)
PUBLIC=0
if [[ ${1:-} == --public ]]; then PUBLIC=1; shift; fi
[[ $# == 0 ]] || { echo "Usage: scripts/make-dmg.sh [--public]" >&2; exit 1; }
APP="$ROOT/dist/Pastty.app"
[[ ! -L "$ROOT/dist" && ! -L "$ROOT/.release-tmp" ]] || { echo "Output directories must not be symlinks." >&2; exit 1; }
if [[ "$PUBLIC" == 1 ]]; then
    "$ROOT/scripts/verify-release.sh" --public "$APP"
    [[ -n ${SIGNING_IDENTITY:-} && -n ${NOTARY_PROFILE:-} ]] || { echo "Public DMG requires SIGNING_IDENTITY and a stored NOTARY_PROFILE." >&2; exit 1; }
    CHANNEL=release
else
    "$ROOT/scripts/verify-release.sh" "$APP"
    CHANNEL=dev
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCHS=$(lipo -archs "$APP/Contents/MacOS/pastty")
case "$ARCHS" in arm64) ARCH=arm64 ;; x86_64) ARCH=x86_64 ;; 'x86_64 arm64'|'arm64 x86_64') ARCH=universal ;; *) echo "Unexpected architectures: $ARCHS" >&2; exit 1 ;; esac
NAME="Pastty-$VERSION-$ARCH-$CHANNEL.dmg"
OUTPUT="$ROOT/dist/$NAME"
[[ ! -e "$OUTPUT" ]] || { echo "DMG already exists: $OUTPUT. Move it aside before rebuilding." >&2; exit 1; }
mkdir -p "$ROOT/.release-tmp"
STAGING=$(mktemp -d "$ROOT/.release-tmp/dmg.XXXXXX")
MOUNTED=0
cleanup() {
    if [[ "$MOUNTED" == 1 ]]; then hdiutil detach "$STAGING/mount" >/dev/null || true; fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
mkdir -p "$STAGING/content"
ditto "$APP" "$STAGING/content/Pastty.app"
ln -s /Applications "$STAGING/content/Applications"
cp "$ROOT/LICENSE" "$STAGING/content/LICENSE.txt"
cp "$ROOT/docs/安装与使用.md" "$STAGING/content/安装与使用.txt"
if [[ "$PUBLIC" == 0 ]]; then
    printf '%s\n' 'Pastty development preview' 'Not notarized for public distribution. Runtime and installation validation may be incomplete.' 'Drag Pastty.app to Applications. This build does not install Rust, Homebrew, or other dependencies.' > "$STAGING/content/DEVELOPMENT-PREVIEW.txt"
fi
hdiutil create -volname "Pastty $VERSION" -srcfolder "$STAGING/content" -format UDZO -ov "$STAGING/$NAME"
if [[ "$PUBLIC" == 1 ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$STAGING/$NAME"
    xcrun notarytool submit "$STAGING/$NAME" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$STAGING/$NAME"
    xcrun stapler validate "$STAGING/$NAME"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$STAGING/$NAME"
fi
hdiutil verify "$STAGING/$NAME"
mkdir "$STAGING/mount"
hdiutil attach -readonly -nobrowse -mountpoint "$STAGING/mount" "$STAGING/$NAME"
MOUNTED=1
[[ -x "$STAGING/mount/Pastty.app/Contents/MacOS/pastty" ]] || { echo "DMG contains no executable app." >&2; exit 1; }
[[ $(readlink "$STAGING/mount/Applications") == /Applications ]] || { echo "Missing Applications shortcut." >&2; exit 1; }
[[ -s "$STAGING/mount/安装与使用.txt" ]] || { echo "Missing installation instructions." >&2; exit 1; }
"$ROOT/scripts/verify-release.sh" "$STAGING/mount/Pastty.app"
hdiutil detach "$STAGING/mount"
MOUNTED=0
mv "$STAGING/$NAME" "$OUTPUT"
(cd "$ROOT/dist" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "Created $OUTPUT"
echo "Checksum: $OUTPUT.sha256"
[[ "$PUBLIC" == 1 ]] || echo "Development DMG only; no GitHub Release or public notarization performed."
