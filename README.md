# cognition-zoom

Tooling for the "N Devins on one Zoom call" demo: a parent Devin session creates a
host-less Zoom meeting through the Zoom REST API, then child sessions (Mac or Linux
VMs) join it as named guests — the Zoom desktop app on macOS, Zoom's web client on Linux.

## Layout

| Path | Purpose |
|------|---------|
| `scripts/zoom_meeting.py` | Server-to-Server OAuth token + `POST /users/{host}/meetings`; prints `join_url`, a web-client URL and a `zoommtg://` deep link. `--end ID` ends it when the demo is over; `--list-live`, `--delete ID` (each needs its scope, see Secrets). |
| `scripts/join_zoom.sh` | `join_zoom.sh <url> [display name]`. macOS: Zoom desktop app via `zoommtg://` (default when the app matches `uname -m`), or `ZOOM_JOIN_MODE=safari|chrome` for the web client. Linux: plain Chrome (own profile, no automation flags) so the join is not blocked as a bot. |
| `scripts/dismiss_notifications.sh` | macOS: closes every Notification Center banner (Zoom background-activity, Chrome notification prompts) via Accessibility so they do not cover the Zoom window. Run by `join_zoom.sh`; rerun whenever a banner shows up. |
| `.agents/skills/zoom-meeting/SKILL.md` | Step-by-step skill Devin sessions in this repo auto-load: create, hand off, join, set audio devices. |
| `docs/wispr-zoom-demo-feasibility.md` | Audio architecture for the Mac VMs (BlackHole, Wispr Flow, realtime voice). |

## Secrets

Personal Devin secrets (owner: Ananth): `ZOOM_S2S_ACCOUNT_ID`, `ZOOM_S2S_CLIENT_ID`,
`ZOOM_S2S_CLIENT_SECRET`, `ZOOM_HOST_EMAIL`. They belong to a Server-to-Server OAuth app
on a paid personal Zoom account with `meeting:write:meeting:admin` and
`meeting:read:meeting:admin` scopes (create). `--end`, `--delete` and `--list-live` also need
`meeting:update:status:admin`, `meeting:delete:meeting:admin` and
`meeting:read:list_meetings:admin`. No Zoom accounts are needed for the joining Devins.

## Quick start

```bash
# parent
python3 scripts/zoom_meeting.py --topic "Devin standup" --duration 60 --json
# child (macOS): desktop app, name pre-filled; then computer use: Join
SwitchAudioSource -s "BlackHole 2ch"
scripts/join_zoom.sh "https://app.zoom.us/wc/join/<id>?pwd=<encrypted_password>" "Devin 1"
# child (Linux): plain Chrome; then computer use: type display name -> Join
scripts/join_zoom.sh "https://app.zoom.us/wc/join/<id>?pwd=<encrypted_password>"
```

## Verified

- 2026-09-11, Linux Devin VM: meeting created via API with `join_before_host` and no
  waiting room; joined as "Devin 0" with nobody hosting. Devin's default Chrome was
  rejected by Zoom's bot check; a plain Chrome instance from `join_zoom.sh` joined.
- 2026-09-11, macOS 26.5 arm64 Devin VM (no audio hardware, BlackHole 2ch preinstalled):

  | Command | Result | Time |
  |---------|--------|------|
  | `system_profiler SPAudioDataType` (baseline) | 1 device: `BlackHole 2ch` (already installed via cask) | 10 s |
  | `brew install --cask blackhole-2ch blackhole-16ch` | ok; 16ch installs, says "reboot" | 41 s |
  | `sudo killall coreaudiod` then `system_profiler SPAudioDataType` | `BlackHole 16ch` + `BlackHole 2ch` enumerated, no reboot | 6 s |
  | `python3 scripts/zoom_meeting.py --topic "Mac spike" --duration 60 --json` | ok on system python 3.9 (after `from __future__ import annotations` fix) | 2 s |
  | `brew install --cask google-chrome` | ok, `/Applications/Google Chrome.app` | 28 s |
  | `scripts/join_zoom.sh <web_client_url>` (plain Chrome) | joined as guest, **no bot block**; mic/speaker lists show `BlackHole 2ch (Virtual)` / `BlackHole 16ch (Virtual)`; mic level lights up on `say` | — |
  | `open -a Safari <web_client_url>` | joined as guest, no bot block; mic list `BlackHole 2ch`/`BlackHole 16ch`, speaker only `Same as System`; no mic level seen on `say` | — |
  | `brew install switchaudio-osx` + `SwitchAudioSource -s "BlackHole 2ch"` | ok (already installed) | 1 s |
  | `curl -L -o Zoom.pkg https://zoom.us/client/latest/Zoom.pkg` + `sudo installer -pkg Zoom.pkg -target /` | installs but **x86_64-only**; `open` fails with error -10669 ("Bad CPU type") | 1 s + 6 s |
  | `curl -sL -o Zoom-arm64.pkg "https://zoom.us/client/latest/Zoom.pkg?archType=arm64"` + `sudo installer -pkg Zoom-arm64.pkg -target /` | ok, arm64 `/Applications/zoom.us.app` (Zoom Workplace 7.1.5) | <1 s + 4 s |
  | `scripts/dismiss_notifications.sh` | closed 3 + 1 banners (Zoom background activity, 2x Chrome notifications) in ~1.5 s, no permission prompt | 2 s |
  | `open "zoommtg://zoom.us/join?confno=<id>&pwd=<enc>&uname=Devin%201b"` | desktop app opens preview with name, joins as guest; device picker lists BlackHole 2ch/16ch; **live captions transcribe `say`** | — |
  | `python3 scripts/zoom_meeting.py --delete <id>` | not run: fails with 400/4711 while scope `meeting:delete:meeting:admin` is missing (use `--end` once its scope is granted) | — |

  Also observed: "The host has another meeting in progress" while a previous meeting on the
  host account was still live (one concurrent meeting per host); it cleared by itself.
