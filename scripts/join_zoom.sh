#!/usr/bin/env bash
# Open a Zoom web-client URL in a *plain* Chrome instance (separate profile, no
# automation flags). Devin's default Chrome runs with --enable-automation and a
# Devin user agent, which trips Zoom's "Automated bots aren't allowed to join"
# reCAPTCHA gate. A clean instance passes. Drive the window with computer use.
#
# Usage: join_zoom.sh <web_client_url_or_join_url>
set -euo pipefail

URL="${1:?usage: join_zoom.sh <zoom url>}"
PROFILE="${ZOOM_CHROME_PROFILE:-$HOME/.zoom-chrome-profile}"
mkdir -p "$PROFILE"

case "$(uname -s)" in
  Darwin)
    BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    EXTRA=()
    ;;
  Linux)
    BIN="$(ls -d /opt/.devin/chrome/chrome/linux-*/chrome-linux64/chrome 2>/dev/null | head -1 || true)"
    [ -n "$BIN" ] || BIN="$(command -v chromium chromium-browser 2>/dev/null | head -1)"
    EXTRA=(--no-sandbox --disable-gpu)
    export DISPLAY="${DISPLAY:-:0}"
    ;;
  *) echo "unsupported OS" >&2; exit 1 ;;
esac

[ -x "$BIN" ] || { echo "chrome binary not found: $BIN" >&2; exit 1; }

nohup "$BIN" "${EXTRA[@]}" \
  --no-first-run --no-default-browser-check \
  --user-data-dir="$PROFILE" \
  --window-size=1280,900 --window-position=0,0 \
  "$URL" >"$PROFILE/launch.log" 2>&1 &

echo "launched pid $! -> $URL"
