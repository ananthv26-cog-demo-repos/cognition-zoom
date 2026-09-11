#!/usr/bin/env bash
# show_meeting_window.sh — make sure the *meeting* window (join preview or the
# in-meeting window), not the "Zoom Workplace" sign-in home window, is on
# screen. Zoom always opens the home window alongside the deep link and it is
# a decoy: if you only see "Sign in"/"Join a meeting", you are NOT in the
# meeting. If no meeting window exists this re-fires the zoommtg:// deep link
# so the join preview comes up again.
#
#   scripts/show_meeting_window.sh "<join_url>" [window title substring] [display name]
# Pass the display name so a re-fired join keeps the roster identity.
# On Windows use the PowerShell equivalent in SKILL.md §4.
set -uo pipefail

URL="${1:?usage: show_meeting_window.sh <zoom url> [window title substring] [display name]}"
WANT="${2:-}"
NAME="${3:-}"

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

case "$(uname -s)" in
  Darwin)
    RESULT="$(osascript - "$WANT" <<'EOF'
on run argv
  set wantTitle to item 1 of argv
  tell application "System Events"
    if not (exists process "zoom.us") then return "no-zoom"
    tell process "zoom.us"
      if wantTitle is not "" then
        repeat with w in windows
          try
            -- never accept the home/sign-in window even if the topic matches it
            if (name of w) contains wantTitle and (name of w) does not contain "Zoom Workplace" then
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
          if n does not contain "Zoom Workplace" and n does not contain "Settings" then
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
)"
    echo "$RESULT"
    if [ "$RESULT" = "home-only" ] || [ "$RESULT" = "no-zoom" ]; then
      open "$(deep_link)"
      echo "re-fired join deep link for meeting $MEETING_ID"
    fi
    ;;
  Linux)
    export DISPLAY="${DISPLAY:-:0}"
    FOUND=""
    pick() {  # $1 = title substring to prefer ("" = any non-home zoom window)
      while IFS= read -r line; do
        local wid="${line%% *}" title="${line#* * * }"   # wmctrl -l: winid desktop host title
        case "$title" in *"Zoom Workplace"*) continue;; esac
        [ -n "$1" ] && ! grep -qF -- "$1" <<<"$title" && continue
        wmctrl -i -a "$wid" && { FOUND="$title"; return 0; }
      done < <(wmctrl -l | grep -i zoom)
      return 1
    }
    # raise by window ID, never by title: wmctrl -a does its own substring match
    # and could pick the home window when both titles contain WANT
    pick "$WANT" || pick ""
    if [ -z "$FOUND" ]; then
      nohup /usr/bin/zoom "$(deep_link)" >"$HOME/zoom-desktop.log" 2>&1 &
      echo "re-fired join deep link for meeting $MEETING_ID"
    else
      echo "raised $FOUND"
    fi
    ;;
  *)
    echo "Windows: Start-Process \"zoommtg://...\" then WScript.Shell AppActivate (see SKILL.md §4)" >&2
    exit 1
    ;;
esac
