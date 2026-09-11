---
name: zoom-meeting
description: Create a host-less Zoom meeting via the Zoom REST API (Server-to-Server OAuth) and join it from a Devin VM as a named guest (Zoom desktop app on macOS, plain Chrome on Linux). Use for multi-Devin Zoom demos (parent creates the meeting, children join with display names/personas and BlackHole audio).
---

# Zoom meeting: create + join from a Devin VM

## Secrets (personal scope, already saved for Ananth)
`ZOOM_S2S_ACCOUNT_ID`, `ZOOM_S2S_CLIENT_ID`, `ZOOM_S2S_CLIENT_SECRET`, `ZOOM_HOST_EMAIL`
(S2S OAuth app "devin-demo" on a paid personal Zoom account; scopes `meeting:write:meeting:admin`, `meeting:read:meeting:admin`;
`--end` / `--delete` / `--list-live` additionally need `meeting:update:status:admin` / `meeting:delete:meeting:admin` / `meeting:read:list_meetings:admin`).

## 1. Create the meeting (parent session)

```bash
python3 scripts/zoom_meeting.py --topic "Devin standup" --duration 60 --json
# -> {"id": ..., "passcode": ..., "join_url": "https://us05web.zoom.us/j/<id>?pwd=<enc>",
#     "web_client_url": "https://app.zoom.us/wc/join/<id>?pwd=<enc>",
#     "zoommtg_url": "zoommtg://zoom.us/join?confno=<id>&pwd=<enc>", ...}
python3 scripts/zoom_meeting.py --end <id>      # when the demo is over (see below)
python3 scripts/zoom_meeting.py --list-live     # find stragglers
```

Always `--end` the meeting when done: a join-before-host meeting stays "in progress" while any
guest is connected, and the host account then rejects joins to any other meeting
("The host has another meeting in progress"). A blocked join = a Devin is still sitting in an
old meeting; end it or have that session leave.

Facts verified 2026-09-11:
- S2S tokens must target an explicit host: `POST /users/{ZOOM_HOST_EMAIL}/meetings` (`me` is not valid for S2S).
- `type: 2` + `join_before_host: true, jbh_time: 0, waiting_room: false, approval_type: 2, meeting_authentication: false`
  produces a meeting guests can enter with nobody hosting.
- `join_url` already carries `?pwd=<encrypted_password>`; the web-client URL with the same `pwd` skips the passcode prompt.
- Account settings that must stay on: "Show a Join from your browser link"; "Allow participants to join before host".
  Must stay off: "Only authenticated users can join meetings from Web client".
- Management calls fail with HTTP 400 code 4711 when the matching scope is not granted on the app
  (`--delete` did on 2026-09-11: `meeting:delete:meeting:admin` missing). Then just let the meeting expire.
- **One live meeting per host.** While a previous join-before-host meeting on the same account is still "in
  progress", joining a new one shows "The host has another meeting in progress" with an auto-retry countdown.
  All Devins must join the *same* meeting; do not create one per child. It clears when the old meeting ends.
- The script runs on the macOS system `python3` (3.9) and on Linux.

Hand each child exactly: the meeting `id` + `pwd` (or the URLs above), a display name ("Devin 1"), and its persona.

## 2. Join from a macOS VM (child session) — verified 2026-09-11, macOS 26.5 arm64 Devin VM

Preferred path: **Zoom desktop app** (guest, no sign-in). BlackHole shows up in every device picker and live
captions transcribe `say` output, which proves the mic path end to end.

```bash
# one-time setup (also in the blueprint)
brew install --cask blackhole-2ch blackhole-16ch      # ~41 s; "reboot" caveat is not needed:
sudo killall coreaudiod                                #   both devices enumerate after this
system_profiler SPAudioDataType                        # lists "BlackHole 16ch" and "BlackHole 2ch"
brew install switchaudio-osx
curl -sL -o ~/Zoom-arm64.pkg "https://zoom.us/client/latest/Zoom.pkg?archType=arm64"
sudo installer -pkg ~/Zoom-arm64.pkg -target /         # ~5 s -> /Applications/zoom.us.app

# per meeting
SwitchAudioSource -s "BlackHole 2ch"                   # system output -> Zoom mic
scripts/join_zoom.sh "<web_client_url_or_join_url>" "Devin 1"
# = open "zoommtg://zoom.us/join?confno=<id>&pwd=<enc>&uname=Devin%201"
```

