---
name: zoom-meeting
description: Create a host-less Zoom meeting via the Zoom REST API (Server-to-Server OAuth) and join it from a Devin VM as a named guest through the Zoom desktop app (macOS + BlackHole, Linux + PulseAudio null sinks, Windows + VB-Audio cables; plain Chrome/Edge web client as fallback). Use for multi-Devin Zoom demos (parent creates the meeting, children join with display names/personas and virtual-audio mics).
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
- Management calls fail with HTTP 400 code 4711 when the matching scope is not granted on the app.
  `--list-live` and `--end` worked on 2026-09-11 once the scopes were added; `--delete` is untested.
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
# = scripts/dismiss_notifications.sh (closes Notification Center banners), then
#   open "zoommtg://zoom.us/join?confno=<id>&pwd=<enc>&uname=Devin%201"
```

**Always clear macOS notifications before and during computer use.** Zoom and Chrome raise banners in the
top-right ("Zoom can run in the background", "Google Chrome Notifications" Allow/Don't Allow) that cover the
Zoom window and steal clicks. `scripts/dismiss_notifications.sh` presses Close / Clear All / Don't Allow on every
banner via the Accessibility API (verified: 4 banners gone in <2 s, no TCC prompt on the Devin VM). `join_zoom.sh`
runs it first; run it again whenever a screenshot shows a banner, before clicking anything else.

Then with computer use:
1. Preview window shows the pre-filled name; dismiss the "update being installed" dialog (**Not Now**), click **Join**.
   macOS TCC asks "devin-remote would like to access the Microphone" the first time -> **Allow**.
2. **Audio ^ > Select a microphone**: `Same as system (BlackHole 2ch)`, `BlackHole 2ch`, `BlackHole 16ch`;
   **Select a speaker**: same three. Pick mic = BlackHole 2ch, speaker = BlackHole 16ch (Zoom remembers it as
   "Custom combination" on the next join).
3. Speak: `say -a "BlackHole 2ch" "Hello from Devin one"` (name the device: on 2 of 3 trio VMs plain `say`
   was not heard even with system output on BlackHole 2ch), or `scripts/speak.py "..."` for an ElevenLabs voice.
   The first audio triggers the TCC mic prompt for devin-remote: **Allow**. Re-check the speaker in Audio ^: Zoom
   defaulted it to BlackHole 2ch (the mic) on two VMs; it must be 16ch.
   **More (…) > Show captions** turns on live captions without host involvement and transcribes the `say` text
   (verified: "Hello from Devon1, Testing Captions").
4. Leave: hover the window, **Leave > Leave meeting**, then `pkill -x zoom.us`.

Gotchas:
- `https://zoom.us/client/latest/Zoom.pkg` (no `archType`) is an **x86_64-only** build; on the arm64 VM `open`
  fails with `_LSOpenURLsWithCompletionHandler() failed ... error -10669` and the binary says "Bad CPU type".
  Use `?archType=arm64` (or install Rosetta). `join_zoom.sh` auto mode checks `lipo -archs` against `uname -m`
  and falls back to Chrome/Safari when the installed app is the wrong architecture.
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

## 3. Join from a Linux VM (child session) — verified 2026-09-11, Ubuntu 22.04 x86_64 Devin VM

Preferred path: **Zoom desktop app** (guest, no sign-in) with PulseAudio null sinks as the BlackHole
equivalent. Live captions transcribe `espeak-ng` / `paplay` output, which proves the mic path end to end.

```bash
# one-time setup (also in the blueprint)
sudo apt-get install -y pulseaudio pulseaudio-utils espeak-ng      # VM ships without pactl
curl -sL -o ~/zoom_amd64.deb https://zoom.us/client/latest/zoom_amd64.deb   # 297 MB
sudo apt-get install -y ~/zoom_amd64.deb                            # ~30 s -> /usr/bin/zoom (Zoom Workplace 7.1.x)

# per meeting
scripts/join_zoom.sh "<join_url_or_web_client_url>" "Devin 2"
# = scripts/linux_audio.sh (sinks devin_mic + zoom_out, remap source devin_mic_src; defaults: sink zoom_out, source devin_mic_src), then
#   /usr/bin/zoom "zoommtg://zoom.us/join?confno=<id>&pwd=<enc>&uname=Devin%202"
```

