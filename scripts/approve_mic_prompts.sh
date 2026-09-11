#!/usr/bin/env bash
# approve_mic_prompts.sh — auto-click "Allow" on macOS TCC permission dialogs
# ("<proc> would like to access the Microphone" / Camera). The Zoom demo's mic
# path (say/afplay routed through devin-remote, or Zoom's own mic grant) raises
# this modal and it sits forever unless someone clicks it — this watcher clicks
# it so the demo never stalls.
#
#   scripts/approve_mic_prompts.sh          # watch for ~10 min, then exit
#   scripts/approve_mic_prompts.sh once     # single pass, then exit
#
# Safe to launch repeatedly: a lock dir makes it a singleton. join_zoom.sh
# starts it on macOS and speak.py re-arms it before every turn. Uses the same
# Accessibility API as dismiss_notifications.sh (already granted on Devin VMs).
# No-op on non-Darwin.
set -uo pipefail
[ "$(uname -s)" = Darwin ] || exit 0

approve_once() {
osascript <<'EOF'
tell application "System Events"
  set clicked to 0
  repeat with p in (every process)
    try
      tell p
        repeat with w in windows
          try
            set wt to name of w
            if wt contains "would like to access" then
              -- find the Allow button anywhere in the window's UI tree
              set els to {}
              try
                set els to entire contents of w
              end try
              repeat with el in els
                try
                  if role of el is "AXButton" and name of el is "Allow" then
                    perform action "AXPress" of el
                    set clicked to clicked + 1
                    exit repeat
                  end if
                end try
              end repeat
            end if
          end try
        end repeat
      end tell
    end try
  end repeat
  return clicked
EOF
}

if [ "${1:-}" = "once" ]; then
  approve_once
  exit 0
fi

LOCKDIR="${TMPDIR:-/tmp}/approve_mic_prompts.lock"
mkdir "$LOCKDIR" 2>/dev/null || exit 0   # already running
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

end=$((SECONDS + ${APPROVE_MIC_WATCH_SECONDS:-600}))
while [ "$SECONDS" -lt "$end" ]; do
  approve_once >/dev/null 2>&1 || true
  sleep 1
done
