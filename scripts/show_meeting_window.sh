#!/usr/bin/env bash
# show_meeting_window.sh — make sure the *meeting* window (join preview or the
# in-meeting window), not the "Zoom Workplace" sign-in home window, is on
# screen. Zoom always opens the home window alongside the deep link and it is
# a decoy: if you only see "Sign in"/"Join a meeting", you are NOT in the
# meeting. If no meeting window exists this re-fires the zoommtg:// deep link
# so the join preview comes up again.
#
#   scripts/show_meeting_window.sh "<join_url>" [window title substring]
# On Windows use the PowerShell equivalent in SKILL.md §4.
set -uo pipefail

URL="${1:?usage: show_meeting_window.sh <zoom url> [window title substring]}"
WANT="${2:-}"

deep_link() {
  local id pwd_
  id="$(sed -E 's#.*/(j|join)/([0-9]+).*#\2#' <<<"$URL")"
  pwd_="$(sed -nE 's#.*[?&]pwd=([^&]+).*#\1#p' <<<"$URL")"
  [[ "$id" =~ ^[0-9]+$ ]] || { echo "cannot parse meeting id from $URL" >&2; exit 1; }
  echo "zoommtg://zoom.us/join?confno=${id}${pwd_:+&pwd=$pwd_}"
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
            if (name of w) contains wantTitle then
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
      DEEP="$(deep_link)"
      open "$DEEP"
      echo "re-fired $DEEP"
    fi
    ;;
  Linux)
    export DISPLAY="${DISPLAY:-:0}"
    FOUND=""
    if [ -n "$WANT" ] && wmctrl -l | grep -F "$WANT" >/dev/null; then
      wmctrl -a "$WANT"; FOUND="$WANT"
    else
      while IFS= read -r line; do
        title="${line#* devin-box }"
        case "$title" in *"Zoom Workplace"*) continue;; esac
        wmctrl -a "$title" && FOUND="$title" && break
      done < <(wmctrl -l | grep -i zoom)
    fi
    if [ -z "$FOUND" ]; then
      DEEP="$(deep_link)"
      nohup /usr/bin/zoom "$DEEP" >"$HOME/zoom-desktop.log" 2>&1 &
      echo "re-fired $DEEP"
    else
      echo "raised $FOUND"
    fi
    ;;
  *)
    echo "Windows: Start-Process \"zoommtg://...\" then WScript.Shell AppActivate (see SKILL.md §4)" >&2
    exit 1
    ;;
esac
