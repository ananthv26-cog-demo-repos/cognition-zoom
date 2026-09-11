#!/usr/bin/env bash
# Join a Zoom meeting from a Devin VM as a named guest.
#
# macOS (verified 2026-09-11 on a Devin macOS 26 arm64 VM):
#   default  -> Zoom desktop app via zoommtg:// (display name pre-filled, BlackHole
#               2ch/16ch in the device picker, live captions transcribe `say`).
#               Requires the arm64 Zoom.pkg: /Applications/zoom.us.app.
#   safari   -> built-in Safari on the web client (joins as guest, mic picker lists
#               BlackHole, speaker is "Same as System" only).
#   chrome   -> plain Google Chrome (brew install --cask google-chrome) on the web
#               client with its own profile; joins as guest, full device picker.
# Linux: plain Chrome instance (Devin's default Chrome runs with --enable-automation
# and a Devin user agent, which trips Zoom's "Automated bots aren't allowed to join"
# reCAPTCHA gate). Drive the window with computer use afterwards.
#
# Usage: join_zoom.sh <web_client_url_or_join_url> [display_name]
#   ZOOM_JOIN_MODE=desktop|safari|chrome overrides the macOS default.
set -euo pipefail

URL="${1:?usage: join_zoom.sh <zoom url> [display name]}"
NAME="${2:-}"
PROFILE="${ZOOM_CHROME_PROFILE:-$HOME/.zoom-chrome-profile}"

launch_chrome() {
  local bin="$1"; shift
  [ -x "$bin" ] || { echo "chrome binary not found: $bin" >&2; exit 1; }
  mkdir -p "$PROFILE"
  nohup "$bin" "$@" \
    --no-first-run --no-default-browser-check \
    --user-data-dir="$PROFILE" \
    --window-size=1280,900 --window-position=0,0 \
    "$URL" >"$PROFILE/launch.log" 2>&1 &
  echo "launched chrome pid $! -> $URL"
}

case "$(uname -s)" in
  Darwin)
    MODE="${ZOOM_JOIN_MODE:-}"
    if [ -z "$MODE" ]; then
      if [ -d /Applications/zoom.us.app ]; then MODE=desktop
      elif [ -d "/Applications/Google Chrome.app" ]; then MODE=chrome
      else MODE=safari; fi
    fi
    case "$MODE" in
      desktop)
        # accepts https://…/j/<id>?pwd=<enc> and https://app.zoom.us/wc/join/<id>?pwd=<enc>
        ID="$(sed -E 's#.*/(j|join)/([0-9]+).*#\2#' <<<"$URL")"
        PWD_="$(sed -nE 's#.*[?&]pwd=([^&]+).*#\1#p' <<<"$URL")"
        [[ "$ID" =~ ^[0-9]+$ ]] || { echo "cannot parse meeting id from $URL" >&2; exit 1; }
        DEEP="zoommtg://zoom.us/join?confno=${ID}${PWD_:+&pwd=$PWD_}"
        [ -n "$NAME" ] && DEEP="$DEEP&uname=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$NAME")"
        open "$DEEP"
        echo "opened zoom.us.app -> $DEEP"
        ;;
      safari)
        open -a Safari "$URL"
        echo "opened Safari -> $URL"
        ;;
      chrome)
        launch_chrome "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        ;;
      *) echo "unknown ZOOM_JOIN_MODE=$MODE" >&2; exit 1 ;;
    esac
    ;;
  Linux)
    BIN="$(ls -d /opt/.devin/chrome/chrome/linux-*/chrome-linux64/chrome 2>/dev/null | head -1 || true)"
    [ -n "$BIN" ] || BIN="$(command -v chromium chromium-browser 2>/dev/null | head -1)"
    export DISPLAY="${DISPLAY:-:0}"
    launch_chrome "$BIN" --no-sandbox --disable-gpu
    ;;
  *) echo "unsupported OS" >&2; exit 1 ;;
esac
