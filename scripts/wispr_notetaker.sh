#!/usr/bin/env bash
# Wispr Flow Notetaker helpers for the macOS Devin VM. Opt-in: only run when the parent prompt says "wispr".
# Everything here was verified 2026-09-11 on two macOS 26.5 arm64 VMs (see SKILL.md §7); the login itself and
# the permission toggles are GUI steps and stay in the skill.
#
#   wispr_notetaker.sh install          brew casks (wispr-flow, google-chrome), Chrome as default browser,
#                                       click-to-show-desktop off. Idempotent; never launches Wispr.
#   wispr_notetaker.sh launch           open Wispr Flow (the app is not found by `open -a`, use the path)
#   wispr_notetaker.sh devices          system output AND input -> BlackHole 2ch (Notetaker follows the default input)
#   wispr_notetaker.sh authdb grant     back up + allow the authorization rights behind the Accessibility toggle
#   wispr_notetaker.sh authdb restore   put them back (run right after the toggle is on)
#   wispr_notetaker.sh layout           clean split screen: hide every other app, auto-hide the Dock, Zoom meeting
#                                       window exactly the left half, Wispr "Meeting Recorder" exactly the right
#                                       half, then verify both frames. Non-zero exit = not presentable.
#   wispr_notetaker.sh layout --verify  check the two frames only, change nothing
#   wispr_notetaker.sh status           is Wispr running, which windows, which permissions look granted
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "macOS only" >&2; exit 1; }

APP="/Applications/Wispr Flow.app"
# Root-owned (0700) so nothing running as the login user can swap a saved policy between grant and restore.
AUTHDB_DIR="${WISPR_AUTHDB_BACKUP_DIR:-/var/root/wispr_authdb_backup}"
# The Accessibility toggle in System Settings asks for the local account password. Allowing only
# system.preferences* does NOT stop the prompt on macOS 26 (authd logs com.apple.DiskManagement.reserveKEK);
# allowing this whole set did (Mac VM 2, 2026-09-11). Always restore afterwards.
AUTHDB_RIGHTS=(
  system.preferences
  system.preferences.security
  system.preferences.accessibility
  com.apple.tcc.util.admin
  com.apple.DiskManagement.reserveKEK
  system.services.directory.configure
  system.services.systemconfiguration.network
)

cmd_install() {
  if [ ! -d "$APP" ]; then
    echo "installing Wispr Flow cask (~50 s)"; brew install --cask wispr-flow
  else
    echo "Wispr Flow present"
  fi
  if [ ! -d "/Applications/Google Chrome.app" ]; then
    echo "installing Google Chrome cask (~30 s; Safari's hCaptcha never loads on the Wispr sign-in page)"
    brew install --cask google-chrome
  else
    echo "Google Chrome present"
  fi
  xattr -dr com.apple.quarantine "/Applications/Google Chrome.app" 2>/dev/null || true
  command -v defaultbrowser >/dev/null || brew install defaultbrowser
  # Wispr's "Sign in via browser" opens the *default* browser; making it Chrome now avoids the Safari dead end.
  # macOS may confirm with a 'Use "Chrome"' dialog: click it (or System Settings > Desktop & Dock > Default web browser).
  defaultbrowser chrome || true
  echo "default browser: $(defaultbrowser 2>/dev/null | grep '^\*' || echo unknown) (if a 'Use Chrome' dialog is up, click it)"
  # Wispr's toasts do not take virtual-mouse clicks reliably; a missed click lands on the wallpaper and
  # macOS 26 then hides every window ("click to show desktop"). Turn that off.
  defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false
  echo "click-to-show-desktop off"
}

cmd_launch() {
  [ -d "$APP" ] || { echo "Wispr Flow not installed; run: $0 install" >&2; exit 1; }
  open "$APP"
  echo "Wispr Flow opened; sign in with 'Sign in via browser' -> Continue with Google (see SKILL.md §7)"
}

cmd_devices() {
  command -v SwitchAudioSource >/dev/null || brew install switchaudio-osx
  SwitchAudioSource -s "BlackHole 2ch"
  SwitchAudioSource -t input -s "BlackHole 2ch"
  echo "output: $(SwitchAudioSource -c)  input: $(SwitchAudioSource -c -t input)"
}

cmd_authdb() {
  case "${1:-}" in
    grant)
      if sudo test -e "$AUTHDB_DIR"; then
        echo "a grant is already pending ($AUTHDB_DIR exists); run: $0 authdb restore" >&2; exit 1
      fi
      sudo install -d -m 0700 -o root -g wheel "$AUTHDB_DIR"
      for r in "${AUTHDB_RIGHTS[@]}"; do
        sudo security authorizationdb read "$r" 2>/dev/null | sudo tee "$AUTHDB_DIR/$r.plist" >/dev/null || true
        sudo test -s "$AUTHDB_DIR/$r.plist" || sudo rm -f "$AUTHDB_DIR/$r.plist"  # right did not exist: restore removes it
        sudo security authorizationdb write "$r" allow
      done
      echo "granted; flip System Settings > Privacy & Security > Accessibility > Wispr Flow, then: $0 authdb restore"
      ;;
    restore)
      sudo test -d "$AUTHDB_DIR" || { echo "nothing to restore: no pending grant in $AUTHDB_DIR" >&2; exit 1; }
      for r in "${AUTHDB_RIGHTS[@]}"; do
        if sudo test -s "$AUTHDB_DIR/$r.plist"; then
          sudo sh -c 'security authorizationdb write "$1" < "$2"' _ "$r" "$AUTHDB_DIR/$r.plist"
        else
          sudo security authorizationdb remove "$r" 2>/dev/null || true
        fi
      done
      sudo rm -rf "$AUTHDB_DIR"
      echo "authorization rights restored; backup consumed"
      ;;
    *) echo "usage: $0 authdb grant|restore" >&2; exit 2 ;;
  esac
}