Then with computer use:
1. Preview window shows the pre-filled name; dismiss the "update being installed" dialog (**Not Now**), click **Join**.
   macOS TCC asks "devin-remote would like to access the Microphone" the first time -> **Allow**.
2. **Audio ^ > Select a microphone**: `Same as system (BlackHole 2ch)`, `BlackHole 2ch`, `BlackHole 16ch`;
   **Select a speaker**: same three. Pick mic = BlackHole 2ch, speaker = BlackHole 16ch (Zoom remembers it as
   "Custom combination" on the next join).
3. Speak: `say "Hello from Devin one"` while the system default output is BlackHole 2ch.
   **More (…) > Show captions** turns on live captions without host involvement and transcribes the `say` text
   (verified: "Hello from Devon1, Testing Captions").
4. Leave: hover the window, **Leave > Leave meeting**, then `pkill -x zoom.us`.

Gotchas:
- `https://zoom.us/client/latest/Zoom.pkg` (no `archType`) is an **x86_64-only** build; on the arm64 VM `open`
  fails with `_LSOpenURLsWithCompletionHandler() failed ... error -10669` and the binary says "Bad CPU type".
  Use `?archType=arm64` (or install Rosetta).
- Prefer `--end` over `--delete` for cleanup; both need their scope on the app (400/4711 otherwise).

### Web client alternatives on macOS (both verified, no bot block)
- **Plain Chrome** (`brew install --cask google-chrome`, ~28 s; `ZOOM_JOIN_MODE=chrome scripts/join_zoom.sh <web_client_url>`):
  joins as guest. Mic list: `Default - BlackHole 2ch (Virtual)`, `BlackHole 16ch (Virtual)`, `BlackHole 2ch (Virtual)`;
  speaker list: same. Mic icon shows a green level while `say` plays. Chrome prompts for mic permission once
  (**Allow**) after the macOS TCC prompt.
- **Safari** (`ZOOM_JOIN_MODE=safari scripts/join_zoom.sh <web_client_url>`): joins as guest. Mic list:
  `BlackHole 2ch`, `BlackHole 16ch`; speaker list: **only `Same as System`** (use `SwitchAudioSource` for output).
  The mic level meter did *not* move while `say` played in this spike (Test Speaker & Microphone showed a flat
  input bar), so treat Safari as join-only until re-tested.
- There is no Devin-default Chrome on the macOS VM (no Chrome preinstalled), so the Linux "Automated bots aren't
  allowed" bot check has no macOS equivalent to hit.

## 3. Join from a Linux VM (child session)

**Do not use Devin's default Chrome.** It runs with `--enable-automation` and a `Devin/1.0` user agent and Zoom's
web client rejects it with "Automated bots aren't allowed to join this meeting" (reCAPTCHA). A second, plain Chrome
instance with its own profile joins fine.

```bash
scripts/join_zoom.sh "<web_client_url>"
```

Then with computer use on the new window:
1. "Enter Meeting Info" page: type the display name in **Your Name**, click **Join**. No account, no passcode.
2. Dismiss the "Cannot detect your camera" / mic banner if there is no device. Click **Allow** on Chrome's mic prompt if one appears.
3. Linux VMs have no audio device; joining still works.
4. Verify: participant count in the bottom bar increments; your name tile is shown.

## Limits
- Paid host account: no 40-min cap. Free account: 40-min cap on 3+ participant meetings even with no host present.
- Nobody in the meeting is host, so nobody can start a cloud recording; record locally if needed.
- Web client vs desktop: web client cannot be host and has limited device controls (Safari: no speaker choice).
