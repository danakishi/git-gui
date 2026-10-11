#!/bin/zsh
# Builds the app, launches it, captures the window to a PNG, and quits.
#
#   scripts/shot.sh out.png [delay] [--select=N] [--working-tree]
#
# Needed to check the UI without the system screen-recording permission:
# the window draws itself (see DebugScreenshot.swift). The app's stderr
# is printed so crashes are visible. NO_BUILD=1 skips the build.

set -uo pipefail
cd "$(dirname "$0")/.."

OUT=${1:?path to png}
DELAY=${2:-4}
shift 2 2>/dev/null || shift $#

[[ -n "${NO_BUILD:-}" ]] || ./scripts/build-app.sh >/dev/null || exit 1
pkill -x GitGui 2>/dev/null; sleep 0.5
rm -f "$OUT"

.build/GitGui.app/Contents/MacOS/GitGui --screenshot "$OUT" --delay "$DELAY" --quit "$@" 2>&1 \
  | grep -vE "^\s*$|^\(|^\t[0-9]+ " | head -20 &
PID=$!
# Safety net in case the app hangs and doesn't exit on its own.
( sleep $((DELAY + 30)); pkill -x GitGui 2>/dev/null ) &
wait $PID

if [[ -f "$OUT" ]]; then
  echo "Screenshot: $OUT"
else
  echo "No screenshot" >&2
  exit 1
fi
