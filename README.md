# cognition-zoom

Tooling for the "N Devins on one Zoom call" demo: a parent Devin session creates a
host-less Zoom meeting through the Zoom REST API, then child sessions (Mac or Linux
VMs) join it as named guests through Zoom's web client.

## Layout

| Path | Purpose |
|------|---------|
| `scripts/zoom_meeting.py` | Server-to-Server OAuth token + `POST /users/{host}/meetings`; prints `join_url` and a direct web-client URL. `--delete ID` cleans up. |
| `scripts/join_zoom.sh` | Launches a plain Chrome (own profile, no automation flags) on a Zoom URL so the join is not blocked as a bot. |
| `.agents/skills/zoom-meeting/SKILL.md` | Step-by-step skill Devin sessions in this repo auto-load: create, hand off, join, set audio devices. |
| `docs/wispr-zoom-demo-feasibility.md` | Audio architecture for the Mac VMs (BlackHole, Wispr Flow, realtime voice). |

## Secrets

Personal Devin secrets (owner: Ananth): `ZOOM_S2S_ACCOUNT_ID`, `ZOOM_S2S_CLIENT_ID`,
`ZOOM_S2S_CLIENT_SECRET`, `ZOOM_HOST_EMAIL`. They belong to a Server-to-Server OAuth app
on a paid personal Zoom account with `meeting:write:meeting:admin` and
`meeting:read:meeting:admin` scopes. No Zoom accounts are needed for the joining Devins.

## Quick start

```bash
# parent
python3 scripts/zoom_meeting.py --topic "Devin standup" --duration 60 --json
# child
scripts/join_zoom.sh "https://app.zoom.us/wc/join/<id>?pwd=<encrypted_password>"
# then, via computer use: type display name -> Join
```

## Verified

- 2026-09-11, Linux Devin VM: meeting created via API with `join_before_host` and no
  waiting room; joined as "Devin 0" with nobody hosting. Devin's default Chrome was
  rejected by Zoom's bot check; a plain Chrome instance from `join_zoom.sh` joined.

## Not yet verified (first Mac spike)

- BlackHole enumerates in a Mac VM with no audio hardware.
- Web client device picker exposes BlackHole 2ch / 16ch (fallback: Zoom desktop client).
- Same bot-check behaviour for the Mac VM's default Chrome.