# Anything that is not Zoom or Wispr has to be off screen: a Chrome window or a strip of wallpaper between the
# two halves is what makes a recording look unfinished. Hiding is reversible and closes nothing.
hide_others() {
  osascript <<'EOF' >/dev/null 2>&1 || true
tell application "System Events"
  repeat with p in (every process whose visible is true and background only is false)
    if name of p is not in {"zoom.us", "Wispr Flow", "Finder"} then
      try
        set visible of p to false
      end try
    end if
  end repeat
end tell
EOF
  # The Dock sits on top of the bottom of both tiles; auto-hide gives them the full height.
  defaults write com.apple.dock autohide -bool true >/dev/null 2>&1 || true
  killall Dock >/dev/null 2>&1 || true
}

# "x y w h" of a window, empty when the window is not there.
win_frame() {
  osascript - "$1" "$2" <<'EOF' 2>/dev/null
on run argv
  tell application "System Events" to tell process (item 1 of argv) to tell (first window whose name is (item 2 of argv))
    set p to position
    set s to size
  end tell
  return ((item 1 of p) as text) & " " & ((item 2 of p) as text) & " " & ((item 1 of s) as text) & " " & ((item 2 of s) as text)
end run
EOF
}

# Separate `set position` / `set size` statements: the combined `set {position, size}` form fails with -10003.
# Applied twice: the first resize is clamped while the window is still laying out.
set_frame() {
  osascript - "$1" "$2" "$3" "$4" "$5" "$6" <<'EOF' >/dev/null 2>&1
on run argv
  set {pname, wname} to {item 1 of argv, item 2 of argv}
  set {x, y, w, h} to {(item 3 of argv) as integer, (item 4 of argv) as integer, (item 5 of argv) as integer, (item 6 of argv) as integer}
  tell application "System Events" to tell process pname to tell (first window whose name is wname)
    repeat 2 times
      set position to {x, y}
      set size to {w, h}
    end repeat
  end tell
end run
EOF
}

# A tile off by more than this many pixels leaves a seam that is visible in screenshots and recordings.
LAYOUT_TOLERANCE=${LAYOUT_TOLERANCE:-6}

check_tile() {
  local label=$1 pname=$2 wname=$3 x=$4 y=$5 w=$6 h=$7 frame d off=0
  frame=$(win_frame "$pname" "$wname")
  if [ -z "$frame" ]; then
    echo "FAIL $label: no \"$wname\" window in $pname" >&2
    return 1
  fi
  # shellcheck disable=SC2086
  set -- $frame
  for d in $(($1 - x)) $(($2 - y)) $(($3 - w)) $(($4 - h)); do
    [ "${d#-}" -le "$LAYOUT_TOLERANCE" ] || off=1
  done
  if [ "$off" = 1 ]; then
    echo "FAIL $label: at $1,$2 ${3}x${4}, expected $x,$y ${w}x${h}" >&2
    return 1
  fi
  echo "ok $label: $1,$2 ${3}x${4}"
}

cmd_layout() {
  local verify_only=0 bounds w h half top rc=0
  [ "${1:-}" = --verify ] && verify_only=1
  bounds=$(osascript -e 'tell application "Finder" to get bounds of window of desktop')
  w=$(echo "$bounds" | awk -F', ' '{print $3}'); h=$(echo "$bounds" | awk -F', ' '{print $4}')
  half=$((w / 2)); top=25  # menu bar
  if [ "$verify_only" = 0 ]; then
    hide_others
    set_frame "zoom.us" "Zoom Meeting" 0 "$top" "$half" $((h - top))
    set_frame "Wispr Flow" "Meeting Recorder" "$half" "$top" "$half" $((h - top))
  fi
  check_tile "zoom (left half)" "zoom.us" "Zoom Meeting" 0 "$top" "$half" $((h - top)) || rc=1
  check_tile "wispr (right half)" "Wispr Flow" "Meeting Recorder" "$half" "$top" "$half" $((h - top)) || rc=1
  if [ "$rc" != 0 ]; then
    echo "split screen is NOT clean (screen ${w}x${h}) - do not record yet. Fix the offending window by hand:" >&2
    echo "hover its green button > Tile Window to Left/Right of Screen (or drag-resize), then: $0 layout --verify" >&2
    return 1
  fi
  echo "layout: clean split, Zoom left / Wispr right (screen ${w}x${h}) - now screenshot to confirm nothing shows behind"
}

cmd_status() {
  echo "app: $([ -d "$APP" ] && echo installed || echo missing)"
  pgrep -xq "Wispr Flow" && echo "process: running" || echo "process: not running"
  osascript -e 'tell application "System Events" to tell process "Wispr Flow" to get name of windows' 2>/dev/null \
    | sed 's/^/windows: /' || true
  echo "default output: $(SwitchAudioSource -c 2>/dev/null || echo '?')  input: $(SwitchAudioSource -c -t input 2>/dev/null || echo '?')"
  echo "notes db: $([ -f "$HOME/Library/Application Support/Wispr Flow/flow.sqlite" ] && echo present || echo none)"
}

case "${1:-}" in
  install) cmd_install ;;
  launch) cmd_launch ;;
  devices) cmd_devices ;;
  authdb) shift; cmd_authdb "$@" ;;
  layout) shift; cmd_layout "$@" ;;
  status) cmd_status ;;
  *) sed -n '2,16p' "$0" >&2; exit 2 ;;
esac
