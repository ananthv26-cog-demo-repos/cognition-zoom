#!/usr/bin/env bash
# show_meeting_window.sh — make sure the *meeting* window (join preview or the
# in-meeting window), not the "Zoom Workplace" sign-in home window, is on
# screen. Zoom always opens the home window alongside the deep link and it is
# a decoy: if you only see "Sign in"/"Join a meeting", you are NOT in the
# meeting. If no meeting window exists this re-fires the zoommtg:// deep link
# so the join preview comes up again.
#
# The meeting window can take the better part of a minute to map after Zoom
# starts, so this waits (ZOOM_WINDOW_WAIT seconds, default 60) for it instead
# of reporting failure while Zoom is still coming up.
#
#   scripts/show_meeting_window.sh "<join_url>" [window title substring] [display name]
# Pass the display name so a re-fired join keeps the roster identity.
# ZOOM_NO_REFIRE=1 only waits and raises (join_zoom.sh uses it right after it
# launches Zoom, when re-firing would just start a second join).
#
#   scripts/show_meeting_window.sh --snapshot
# prints the ids of Zoom's current windows (X window ids on Linux, CoreGraphics
# window numbers on macOS), one per line; exits non-zero if they could not be
# enumerated. join_zoom.sh takes it before firing the deep link and passes it as
# ZOOM_PRIOR_WINDOWS, so a meeting Zoom was already showing is never accepted
# as the one being waited for. Ids, not titles: a new window may reuse the
# title of an old one (recurring topic).
# On Windows use the PowerShell equivalent in SKILL.md §4.
set -uo pipefail

# zoom_windows prints "<window id>\t<title>" per Zoom-owned window.
# Exit status: 0 = enumerated (no rows = Zoom is up but has mapped nothing yet),
# 3 = no Zoom process, anything else = enumeration failed.
mac_windows() {
  local pids
  pids="$(pgrep -x zoom.us)"
  [ -z "$pids" ] && return 3
  # CoreGraphics window numbers are stable for a window's lifetime; System Events
  # windows only expose names, and two Zoom windows can share a name
  osascript -l JavaScript - $pids <<'EOF'
ObjC.import('CoreGraphics');
ObjC.import('Foundation');
function run(argv) {
  const pids = argv.map(Number);
  // kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID.
  // The CFArrayRef must go through castRefToObject: $.CFBridgingRelease on it
  // segfaults osascript (observed on macOS 26).
  const list = $.CGWindowListCopyWindowInfo(1 | 16, 0);
  const wins = ObjC.deepUnwrap(ObjC.castRefToObject(list));
  const out = [];
  for (const w of wins) {
    if (pids.indexOf(Number(w.kCGWindowOwnerPID)) < 0) continue;
    if (Number(w.kCGWindowLayer) !== 0) continue;
    const name = w.kCGWindowName === undefined || w.kCGWindowName === null ? '' : String(w.kCGWindowName);
    if (name === '') continue;
    out.push(String(w.kCGWindowNumber) + '\t' + name);
  }
  return out.join('\n');
}
EOF
}

mac_raise() {  # $1 = CoreGraphics window number, $2 = title
  # Accessibility windows carry no CG number. With one window of that title the
  # match is exact; with several (recurring topic still open in a stale window)
  # raise each in turn and accept only when CG (front-to-back order) shows $1 on top.
  local n i
  n="$(osascript - "$2" <<'EOF'
on run argv
  tell application "System Events" to tell process "zoom.us"
    count (windows whose name is (item 1 of argv))
  end tell
end run
EOF
)" || return 1
  for ((i = 1; i <= n; i++)); do
    osascript - "$2" "$i" <<'EOF' >/dev/null || continue
on run argv
  tell application "System Events" to tell process "zoom.us"
    set same to (windows whose name is (item 1 of argv))
    perform action "AXRaise" of item ((item 2 of argv) as integer) of same
    set frontmost to true
  end tell
end run
EOF
    [ "$n" = 1 ] && return 0
    sleep 0.3
    [ "$(mac_windows | head -n1 | cut -f1)" = "$1" ] && return 0
  done
  return 1
}

linux_windows() {
  local pids
  # find Zoom's windows by PID: the meeting window is titled after the meeting
  # topic ("Devin standup"), so anything that greps window titles for "zoom"
  # sees only the home window and never the meeting
  pids="$(pgrep -x zoom; pgrep -f '/opt/zoom/zoom')"
  [ -z "$pids" ] && return 3
  wmctrl -lp | awk -v pids="^($(tr '\n' '|' <<<"$pids" | sed 's/|$//'))$" \
    '$3 ~ pids { wid = $1; $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); if ($0 != "") print wid "\t" $0 }'
}

