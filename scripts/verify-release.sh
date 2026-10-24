#!/bin/bash
set -euo pipefail

ROOT=$(cd -P "$(dirname "$0")/.." && pwd)
PUBLIC=0
if [[ ${1:-} == --public ]]; then PUBLIC=1; shift; fi
[[ $# -le 1 ]] || { echo "Usage: scripts/verify-release.sh [--public] [Pastty.app]" >&2; exit 1; }
APP=${1:-$ROOT/dist/Pastty.app}
[[ $(uname -s) == Darwin ]] || { echo "Verification requires macOS." >&2; exit 1; }
PLIST="$APP/Contents/Info.plist"
BINARY="$APP/Contents/MacOS/pastty"
[[ -f "$PLIST" && -x "$BINARY" && -f "$APP/Contents/Resources/LICENSE" ]] || { echo "Incomplete Pastty.app bundle." >&2; exit 1; }
[[ -s "$APP/Contents/Resources/Pastty.icns" && -s "$APP/Contents/Resources/MenuIconTemplate.png" ]] || { echo "Missing Pastty icon resources." >&2; exit 1; }
NOTICES="$APP/Contents/Resources/DEPENDENCY-LICENSES.txt"
[[ -s "$NOTICES" ]] || { echo "Dependency license notices are missing." >&2; exit 1; }
plutil -lint "$PLIST"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST") == pastty ]] || { echo "Unexpected executable." >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PLIST") == Pastty.icns ]] || { echo "Unexpected application icon." >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST") == true ]] || { echo "Pastty must remain a menu-bar application." >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST") == 14.0 ]] || { echo "Unexpected minimum macOS." >&2; exit 1; }
ARCHS=$(lipo -archs "$BINARY")
for ARCH in $ARCHS; do
    case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
done
[[ -n "$ARCHS" ]] || { echo "No Mach-O architecture found." >&2; exit 1; }
otool -L "$BINARY" | awk '
    NR > 1 && $1 ~ /^\// && $1 !~ /^\/System\/Library\// && $1 !~ /^\/usr\/lib\// { bad=1 }
    END { exit bad }
' || { echo "Application depends on a non-system absolute library path." >&2; exit 1; }
# Check the binary deployment target as well as the plist declaration.
BUILD_INFO=$(xcrun vtool -show-build "$BINARY")
printf '%s\n' "$BUILD_INFO" | awk '
    $1 == "minos" { seen=1; if ($2 != "14.0") bad=1 }
    END { if (!seen || bad) exit 1 }
' || { echo "Binary deployment target does not match macOS 14.0." >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Bundle structure, deployment target, architectures ($ARCHS), and signature verified."
if [[ "$PUBLIC" == 1 ]]; then
    grep -qx 'Unresolved license texts: 0' "$NOTICES" || { echo "Public release has unresolved dependency license notices." >&2; exit 1; }
    SIGNATURE=$(codesign -d --verbose=4 "$APP" 2>&1)
    printf '%s\n' "$SIGNATURE" | grep -q '^Authority=Developer ID Application:' || { echo "Public release requires Developer ID Application signing." >&2; exit 1; }
    printf '%s\n' "$SIGNATURE" | grep -q 'flags=.*runtime' || { echo "Public release requires hardened runtime." >&2; exit 1; }
    [[ ! -e "$APP/Contents/Resources/DEVELOPMENT-PREVIEW.txt" ]] || { echo "Development preview marker is present." >&2; exit 1; }
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
    echo "Public signing, stapled notarization, and Gatekeeper checks passed."
else
    echo "Development validation only: notarization and another-Mac installation are not established."
fi
