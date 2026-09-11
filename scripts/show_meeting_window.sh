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
# ZOOM_PRIOR_WINDOWS holds the output of `show_meeting_window.sh --snapshot`
# taken before the deep link was fired; those windows (a meeting Zoom was
# already showing) are never accepted as the one being waited for.
# On Windows use the PowerShell equivalent in SKILL.md §4.
set -uo pipefail

if [ "${1:-}" = --snapshot ]; then
  case "$(uname -s)" in
    Darwin)
      osascript -e 'tell application "System Events"
        if not (exists process "zoom.us") then return ""
        set out to ""
        repeat with w in windows of process "zoom.us"
          try
            set out to out & (name of w) & linefeed
          end try
        end repeat
        return out
      end tell' ;;
    Linux)
      export DISPLAY="${DISPLAY:-:0}"
      pids="$(pgrep -x zoom; pgrep -f '/opt/zoom/zoom')"
      [ -n "$pids" ] && wmctrl -lp | awk -v pids="^($(tr '\n' '|' <<<"$pids" | sed 's/|$//'))$" '$3 ~ pids { print $1 }' ;;
  esac
  exit 0
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
# not mapped a window yet) | "home-only" | "no-zoom".
mac_attempt() {
  osascript - "$WANT" "$PRIOR" <<'EOF'
on run argv
  set wantTitle to item 1 of argv
  set priorTitles to paragraphs of (item 2 of argv)
  tell application "System Events"
    if not (exists process "zoom.us") then return "no-zoom"
    tell process "zoom.us"
      if (count of windows) is 0 then return "starting"
      if wantTitle is not "" then
        repeat with w in windows
          try
            -- never accept the home/sign-in window even if the topic matches it
            if (name of w) contains wantTitle and (name of w) does not contain "Zoom Workplace" and priorTitles does not contain (name of w) then
              perform action "AXRaise" of w
              set frontmost to true
              return "raised " & (name of w)
            end if
          end try
        end repeat
      end if
      repeat with w in windows
        try
          set n to name of w
          if n does not contain "Zoom Workplace" and n does not contain "Settings" and priorTitles does not contain n then
            perform action "AXRaise" of w
            set frontmost to true
            return "raised " & n
          end if
        end try
      end repeat
      return "home-only"
    end tell
  end tell
end run
EOF
}

linux_attempt() {
  local pids rows found=""
  # find Zoom's windows by PID: the meeting window is titled after the meeting
  # topic ("Devin standup"), so anything that greps window titles for "zoom"
  # sees only the home window and never the meeting
  pids="$(pgrep -x zoom; pgrep -f '/opt/zoom/zoom')"
  [ -z "$pids" ] && { echo "no-zoom"; return; }
  rows="$(wmctrl -lp | awk -v pids="^($(tr '\n' '|' <<<"$pids" | sed 's/|$//'))$" \
    '$3 ~ pids { wid = $1; $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); if ($0 != "") print wid "\t" $0 }')"
  [ -z "$rows" ] && { echo "starting"; return; }
  pick() {  # $1 = title substring to prefer ("" = any non-home zoom window)
    local wid title
    while IFS=$'\t' read -r wid title; do
      case "$title" in *"Zoom Workplace"*|Settings) continue;; esac
      grep -qxF -- "$wid" <<<"$PRIOR" && continue
      [ -n "$1" ] && ! grep -qF -- "$1" <<<"$title" && continue
      wmctrl -i -a "$wid" && { found="$title"; return 0; }
    done <<<"$rows"
    return 1
  }
  # raise by window ID, never by title: wmctrl -a does its own substring match
  # and could pick the home window when both titles contain WANT
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

case "$(uname -s)" in
  Darwin) attempt() { mac_attempt; } ;;
  Linux)  export DISPLAY="${DISPLAY:-:0}"; attempt() { linux_attempt; } ;;
  *)
    echo "Windows: Start-Process \"zoommtg://...\" then WScript.Shell AppActivate (see SKILL.md §4)" >&2
    exit 1
    ;;
esac

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
