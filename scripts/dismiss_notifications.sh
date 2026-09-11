#!/usr/bin/env bash
# Close every macOS Notification Center banner/alert (e.g. "Zoom can run in the
# background", "Google Chrome Notifications" Allow/Don't Allow) so they do not
# cover the Zoom window during computer-use steps. Idempotent; no-op on Linux.
# Uses the Accessibility API, which the Devin macOS VM already grants.
set -uo pipefail
[ "$(uname -s)" = Darwin ] || exit 0

osascript <<'EOF'
tell application "System Events"
  if not (exists process "NotificationCenter") then return "no notification center"
  tell process "NotificationCenter"
    set closedCount to 0
    repeat 30 times
      set didClose to false
      repeat with i from 1 to (count of windows)
        set els to {}
        try
          set els to entire contents of window i
        end try
        repeat with el in els
          try
            if role of el is "AXGroup" then
              repeat with a in (actions of el)
                set nm to name of a as text
                -- names look like "Name:Close\nTarget:...", so match by substring
                if nm contains "Name:Close" or nm contains "Name:Clear All" or nm contains "Name:Don’t Allow" then
                  perform a
                  set closedCount to closedCount + 1
                  set didClose to true
                  exit repeat
                end if
              end repeat
            end if
          end try
          if didClose then exit repeat
        end repeat
        if didClose then exit repeat
      end repeat
      if not didClose then exit repeat
      delay 0.8
    end repeat
    return "closed " & closedCount & " notification(s)"
  end tell
end tell
EOF