linux_raise() {  # raise by window id, never by title: wmctrl -a does its own
  wmctrl -i -a "$1"  # substring match and could pick the home window instead
}

case "$(uname -s)" in
  Darwin) zoom_windows() { mac_windows; }; raise_window() { mac_raise "$@"; } ;;
  Linux)
    export DISPLAY="${DISPLAY:-:0}"
    zoom_windows() { linux_windows; }; raise_window() { linux_raise "$@"; } ;;
  *)
    echo "Windows: Start-Process \"zoommtg://...\" then WScript.Shell AppActivate (see SKILL.md §4)" >&2
    exit 1
    ;;
esac

if [ "${1:-}" = --snapshot ]; then
  rows="$(zoom_windows)"; rc=$?
  case "$rc" in
    0) cut -f1 <<<"$rows" | grep . ; exit 0 ;;
    3) exit 0 ;;
    *) echo "could not enumerate Zoom windows (status $rc)" >&2; exit 1 ;;
  esac
fi

URL="${1:?usage: show_meeting_window.sh <zoom url> [window title substring] [display name]}"
WANT="${2:-}"
NAME="${3:-}"
PRIOR="${ZOOM_PRIOR_WINDOWS:-}"
WAIT="${ZOOM_WINDOW_WAIT:-60}"
# how long a windowless Zoom process is assumed to be starting up before it is
# treated as an idle background client that needs the deep link again
GRACE="${ZOOM_START_GRACE:-25}"

MEETING_ID="$(sed -E 's#.*/(j|join)/([0-9]+).*#\2#' <<<"$URL")"

deep_link() {
  local pwd_ enc_name=""
  pwd_="$(sed -nE 's#.*[?&]pwd=([^&]+).*#\1#p' <<<"$URL")"
  [[ "$MEETING_ID" =~ ^[0-9]+$ ]] || { echo "cannot parse meeting id from $URL" >&2; exit 1; }
  if [ -n "$NAME" ]; then
    enc_name="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe=""))' "$NAME" 2>/dev/null \
      || sed 's/[^A-Za-z0-9._~-]/_/g' <<<"$NAME")"
  fi
  echo "zoommtg://zoom.us/join?confno=${MEETING_ID}${pwd_:+&pwd=$pwd_}${enc_name:+&uname=$enc_name}"
}

# Each attempt prints one of: "raised <title>" | "starting" (Zoom is up but has
# not mapped a window yet) | "home-only" | "no-zoom" | "enum-failed".
attempt() {
  local rows rc found=""
  rows="$(zoom_windows)"; rc=$?
  case "$rc" in
    0) ;;
    3) echo "no-zoom"; return ;;
    *) echo "enum-failed"; return ;;
  esac
  [ -z "$rows" ] && { echo "starting"; return; }
  pick() {  # $1 = title substring to prefer ("" = any non-home zoom window)
    local wid title
    while IFS=$'\t' read -r wid title; do
      [ -z "$wid" ] && continue
      case "$title" in *"Zoom Workplace"*|Settings) continue;; esac
      grep -qxF -- "$wid" <<<"$PRIOR" && continue
      [ -n "$1" ] && ! grep -qF -- "$1" <<<"$title" && continue
      raise_window "$wid" "$title" && { found="$title"; return 0; }
    done <<<"$rows"
    return 1
  }
  pick "$WANT" || pick ""
  [ -n "$found" ] && echo "raised $found" || echo "home-only"
}

refire() {
  case "$(uname -s)" in
    Darwin) open "$(deep_link)" ;;
    Linux)  nohup /usr/bin/zoom "$(deep_link)" >"$HOME/zoom-desktop.log" 2>&1 & ;;
  esac
  echo "re-fired join deep link for meeting $MEETING_ID"
}

refired=0
begin="$(date +%s)"
deadline=$(( begin + WAIT ))
while :; do
  STATE="$(attempt)"
  case "$STATE" in
    "raised "*) echo "$STATE"; exit 0 ;;
  esac
  now="$(date +%s)"
  # "starting" means Zoom owns no window yet: wait out the grace period first, a
  # second deep link during startup would only add another instance — but a Zoom
  # left running in the background never grows a window on its own, so re-fire
  # once the grace period is over
  if [ "$refired" = 0 ] && [ -z "${ZOOM_NO_REFIRE:-}" ] &&
     { [ "$STATE" != starting ] || [ $(( now - begin )) -ge "$GRACE" ]; }; then
    refire
    refired=1
    deadline=$(( now + WAIT ))
  elif [ "$now" -ge "$deadline" ]; then
    echo "no meeting window after ${WAIT}s (zoom state: $STATE)" >&2
    exit 1
  fi
  sleep 2
done