Then with computer use (`DISPLAY=:0`; `wmctrl -a "<topic>"` brings the preview window to the front):
1. Preview window shows the pre-filled name. Close the "Your speaker volume is low" toast if shown, click **Join**.
   The audio dropdown defaults to "Computer audio"; if it says "Select audio", pick **Computer audio** first.
   No permission prompts on Linux.
2. **Audio ^**: microphone `DevinMicSrc` (and `Same as System (DevinMicSrc)`), speaker `DevinMic` / `ZoomOut`.
   Pick mic = DevinMicSrc, speaker = ZoomOut; Zoom remembers it ("Custom audio combination") on the next join.
3. Speak: `PULSE_SINK=devin_mic espeak-ng "Hello from Devin two"` or `paplay --device=devin_mic tts.wav`
   (any TTS that writes a WAV works; espeak-ng is robotic and captions mishear names).
   **More (…) > Show captions** turns on live captions without host involvement and transcribes it
   (verified: "Hello from Bevin on Linux. This is a quick roundbox...", "Testing Popley Pot" for "Testing paplay path").
4. Zoom's own output goes to `zoom_out`; capture it with `parecord --device=zoom_out.monitor out.wav`, or
   `scripts/listen.py --seconds 15` to get an ElevenLabs Scribe transcript of what the meeting said.
5. Leave: **Leave > Leave meeting**, then `pkill -f /opt/zoom/zoom`.

Gotchas:
- Zoom's Linux client **does not list `*.monitor` sources as microphones** ("Zoom cannot detect your microphone").
  `linux_audio.sh` adds a `module-remap-source` over `devin_mic.monitor`; that remap (`DevinMicSrc`) is what shows up.
- Devices created while Zoom is already running do appear in the picker, but run `linux_audio.sh` first anyway so
  the defaults are right when Zoom starts.
- The desktop app opens a second "Zoom Workplace" home window (sign-in nag); ignore it.

### Web client fallback on Linux (`ZOOM_JOIN_MODE=chrome scripts/join_zoom.sh "<web_client_url>"`)
**Do not use Devin's default Chrome.** It runs with `--enable-automation` and a `Devin/1.0` user agent and Zoom's
web client rejects it with "Automated bots aren't allowed to join this meeting" (reCAPTCHA). The plain Chrome
instance the script launches (own profile) joins fine. Then: type the display name in **Your Name**, **Join**,
dismiss the "Cannot detect your camera" banner, **Allow** Chrome's mic prompt. Not re-tested with the null sinks.

## 4. Join from a Windows VM (child session) — verified 2026-09-11, Windows Server 2022 x64 Devin VM

Preferred path: **Zoom desktop app** (guest, no sign-in) with two VB-Audio virtual cables as the BlackHole
equivalent: **VB-CABLE** carries TTS into the Zoom mic, **Hi-Fi Cable** is the Zoom speaker (distinct device, so
"Same as System" can never loop meeting audio back into the mic). All PowerShell; the shell is already elevated.
Verified end to end: guest join with display name, device pickers, Windows TTS moving the mic meter and
**live captions transcribing it**. The Edge web client is bot-blocked on this VM, so the desktop app is the only path.

