# cognition-zoom

Tooling for the "N Devins on one Zoom call" demo: a parent Devin session creates a
host-less Zoom meeting through the Zoom REST API, then child sessions (Mac or Linux
VMs) join it as named guests through the Zoom desktop app (web client as fallback).

## Layout

| Path | Purpose |
|------|---------|
| `scripts/zoom_meeting.py` | Server-to-Server OAuth token + `POST /users/{host}/meetings`; prints `join_url`, a web-client URL and a `zoommtg://` deep link. `--end ID` ends it when the demo is over; `--list-live`, `--delete ID` (each needs its scope, see Secrets). |
| `scripts/join_zoom.sh` | `join_zoom.sh <url> [display name]`. Zoom desktop app via `zoommtg://` when installed (macOS: app matches `uname -m`; Linux: `/usr/bin/zoom`), else a plain Chrome (own profile, no automation flags, so the join is not blocked as a bot). `ZOOM_JOIN_MODE=desktop|chrome|safari` overrides. |
| `scripts/linux_audio.sh` | Linux BlackHole equivalent: PulseAudio null sinks `DevinMic` (play TTS here) + `ZoomOut` (Zoom speaker) and remap source `DevinMicSrc` (Zoom mic). Idempotent; `join_zoom.sh` runs it before the desktop app. |
| `scripts/speak.py` | `speak.py "text"`: ElevenLabs TTS (natural voice, `--voice Roger`, `--list-voices`) played into the Zoom mic (`paplay --device=devin_mic` on Linux, `afplay` with system output = BlackHole 2ch on macOS). Falls back to `say -a "BlackHole 2ch"` / `espeak-ng` without `ELEVENLABS_API_KEY`. `--if-quiet` waits for a gap in the meeting audio (random 0.5-2 s, backs off if someone else starts). |
| `scripts/listen.py` | `listen.py --seconds 15`: records what the meeting says (`zoom_out.monitor` on Linux, `BlackHole 16ch` via ffmpeg on macOS) and transcribes it with ElevenLabs Scribe, `keyterms` biased to "Devin" so names come back right. `--json` gives words + `speaker_id`. `--until-silence 2` blocks until the current speaker has paused for 2 s (turn-taking). |
| `scripts/dismiss_notifications.sh` | macOS: closes every Notification Center banner (Zoom background-activity, Chrome notification prompts) via Accessibility so they do not cover the Zoom window. Run by `join_zoom.sh`; rerun whenever a banner shows up. |
| `.agents/skills/zoom-meeting/SKILL.md` | Step-by-step skill Devin sessions in this repo auto-load: create, hand off, join, set audio devices. |
| `docs/wispr-zoom-demo-feasibility.md` | Audio architecture for the Mac VMs (BlackHole, Wispr Flow, realtime voice). |
| `docs/gotchas.md` | Every symptom -> cause -> fix we hit (API scopes, bot check, arm64 pkg, monitor-source remap, echo loop, notifications...). Read before debugging. |

## Secrets

Personal Devin secrets (owner: Ananth): `ZOOM_S2S_ACCOUNT_ID`, `ZOOM_S2S_CLIENT_ID`,
`ZOOM_S2S_CLIENT_SECRET`, `ZOOM_HOST_EMAIL`. They belong to a Server-to-Server OAuth app
on a paid personal Zoom account with `meeting:write:meeting:admin` and
`meeting:read:meeting:admin` scopes (create). `--end`, `--delete` and `--list-live` also need
`meeting:update:status:admin`, `meeting:delete:meeting:admin` and
`meeting:read:list_meetings:admin`. No Zoom accounts are needed for the joining Devins.

`ELEVENLABS_API_KEY` (personal, owner: Ananth; key restricted to Text to Speech, Speech to Text,
Voices read, Models) powers `speak.py` / `listen.py`. Without it `speak.py` falls back to the OS voice;
`listen.py` exits up front (no offline STT).

## Quick start

