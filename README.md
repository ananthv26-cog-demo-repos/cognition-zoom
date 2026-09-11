# cognition-zoom

Tooling for the "N Devins on one Zoom call" demo: a parent Devin session creates a
host-less Zoom meeting through the Zoom REST API, then child sessions (Mac, Linux or
Windows VMs) join it as named guests through the Zoom desktop app (web client as fallback).

## Layout

| Path | Purpose |
|------|---------|
| `scripts/zoom_meeting.py` | Server-to-Server OAuth token + `POST /users/{host}/meetings`; prints `join_url`, a web-client URL and a `zoommtg://` deep link. `--end ID` ends it when the demo is over; `--list-live`, `--delete ID` (each needs its scope, see Secrets). |
| `scripts/join_zoom.sh` | `join_zoom.sh <url> [display name]`. Zoom desktop app via `zoommtg://` when installed (macOS: app matches `uname -m`; Linux: `/usr/bin/zoom`), else a plain Chrome (own profile, no automation flags, so the join is not blocked as a bot). `ZOOM_JOIN_MODE=desktop|chrome|safari` overrides. |
| `scripts/linux_audio.sh` | Linux BlackHole equivalent: PulseAudio null sinks `DevinMic` (play TTS here) + `ZoomOut` (Zoom speaker) and remap source `DevinMicSrc` (Zoom mic). Idempotent; `join_zoom.sh` runs it before the desktop app. |
| `scripts/windows/vb-audio-driver-signer.cer` | VB-Audio's public code-signing certificate (exported from the Hi-Fi Cable driver `.cat`). `certutil -addstore TrustedPublisher` it so the Hi-Fi Cable driver installs without the "Windows Security" publisher dialog. Windows has no `join_zoom.sh`: the `zoommtg://` deep link is the whole join (skill section 4). |
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
# child (Windows, PowerShell): desktop app, name pre-filled, mic=CABLE Output speaker=Hi-Fi Cable Input; then computer use: Join
#   Start-Process "zoommtg://zoom.us/join?confno=<id>&pwd=<encrypted_password>&uname=Devin%20Win"
#   Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak("Hello from Devin Win")
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
- 2026-09-11, Windows Devin VM (Windows Server 2022 x64, no audio hardware, elevated shell,
  UAC off, no `winget`), Zoom desktop app. **No reboot was needed** at any step.

  | Command | Result | Time |
  |---------|--------|------|
  | `Get-CimInstance Win32_SoundDevice` / `Get-AudioDevice -List` (baseline) | no sound device, 0 endpoints; `Audiosrv` + `AudioEndpointBuilder` are **Stopped/Disabled** | 1 s |
  | `Set-Service Audiosrv -StartupType Automatic; Start-Service Audiosrv` (same for `AudioEndpointBuilder`) | ok; without this no virtual cable ever enumerates | <1 s |
  | `Install-Module AudioDeviceCmdlets -Force -Scope CurrentUser` | ok, `Get-AudioDevice`/`Set-AudioDevice` | 7 s |
  | `winget install --id VB-Audio.VBCable` | **`winget` is not installed** on Server 2022 | — |
  | `choco install vb-cable -y` | "installed" (driver pack 43) but `Get-AudioDevice -List` stays empty | ~20 s |
  | `curl.exe -sL -o VBCABLE_Driver_Pack45.zip https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip`, `Expand-Archive`, `VBCABLE_Setup_x64.exe -i -h` | ok: playback `CABLE Input`, `CABLE In 16ch`; recording `CABLE Output`, enumerated immediately, no reboot | 2 s + 9 s (1 s rerun) |
  | `HiFiCableAsioBridgeSetup.exe -i -h` (second cable, Zoom speaker) | first run stops on a "Windows Security" driver-publisher dialog (2015 signature); after `certutil -addstore TrustedPublisher scripts\windows\vb-audio-driver-signer.cer` it is silent: `Hi-Fi Cable Input`/`Output` | 1.5 s |
  | `curl.exe -sL -o ZoomInstallerFull.msi https://zoom.us/client/latest/ZoomInstallerFull.msi` + `msiexec /i ... /qn /norestart` | installs but **32-bit**: `C:\Program Files (x86)\Zoom\bin\Zoom.exe`, "upgrade to 64-bit" banner | 14 min (212 MB, throttled CDN) + 20 s |
  | `curl.exe -sL -o ZoomInstallerFull-x64.msi "https://zoom.us/client/latest/ZoomInstallerFull.msi?archType=x64"` + `msiexec /i ... /qn /norestart` | ok, Zoom Workplace 7.1.8 at `C:\Program Files\Zoom\bin\Zoom.exe` (x86 build replaced) | 7 s + 20 s (2 s rerun) |
  | `python scripts/zoom_meeting.py --topic "Windows spike" --duration 60 --json` | ok on the VM's Python 3.12 (`C:\devin\python`) | 2 s |
  | `Start-Process "zoommtg://zoom.us/join?confno=<id>&pwd=<enc>&uname=Devin%20Win"` | preview opens with **Devin Win** pre-filled, "No camera connected"; first showed "Allow Zoom Workplace to access your microphone" until the `ConsentStore\microphone` = `Allow` registry values were set. **Join** said "The host has another meeting in progress" for ~25 min (another Devin's meeting was live); Zoom retried by itself and **joined as guest `Devin Win`** the moment that meeting ended | 5 s to preview |
  | **Audio ^** in the meeting (also Settings > Audio from the preview) | microphone list `CABLE Output`, `Hi-Fi Cable Output`, `Same as system (CABLE Output)`; speaker list `CABLE Input`, `CABLE In 16ch`, `Hi-Fi Cable Input`, `Same as system (CABLE Input)`; picked mic = CABLE Output, speaker = Hi-Fi Cable Input, remembered on the next join | — |
  | `Set-AudioDevice -ID (... 'CABLE Input*').ID` then `Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak("Hello from Devin Windows, testing captions...")` | mic level meter lights up green for the phrase ("Microsoft David Desktop" voice); **More > Show captions transcribes it**: "Hello from Devon Windows, testing captions This is Devin Wynne speaking through the virtual cable" | 7 s for the 2-sentence phrase |
  | `Start-Process msedge "https://app.zoom.us/wc/join/<id>?pwd=<enc>"` (plain Edge, first launch) | Edge first-run wizard once; web client loads; Edge asks for camera+mic (needed `ConsentStore\webcam` = `Allow` too, else "give Edge access"); device picker lists **all four VB-Audio endpoints**; but **Join -> "Automated bots aren't allowed to join this meeting"** (reCAPTCHA) even in plain Edge, so no web-client join on Windows | 10 s |
  | `python scripts/zoom_meeting.py --list-live` / `--end <id>` | ok: `--list-live` showed the blocking meeting, later ours; `--end` ended it ("The host ended this meeting" in the desktop app), `--list-live` -> "no live meetings" | <1 s |

  Everything in the `runs-on: windows` blueprint document re-ran green end-to-end on this
  VM (~20 s). Gotcha: `HiFiCableAsioBridgeSetup.exe -i` on an already installed Hi-Fi Cable
  *removes* it, so the blueprint guards it with `Get-PnpDevice`; `VBCABLE_Setup_x64.exe -i`
  is a harmless reinstall.
