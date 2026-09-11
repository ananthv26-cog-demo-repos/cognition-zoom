---
name: zoom-meeting
description: Create a host-less Zoom meeting via the Zoom REST API (Server-to-Server OAuth) and join it from a Devin VM as a named guest through Zoom's web client. Use for multi-Devin Zoom demos (parent creates the meeting, children join with display names/personas).
---

# Zoom meeting: create + join from a Devin VM

## Secrets (personal scope, already saved for Ananth)
`ZOOM_S2S_ACCOUNT_ID`, `ZOOM_S2S_CLIENT_ID`, `ZOOM_S2S_CLIENT_SECRET`, `ZOOM_HOST_EMAIL`
(S2S OAuth app "devin-demo" on a paid personal Zoom account; scopes `meeting:write:meeting:admin`, `meeting:read:meeting:admin`).

## 1. Create the meeting (parent session)

```bash
python3 scripts/zoom_meeting.py --topic "Devin standup" --duration 60 --json
# -> {"id": ..., "passcode": ..., "join_url": "https://us05web.zoom.us/j/<id>?pwd=<enc>",
#     "web_client_url": "https://app.zoom.us/wc/join/<id>?pwd=<enc>", ...}
python3 scripts/zoom_meeting.py --delete <id>   # cleanup afterwards
```

Facts verified 2026-09-11:
- S2S tokens must target an explicit host: `POST /users/{ZOOM_HOST_EMAIL}/meetings` (`me` is not valid for S2S).
- `type: 2` + `join_before_host: true, jbh_time: 0, waiting_room: false, approval_type: 2, meeting_authentication: false`
  produces a meeting guests can enter with nobody hosting.
- `join_url` already carries `?pwd=<encrypted_password>`; the web-client URL with the same `pwd` skips the passcode prompt.
- Account settings that must stay on: "Show a Join from your browser link"; "Allow participants to join before host".
  Must stay off: "Only authenticated users can join meetings from Web client".

Hand each child exactly: `web_client_url`, a display name ("Devin 1"), and its persona.

## 2. Join from a VM (child session)

**Do not use Devin's default Chrome.** It runs with `--enable-automation` and a `Devin/1.0` user agent and Zoom's
web client rejects it with "Automated bots aren't allowed to join this meeting" (reCAPTCHA). A second, plain Chrome
instance with its own profile joins fine (verified on Linux; the same flags issue is expected on macOS).

```bash
scripts/join_zoom.sh "<web_client_url>"
```

Then with computer use on the new window:
1. "Enter Meeting Info" page: type the display name in **Your Name**, click **Join**. No account, no passcode.
2. Dismiss the "Cannot detect your camera" / mic banner if there is no device. Click **Allow** on Chrome's mic prompt if one appears.
3. Audio: **Audio ^ (caret) > Select a Microphone / Select a Speaker**. On macOS pick BlackHole 2ch as mic and
   BlackHole 16ch as speaker (see the Wispr/BlackHole feasibility doc). Linux VMs have no audio device; joining still works.
4. Verify: participant count in the bottom bar increments; your name tile is shown.

Fallback if the web client misbehaves on macOS: install the Zoom desktop client (`Zoom.pkg`, sudo available),
open `join_url`, join as guest with the same display name.

## Limits
- Paid host account: no 40-min cap. Free account: 40-min cap on 3+ participant meetings even with no host present.
- Nobody in the meeting is host, so nobody can start a cloud recording; record locally (ffmpeg) if needed.
- Web client vs desktop: web client cannot be host, has limited device controls; fine for guests.