```powershell
# one-time setup (all in the runs-on: windows blueprint doc; ~20 s total, NO reboot needed)
Set-Service AudioEndpointBuilder -StartupType Automatic; Start-Service AudioEndpointBuilder   # VM boots with audio
Set-Service Audiosrv -StartupType Automatic; Start-Service Audiosrv                           # services disabled
Install-Module AudioDeviceCmdlets -Force -Scope CurrentUser                                   # Get-/Set-AudioDevice
# both installers' -i switch TOGGLES: guard on any PnP node (OK or not) so a rerun never uninstalls a cable
if (-not (Get-PnpDevice -Class MEDIA -FriendlyName 'VB-Audio Virtual Cable' -ErrorAction SilentlyContinue)) {
  curl.exe -sL -o $HOME\VBCABLE_Driver_Pack45.zip https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip
  Expand-Archive -Force $HOME\VBCABLE_Driver_Pack45.zip $HOME\vbcable45
  Start-Process -Wait $HOME\vbcable45\VBCABLE_Setup_x64.exe -ArgumentList '-i','-h' -WorkingDirectory $HOME\vbcable45   # 1-9 s
}
if (-not (Get-PnpDevice -Class MEDIA -FriendlyName 'VB-Audio Hi-Fi Cable' -ErrorAction SilentlyContinue)) {
  $trust = "Cert:\LocalMachine\TrustedPublisher\$((Get-PfxCertificate scripts\windows\vb-audio-driver-signer.cer).Thumbprint)"
  $addedTrust = -not (Test-Path $trust)
  try {
    if ($addedTrust) { certutil -addstore -f TrustedPublisher scripts\windows\vb-audio-driver-signer.cer }   # else a driver-trust dialog
    curl.exe -sL -o $HOME\HiFiCable.zip https://download.vb-audio.com/Download_CABLE/HiFiCableAsioBridgeSetup_v1007.zip
    Expand-Archive -Force $HOME\HiFiCable.zip $HOME\hificable
    Start-Process -Wait $HOME\hificable\HiFiCableAsioBridgeSetup.exe -ArgumentList '-i','-h' -WorkingDirectory $HOME\hificable  # 1.5 s
  } finally { if ($addedTrust -and (Test-Path $trust)) { Remove-Item $trust } }   # trust only needed for the install; keep it if it was already there
}
foreach ($name in 'VB-Audio Virtual Cable', 'VB-Audio Hi-Fi Cable') {
  $dev = @(Get-PnpDevice -Class MEDIA -FriendlyName $name -ErrorAction SilentlyContinue)
  if (-not $dev) { throw "$name missing; re-run the setup" }
  $bad = @($dev | Where-Object Status -ne 'OK')
  if ($bad) { throw "$name not healthy: pnputil /remove-device $($bad.InstanceId -join ' '), then re-run" }
}
curl.exe -sL -o $HOME\Zoom-x64.msi "https://zoom.us/client/latest/ZoomInstallerFull.msi?archType=x64"   # 212 MB; unsuffixed = 32-bit
Start-Process -Wait msiexec -ArgumentList '/i',"$HOME\Zoom-x64.msi",'/qn','/norestart'          # 20 s -> C:\Program Files\Zoom\bin\Zoom.exe

# per session: system output -> CABLE Input (= Zoom mic feed), system input -> CABLE Output
Import-Module AudioDeviceCmdlets
Get-AudioDevice -List | Format-Table Type, Name, Default   # expect CABLE Input, CABLE In 16ch, Hi-Fi Cable Input / CABLE Output, Hi-Fi Cable Output
Set-AudioDevice -ID (Get-AudioDevice -List | Where-Object { $_.Type -eq 'Playback'  -and $_.Name -like 'CABLE Input*'  }).ID
Set-AudioDevice -ID (Get-AudioDevice -List | Where-Object { $_.Type -eq 'Recording' -and $_.Name -like 'CABLE Output*' }).ID

# per meeting (no join_zoom.sh on Windows; the deep link is the whole script)
Start-Process "zoommtg://zoom.us/join?confno=<id>&pwd=<enc>&uname=Devin%20Win"
```

Then with computer use:
1. Preview window "Windows spike" shows the pre-filled name and "No camera connected"; click **Join**. If it says
   "Allow Zoom Workplace to access your microphone", desktop-app mic privacy is off: the blueprint sets
   `ConsentStore\microphone` = `Allow` (HKLM + HKCU + `NonPackaged`), or toggle it in Settings > Privacy > Microphone.
2. **Audio ^ > Audio Settings** (works from the preview too): speaker list `CABLE Input`, `CABLE In 16ch`,
   `Hi-Fi Cable Input`, `Same as System`; microphone list `CABLE Output`, `Hi-Fi Cable Output`, `Same as System`.
   Pick **speaker = Hi-Fi Cable Input, microphone = CABLE Output**; Zoom remembers it ("Custom combination").
