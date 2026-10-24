#!/bin/bash
# Developer-only isolated AppKit lifecycle test. Does not use the system clipboard,
# paste into other apps, or register login startup. Window alpha is zero during stress.
# PASS memory-sample means task_info succeeded, not that a resource budget passed.
set -euo pipefail
ROOT=$(cd -P "$(dirname "$0")/.." && pwd)
[[ $(uname -s) == Darwin ]] || { echo 'FAIL stress-requires-macOS' >&2; exit 1; }
[[ $# -le 2 ]] || { echo 'Usage: scripts/stress-native.sh [cycles=1000] [Pastty.app]' >&2; exit 1; }
CYCLES=${1:-${PASTTY_STRESS_CYCLES:-1000}}
[[ "$CYCLES" =~ ^[1-9][0-9]{0,4}$ ]] && (( CYCLES <= 10000 )) || { echo 'FAIL stress-cycle-count-must-be-1-to-10000' >&2; exit 1; }
APP=${2:-"$ROOT/dist/Pastty.app"}
BINARY="$APP/Contents/MacOS/pastty"
[[ -x "$BINARY" && -f "$APP/Contents/Resources/Pastty.icns" ]] || { echo 'FAIL stress-requires-built-Pastty-app-with-icon' >&2; exit 1; }
STRESS_TMPROOT=${TMPDIR:-/tmp}
WORK=$(mktemp -d "${STRESS_TMPROOT%/}/pastty-native-stress.XXXXXX")
chmod 700 "$WORK"
mkdir -m 700 "$WORK/data"
echo "Isolated stress evidence: $WORK"
echo "Isolated lifecycle validation only; global hotkeys and cross-application paste are not exercised."
if ! env PASTTY_SMOKE_TEST=1 PASTTY_STRESS_CYCLES="$CYCLES" \
    PASTTY_DATA_DIR="$WORK/data" PASTTY_SMOKE_HOLD_SECONDS=0 PASTTY_SMOKE_VIEW=stress \
    "$BINARY" 2>&1 | tee "$WORK/run.log"; then
    echo 'FAIL native-stress-process' >&2
    exit 1
fi
if ! /usr/bin/grep -Fxq "PASS stress-complete cycles=$CYCLES" "$WORK/run.log" || /usr/bin/grep -q '^FAIL ' "$WORK/run.log"; then
    echo 'FAIL native-stress-assertions' >&2
    exit 1
fi
printf 'PASS native-stress-script cycles=%s\n' "$CYCLES"