```bash
# parent
python3 scripts/zoom_meeting.py --topic "Devin standup" --duration 60 --json
# child (macOS): desktop app, name pre-filled; then computer use: Join
SwitchAudioSource -s "BlackHole 2ch"
scripts/join_zoom.sh "https://app.zoom.us/wc/join/<id>?pwd=<encrypted_password>" "Devin 1"
# child (Linux): desktop app, name pre-filled, mic=DevinMicSrc speaker=ZoomOut; then computer use: Join
scripts/join_zoom.sh "https://app.zoom.us/wc/join/<id>?pwd=<encrypted_password>" "Devin 2"
PULSE_SINK=devin_mic espeak-ng "Hello from Devin two"     # or: paplay --device=devin_mic tts.wav
# any participant: natural voice in, transcript out (needs ELEVENLABS_API_KEY)
scripts/speak.py --voice Roger "Hi everyone, Devin 2 here."
scripts/listen.py --seconds 15
# parent, when done
python3 scripts/zoom_meeting.py --end <id>
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
- 2026-09-11, Linux Devin VM (Ubuntu 22.04.5, x86_64, no audio hardware), Zoom desktop app:

  | Command | Result | Time |
  |---------|--------|------|
  | `curl -sL -o zoom_amd64.deb https://zoom.us/client/latest/zoom_amd64.deb` (297 MB) + `sudo apt-get install -y ./zoom_amd64.deb` | ok, Zoom Workplace 7.1.5.4332 at `/usr/bin/zoom` | ~10 s + 29 s |
  | `sudo apt-get install -y pulseaudio pulseaudio-utils espeak-ng` | ok (`pactl` was absent before) | ~20 s |
  | `scripts/linux_audio.sh` | sinks `devin_mic`, `zoom_out`; sources `devin_mic.monitor`, `devin_mic_src`; idempotent, also after `pulseaudio --kill` | <1 s |
  | `scripts/join_zoom.sh <join_url> "Devin 2"` | desktop preview with name pre-filled, joins as guest; **Audio ^** lists mic `DevinMicSrc`, speakers `DevinMic`/`ZoomOut`; the choice is remembered ("Custom audio combination") | ~10 s to preview |
  | `PULSE_SINK=devin_mic espeak-ng "Hello from Devin on Linux..."` and `paplay --device=devin_mic tts.wav` | **More > Show captions transcribes both** (robotic espeak voice -> "Bevin", "roundbox"; fine for proof, use a real TTS for the demo) | — |
  | `python3 scripts/zoom_meeting.py --list-live` / `--end <id>` | ok once the three management scopes were added to the S2S app | 1 s |

  Gotcha: Zoom's Linux client does not list PulseAudio `*.monitor` sources as microphones
  ("Zoom cannot detect your microphone"); the `module-remap-source` over `devin_mic.monitor`
  in `linux_audio.sh` is what makes `DevinMicSrc` appear. Devices added while Zoom is running
  do show up in the picker.
- 2026-09-11, **3 macOS Devin VMs in one meeting** (parent on Linux as "Observer", one meeting from
  the API, three child sessions from the macOS snapshot with Zoom + BlackHole preinstalled):

  | Check | Result |
  |-------|--------|
  | Roster | `Observer`, `Devin 1`, `Devin 2`, `Devin 3`, each a separate guest, no Zoom accounts |
  | Time from session start to "in meeting" | 72 s / 108 s / 146 s |
  | Devices | mic = BlackHole 2ch, speaker = BlackHole 16ch on all three (Zoom defaulted the speaker to 2ch once; pick 16ch by hand) |
  | Speech | `say -a "BlackHole 2ch"` on each Mac; plain `say` was **not** heard until `-a` (or `SwitchAudioSource -s "BlackHole 2ch"`) |
  | Captions | speaker-attributed on every VM ("Devin 1: Quick round of status updates...", "Devin 2: ... Zoom API backend reporting in", "Devin 3: Nothing blocking me") |
  | Turn-taking | scripted stagger (Devin n waits (n-1) x 25 s after the roster is complete); no overlap |
  | Name spelling | Zoom's own captions wrote "Devon 1" / "Kevin 3" for `say`, and still "Devon" for an ElevenLabs voice; `listen.py` (Scribe + keyterms) returned "Devin" every time |
  | `speak.py` (ElevenLabs, Roger) from the Observer | heard by the meeting, captioned |
  | `listen.py --seconds 75` on the Observer | transcribed a Devin's line from `zoom_out.monitor` |