3. Speak: `Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak("Hello from Devin Windows, testing captions")`
   (voices: Microsoft David/Zira Desktop; `SetOutputToDefaultAudioDevice()` is the default, i.e. CABLE Input).
   The **Input Level** meter in Audio Settings lights up green for the phrase. **More (…) > Show captions**
   transcribes it (verified: "Hello from Devon Windows, testing captions This is Devin Wynne speaking through the
   virtual cable"; David/Zira mishear names a bit, like espeak on Linux).
4. Zoom's own output lands on `Hi-Fi Cable Input`; record it from `Hi-Fi Cable Output` if STT of the meeting is needed.
5. Leave: **Leave > Leave meeting**, then `Get-Process Zoom* | Stop-Process -Force`.

Gotchas (details in `docs/gotchas.md`, tag `[win]`):
- No `winget` on Server 2022; `choco install vb-cable` (pack 43) installs but enumerates nothing — use pack 45.
- Both Zoom drivers enumerate immediately, **no reboot** at any step.
- `HiFiCableAsioBridgeSetup.exe -i` is a toggle: guard it with `Get-PnpDevice -Class MEDIA -FriendlyName 'VB-Audio Hi-Fi Cable'`.
- Zoom desktop keeps retrying "The host has another meeting in progress" by itself and joins as soon as the other
  meeting ends (it did after ~25 min here); `--list-live` from a shell with the secrets tells you which meeting blocks.

### Web client comparison on Windows (`Start-Process msedge "https://app.zoom.us/wc/join/<id>?pwd=<enc>"`)
Does **not** work as a join path: the preview loads (after Edge's one-time welcome wizard and a
`ConsentStore\webcam` = `Allow` so Edge may ask for camera+mic) and its device picker lists all four VB-Audio
endpoints, but **Join** returns "Automated bots aren't allowed to join this meeting" (reCAPTCHA) even in plain,
non-automated Edge — unlike plain Chrome on Linux/macOS. Use the desktop app.

## 5. Talking like a person (ElevenLabs, `ELEVENLABS_API_KEY`)

```bash
scripts/speak.py --list-voices                     # Roger, Sarah, George, ... (pick one per Devin persona)
scripts/speak.py --voice Roger "Hi everyone, Devin 2 here. The audio routing is done."
scripts/listen.py --seconds 15                     # transcript of the meeting audio, "Devin" spelled right
scripts/listen.py --seconds 15 --json              # words + speaker_id + timestamps
```

- `speak.py` plays into the Zoom mic device (Linux `paplay --device=devin_mic`; macOS `afplay`, so system output
  must be BlackHole 2ch). No key -> falls back to `say -a "BlackHole 2ch"` / `PULSE_SINK=devin_mic espeak-ng`.
- `listen.py` records the Zoom speaker device (Linux `zoom_out.monitor`; macOS `BlackHole 16ch` via ffmpeg,
  `brew install ffmpeg` first) and posts it to Scribe with `keyterms` for our names. Verified on Linux: TTS ->
  `zoom_out` -> `listen.py` round trip and a real Devin line from the meeting both came back word for word.
- Zoom's *own* captions still write "Devon"/"Kevin": no custom vocabulary there. Accept it, or (future) push our
  Scribe transcript into Zoom via the third-party closed-caption API token.
- Turn-taking for a natural-sounding meeting: `listen.py` (or a streaming version) until ~1.5-2 s of silence, back
  off a random 0.5-2 s if someone else starts, then `speak.py`. The trio test used a fixed stagger instead
  (Devin n waits (n-1) x 25 s after the roster is complete) and had no overlap.

## Limits
- Paid host account: no 40-min cap. Free account: 40-min cap on 3+ participant meetings even with no host present.
- Nobody in the meeting is host, so nobody can start a cloud recording; record locally if needed.
- Web client vs desktop: web client cannot be host and has limited device controls (Safari: no speaker choice).
- Linux: `pulseaudio --start` is per-session (user daemon); `linux_audio.sh` restarts it and recreates the sinks if needed.
