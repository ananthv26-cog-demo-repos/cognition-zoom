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
#   wispr_notetaker.sh layout           Zoom meeting window left half, Wispr "Meeting Recorder" right half
#   wispr_notetaker.sh status           is Wispr running, which windows, which permissions look granted
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "macOS only" >&2; exit 1; }

APP="/Applications/Wispr Flow.app"
AUTHDB_DIR="${WISPR_AUTHDB_BACKUP_DIR:-$HOME/.wispr_authdb_backup}"
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
      mkdir -p "$AUTHDB_DIR"
      for r in "${AUTHDB_RIGHTS[@]}"; do
        [ -s "$AUTHDB_DIR/$r.plist" ] || sudo security authorizationdb read "$r" > "$AUTHDB_DIR/$r.plist" 2>/dev/null || true
        sudo security authorizationdb write "$r" allow
      done
      echo "granted; flip System Settings > Privacy & Security > Accessibility > Wispr Flow, then: $0 authdb restore"
      ;;
    restore)
      for r in "${AUTHDB_RIGHTS[@]}"; do
        if [ -s "$AUTHDB_DIR/$r.plist" ]; then
          sudo security authorizationdb write "$r" < "$AUTHDB_DIR/$r.plist"
        else
          sudo security authorizationdb remove "$r" 2>/dev/null || true
        fi
      done
      echo "authorization rights restored from $AUTHDB_DIR"
      ;;
    *) echo "usage: $0 authdb grant|restore" >&2; exit 2 ;;
  esac
}

cmd_layout() {
  # Separate `set position` / `set size` statements: the combined `set {position, size}` form fails with -10003.
  local bounds w h half
  bounds=$(osascript -e 'tell application "Finder" to get bounds of window of desktop')
  w=$(echo "$bounds" | awk -F', ' '{print $3}'); h=$(echo "$bounds" | awk -F', ' '{print $4}')
  half=$((w / 2))
  osascript - "$half" "$h" <<'EOF' || echo "Zoom meeting window not positioned (is the meeting joined?)" >&2
on run argv
  set half to (item 1 of argv) as integer
  set h to (item 2 of argv) as integer
  tell application "System Events" to tell process "zoom.us" to tell (first window whose name is "Zoom Meeting")
    set position to {0, 25}
    set size to {half, h - 25}
  end tell
end run
EOF
  osascript - "$half" "$h" <<'EOF' || echo "Wispr 'Meeting Recorder' window not positioned (start a note first)" >&2
on run argv
  set half to (item 1 of argv) as integer
  set h to (item 2 of argv) as integer
  tell application "System Events" to tell process "Wispr Flow" to tell (first window whose name is "Meeting Recorder")
    set position to {half, 25}
    set size to {half, h - 25}
  end tell
end run
EOF
  echo "layout: Zoom left, Wispr right (${w}x${h})"
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
  layout) cmd_layout ;;
  status) cmd_status ;;
  *) sed -n '2,13p' "$0" >&2; exit 2 ;;
esac
