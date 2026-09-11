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
# Linux (verified 2026-09-11 on a Devin Ubuntu 22.04 x86_64 VM):
#   default  -> Zoom desktop app (/usr/bin/zoom from zoom_amd64.deb) via zoommtg://,
#               after linux_audio.sh creates the PulseAudio null sinks (DevinMicSrc as
#               mic, ZoomOut as speaker); live captions transcribe espeak-ng/paplay.
#   chrome   -> plain Chrome instance (Devin's default Chrome runs with
#               --enable-automation and a Devin user agent, which trips Zoom's
#               "Automated bots aren't allowed to join" reCAPTCHA gate).
# Drive the window with computer use afterwards.
#
# Usage: join_zoom.sh <web_client_url_or_join_url> [display_name]
#   ZOOM_JOIN_MODE=desktop|safari|chrome overrides the default (safari is macOS only).
#   macOS auto mode skips the desktop app if its binary does not match `uname -m`
#   (the generic Zoom.pkg is x86_64-only and fails with -10669 on arm64); Linux auto
#   mode skips it when /usr/bin/zoom is not installed.
#   On macOS, Notification Center banners are closed first (dismiss_notifications.sh)
#   and approve_mic_prompts.sh is launched to auto-Allow the devin-remote mic TCC
#   dialog. Afterwards, run show_meeting_window.sh if the Zoom Workplace sign-in
#   window is on screen instead of the join preview / meeting window.
#   Desktop mode does not return until the meeting window is on screen (Zoom can
#   take ~45 s to map it, and screenshots taken before that show the old desktop);
#   ZOOM_WINDOW_WAIT caps that wait. Windows Zoom already had before the deep
#   link (a previous meeting still open) do not count as the new one.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZOOM_APP=/Applications/zoom.us.app

zoom_app_runnable() {
  [ -d "$ZOOM_APP" ] && lipo -archs "$ZOOM_APP/Contents/MacOS/zoom.us" 2>/dev/null | grep -qE "(^| )$(uname -m)e?( |$)"
}

URL="${1:?usage: join_zoom.sh <zoom url> [display name]}"
NAME="${2:-}"
PROFILE="${ZOOM_CHROME_PROFILE:-$HOME/.zoom-chrome-profile}"

# zoommtg:// deep link from https://…/j/<id>?pwd=<enc> or https://app.zoom.us/wc/join/<id>?pwd=<enc>
deep_link() {
  local id pwd_ deep
  id="$(sed -E 's#.*/(j|join)/([0-9]+).*#\2#' <<<"$URL")"
  pwd_="$(sed -nE 's#.*[?&]pwd=([^&]+).*#\1#p' <<<"$URL")"
  [[ "$id" =~ ^[0-9]+$ ]] || { echo "cannot parse meeting id from $URL" >&2; exit 1; }
  deep="zoommtg://zoom.us/join?confno=${id}${pwd_:+&pwd=$pwd_}"
  [ -n "$NAME" ] && deep="$deep&uname=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$NAME")"
  echo "$deep"
}

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
    "$HERE/dismiss_notifications.sh" || true
    nohup "$HERE/approve_mic_prompts.sh" >/dev/null 2>&1 &
    MODE="${ZOOM_JOIN_MODE:-}"
    if [ -z "$MODE" ]; then
      if zoom_app_runnable; then MODE=desktop
      elif [ -d "/Applications/Google Chrome.app" ]; then MODE=chrome
      else MODE=safari; fi
      [ -d "$ZOOM_APP" ] && [ "$MODE" != desktop ] && echo "zoom.us.app is not built for $(uname -m); falling back to $MODE" >&2
    fi
    case "$MODE" in
      desktop)
        DEEP="$(deep_link)"
        PRIOR="$("$HERE/show_meeting_window.sh" --snapshot)"
        open "$DEEP"
        echo "opened zoom.us.app -> $DEEP"
        ZOOM_NO_REFIRE=1 ZOOM_PRIOR_WINDOWS="$PRIOR" "$HERE/show_meeting_window.sh" "$URL" "" "$NAME"
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
    export DISPLAY="${DISPLAY:-:0}"
    MODE="${ZOOM_JOIN_MODE:-}"
    if [ -z "$MODE" ]; then
      if [ -x /usr/bin/zoom ]; then MODE=desktop; else MODE=chrome; fi
    fi
    case "$MODE" in
      desktop)
        [ -x /usr/bin/zoom ] || { echo "zoom binary not found: /usr/bin/zoom (sudo apt-get install -y ./zoom_amd64.deb)" >&2; exit 1; }
        "$HERE/linux_audio.sh" >/dev/null || echo "linux_audio.sh failed; Zoom will report no microphone" >&2
        DEEP="$(deep_link)"
        PRIOR="$("$HERE/show_meeting_window.sh" --snapshot)"
        nohup /usr/bin/zoom "$DEEP" >"$HOME/zoom-desktop.log" 2>&1 &
        echo "launched zoom pid $! -> $DEEP"
        ZOOM_NO_REFIRE=1 ZOOM_PRIOR_WINDOWS="$PRIOR" "$HERE/show_meeting_window.sh" "$URL" "" "$NAME"
        ;;
      chrome)
        BIN="$(ls -d /opt/.devin/chrome/chrome/linux-*/chrome-linux64/chrome 2>/dev/null | head -1 || true)"
        [ -n "$BIN" ] || BIN="$(command -v chromium chromium-browser 2>/dev/null | head -1)"
        launch_chrome "$BIN" --no-sandbox --disable-gpu
        ;;
      *) echo "unknown ZOOM_JOIN_MODE=$MODE" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unsupported OS" >&2; exit 1 ;;
esac
