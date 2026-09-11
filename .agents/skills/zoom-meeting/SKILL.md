---
name: zoom-meeting
description: Create a host-less Zoom meeting via the Zoom REST API (Server-to-Server OAuth) and join it from a Devin VM as a named guest through the Zoom desktop app (macOS + BlackHole, Linux + PulseAudio null sinks, Windows + VB-Audio cables; plain Chrome/Edge web client as fallback). Use for multi-Devin Zoom demos (parent creates the meeting, children join with display names/personas and virtual-audio mics), for the fast in-process conversation loop (converse.py), and for the opt-in Wispr Flow Notetaker on macOS (only when the prompt says "wispr").
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

Hand each child exactly: the meeting `id` + `pwd` (or the URLs above), a display name, and its persona.
Display names follow a fixed scheme so the roster is readable to a viewer: `Mac VM 1`, `Mac VM 2`,
`Windows VM` (or `Linux VM 1`, `Linux VM 2`, ... by OS), and the parent's own seat is `Parent`. Deliberately no
`Devin` in display names — Zoom captions mishear it ("Devon", "Kevin"); plain OS names transcribe cleanly
(never "Observer" or bare "Devin 1" — a demo viewer can't tell who those are).

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
scripts/join_zoom.sh "<web_client_url_or_join_url>" "Mac VM 1"
# = scripts/dismiss_notifications.sh (closes Notification Center banners), launches
#   scripts/approve_mic_prompts.sh (auto-clicks Allow on the devin-remote mic TCC dialog), then
#   open "zoommtg://zoom.us/join?confno=<id>&pwd=<enc>&uname=Mac%20VM%201"
```

`join_zoom.sh` waits for the meeting window before returning (same as Linux §3, where it took 28-45 s; the wait
itself is only verified on Linux), so the first screenshot after it returns shows the join preview.

**Two focus traps, both handled by scripts now:** (a) Zoom always opens a "Zoom Workplace" sign-in/home
window alongside the join preview — it is a decoy. If a screenshot shows Sign in / Join a meeting instead
of the join preview or in-meeting toolbar, run `scripts/show_meeting_window.sh "<join_url>" "<topic>" "Mac VM 1"`
(raises the meeting window; re-fires the deep link — keeping the roster name — if only the home window exists). Never interact with the
sign-in page — a guest join needs no account. (b) The macOS TCC dialog "devin-remote would like to access
the Microphone" blocks the mic path until clicked; `approve_mic_prompts.sh` (auto-started by join_zoom.sh,
re-armed by every speak.py call, ~10-min singleton watcher) clicks **Allow** itself. The watcher does miss it
sometimes (seen 2026-09-11: the prompt was still up on the first `speak.py` and had to be clicked by hand), so
screenshot after the first speak: if a prompt is sitting on screen, click Allow once and re-run
`scripts/approve_mic_prompts.sh &`.

**Always clear macOS notifications before and during computer use.** Zoom and Chrome raise banners in the
top-right ("Zoom can run in the background", "Google Chrome Notifications" Allow/Don't Allow) that cover the
Zoom window and steal clicks. `scripts/dismiss_notifications.sh` presses Close / Clear All / Don't Allow on every
banner via the Accessibility API (verified: 4 banners gone in <2 s, no TCC prompt on the Devin VM). `join_zoom.sh`
runs it first; run it again whenever a screenshot shows a banner, before clicking anything else.

Then with computer use:
1. Preview window shows the pre-filled name; dismiss the "update being installed" dialog (**Not Now**), click **Join**.
   macOS TCC asks "devin-remote would like to access the Microphone" the first time — `approve_mic_prompts.sh`
   clicks **Allow** on its own; if it is visible for more than a few seconds, click Allow manually and
   restart the watcher (`scripts/approve_mic_prompts.sh &`).
2. **Audio ^ > Select a microphone**: `Same as system (BlackHole 2ch)`, `BlackHole 2ch`, `BlackHole 16ch`;
   **Select a speaker**: same three. Pick mic = BlackHole 2ch, speaker = BlackHole 16ch (Zoom remembers it as
   "Custom combination" on the next join).
3. Speak: `say -a "BlackHole 2ch" "Hello from Devin one"` (name the device: on 2 of 3 trio VMs plain `say`
   was not heard even with system output on BlackHole 2ch), or `scripts/speak.py "..."` for an ElevenLabs voice.
   The first audio triggers the TCC mic prompt for devin-remote; the `approve_mic_prompts.sh` watcher
   auto-Allows it (speak.py re-arms the watcher on every call). Re-check the speaker in Audio ^: Zoom
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
- `show_meeting_window.sh --snapshot` lists Zoom's windows as `<CG window number>\t<title>` via `osascript -l
  JavaScript`. On macOS 26 `ObjC.deepUnwrap($.CFBridgingRelease(list))` segfaults the whole osascript (status 139,
  "could not enumerate Zoom windows") and `join_zoom.sh` then refuses to fire the deep link (`zoom state: enum-failed`);
  `ObjC.castRefToObject(list)` is the working form. If you ever see status 139 there, that regression is back.

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
scripts/join_zoom.sh "<join_url_or_web_client_url>" "Linux VM 1"
# = scripts/linux_audio.sh (sinks devin_mic + zoom_out, remap source devin_mic_src; defaults: sink zoom_out, source devin_mic_src), then
#   /usr/bin/zoom "zoommtg://zoom.us/join?confno=<id>&pwd=<enc>&uname=<name>"
```

`join_zoom.sh` does not return until the meeting window is actually on screen (and fails if it never appears) —
Zoom took 28-45 s to map it on this VM, and a screenshot before that still shows the old desktop
(`ZOOM_WINDOW_WAIT`, default 60 s, caps the wait). A Zoom left running with no windows is re-sent the deep link
after `ZOOM_START_GRACE` (25 s), since it never grows a meeting window on its own. Windows Zoom already had
before the deep link (a previous meeting still open) are snapshotted (`show_meeting_window.sh --snapshot`, X
window ids here, CoreGraphics window numbers on macOS — never titles, a recurring topic reuses them) and
never count as the new meeting — leave the old meeting first or the wait times out. If the snapshot itself fails
(no X display, `wmctrl`/`osascript` error) `join_zoom.sh` refuses to fire the deep link rather than guess.

Then with computer use (`DISPLAY=:0`; `scripts/show_meeting_window.sh "<join_url>" "<topic>"` — or
`wmctrl -a "<topic>"` — brings the meeting window to the front, waits for it if Zoom is still starting, and
re-fires the deep link if only the "Zoom Workplace" sign-in window is up):
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
- The desktop app opens a second "Zoom Workplace" home window (sign-in nag); ignore it — drive only the
  meeting window (`scripts/show_meeting_window.sh "<join_url>" "<topic>"` raises it).
- **The meeting window's title is the meeting topic, not "Zoom"** (`wmctrl -lp`: `Zoom Workplace` + `Devin standup`),
  so filtering window titles for "zoom" finds only the home window and looks like a failed join.
  `show_meeting_window.sh` matches Zoom's windows by PID (`pgrep -f /opt/zoom/zoom`) instead.

### Web client fallback on Linux (`ZOOM_JOIN_MODE=chrome scripts/join_zoom.sh "<web_client_url>"`)
**Do not use Devin's default Chrome.** It runs with `--enable-automation` and a `Devin/1.0` user agent and Zoom's
web client rejects it with "Automated bots aren't allowed to join this meeting" (reCAPTCHA). The plain Chrome
instance the script launches (own profile) joins fine. Then: type the display name in **Your Name**, **Join**,
dismiss the "Cannot detect your camera" banner, **Allow** Chrome's mic prompt. Not re-tested with the null sinks.

## 4. Join from a Windows VM (child session) — verified 2026-09-11, Windows Server 2022 x64 Devin VM

Preferred path: **Zoom desktop app** (guest, no sign-in) with two VB-Audio virtual cables as the BlackHole
equivalent: **VB-CABLE** carries TTS into the Zoom mic, **Hi-Fi Cable** is the Zoom speaker (distinct device, so
"Same as System" can never loop meeting audio back into the mic). All PowerShell; the shell is already elevated.
Verified end to end: guest join with display name, device pickers, ElevenLabs `speak.py` captioned by Zoom,
`listen.py` transcribing another participant verbatim, and `--if-quiet` turn-taking. The Edge web client is
bot-blocked on this VM, so the desktop app is the only path. `python` (3.12, `C:\devin\python`) and `ffmpeg`
(chocolatey) are preinstalled on the Devin Windows image; the blueprint only installs ffmpeg if missing.

```powershell
# one-time setup (all in the runs-on: windows blueprint doc; ~20 s total, NO reboot needed)
Set-Service AudioEndpointBuilder -StartupType Automatic; Start-Service AudioEndpointBuilder   # VM boots with audio
Set-Service Audiosrv -StartupType Automatic; Start-Service Audiosrv                           # services disabled
Install-Module AudioDeviceCmdlets -Force -Scope CurrentUser                                   # Get-/Set-AudioDevice
curl.exe -sL -o $HOME\VBCABLE_Driver_Pack45.zip https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip
Expand-Archive -Force $HOME\VBCABLE_Driver_Pack45.zip $HOME\vbcable45
Start-Process -Wait $HOME\vbcable45\VBCABLE_Setup_x64.exe -ArgumentList '-i','-h' -WorkingDirectory $HOME\vbcable45   # 1-9 s
certutil -addstore -f TrustedPublisher scripts\windows\vb-audio-driver-signer.cer             # else a driver-trust dialog; blueprint removes it after the install
curl.exe -sL -o $HOME\HiFiCable.zip https://download.vb-audio.com/Download_CABLE/HiFiCableAsioBridgeSetup_v1007.zip
Expand-Archive -Force $HOME\HiFiCable.zip $HOME\hificable
if (-not (Get-PnpDevice -Class MEDIA -FriendlyName 'VB-Audio Hi-Fi Cable' -Status OK -ErrorAction SilentlyContinue)) {  # -i on an installed one REMOVES it
  Start-Process -Wait $HOME\hificable\HiFiCableAsioBridgeSetup.exe -ArgumentList '-i','-h' -WorkingDirectory $HOME\hificable  # 1.5 s
}
Remove-Item "Cert:\LocalMachine\TrustedPublisher\$((Get-PfxCertificate scripts\windows\vb-audio-driver-signer.cer).Thumbprint)"  # trust only needed for the install
curl.exe -sL -o $HOME\Zoom-x64.msi "https://zoom.us/client/latest/ZoomInstallerFull.msi?archType=x64"   # 212 MB; unsuffixed = 32-bit
Start-Process -Wait msiexec -ArgumentList '/i',"$HOME\Zoom-x64.msi",'/qn','/norestart'          # 20 s -> C:\Program Files\Zoom\bin\Zoom.exe

# per session: system output -> CABLE Input (= Zoom mic feed), system input -> CABLE Output
Import-Module AudioDeviceCmdlets
Get-AudioDevice -List | Format-Table Type, Name, Default   # expect CABLE Input, CABLE In 16ch, Hi-Fi Cable Input / CABLE Output, Hi-Fi Cable Output
Set-AudioDevice -ID (Get-AudioDevice -List | Where-Object { $_.Type -eq 'Playback'  -and $_.Name -like 'CABLE Input*'  }).ID
Set-AudioDevice -ID (Get-AudioDevice -List | Where-Object { $_.Type -eq 'Recording' -and $_.Name -like 'CABLE Output*' }).ID

# per meeting (no join_zoom.sh on Windows; the deep link is the whole script)
Start-Process "zoommtg://zoom.us/join?confno=<id>&pwd=<enc>&uname=Devin%20Child%203%20(Windows)"
# if the Zoom Workplace sign-in home window shows instead of the join preview, re-fire + foreground:
Start-Process "zoommtg://zoom.us/join?confno=<id>&pwd=<enc>&uname=Devin%20Child%203%20(Windows)"
(New-Object -ComObject WScript.Shell).AppActivate('<topic>')   # meeting window title = meeting topic
```

Then with computer use:
1. Preview window "Windows spike" shows the pre-filled name and "No camera connected"; click **Join**. If it says
   "Allow Zoom Workplace to access your microphone", desktop-app mic privacy is off: the blueprint sets
   `ConsentStore\microphone` = `Allow` (HKLM + HKCU + `NonPackaged`), or toggle it in Settings > Privacy > Microphone.
2. **Audio ^** in the preview (or Audio Settings): speaker list `CABLE Input`, `CABLE In 16ch`,
   `Hi-Fi Cable Input`, `Same as System`; microphone list `CABLE Output`, `Hi-Fi Cable Output`, `Same as System`.
   Zoom picks up the mic (CABLE Output) from the system default but **defaults the speaker to CABLE Input**, i.e.
   its own mic feed, so always switch **speaker = Hi-Fi Cable Input** (microphone = CABLE Output); Zoom remembers
   it ("Custom combination").
3. Speak: `python scripts\speak.py --voice Roger "Hello from Devin Windows"` (ElevenLabs -> WAV -> `System.Media.SoundPlayer`
   on the default output = CABLE Input; 4.8 s of audio took 8 s wall). **More (…) > Show captions** transcribes it
   (verified: "Hello from Devon Windows. This is the ElevenLabs voiced through the virtual cable"). No key -> falls
   back to `System.Speech` (Microsoft David/Zira; captioned as "Ball Back Windows Voice Test").
4. Listen: `python scripts\listen.py --seconds 20` / `--until-silence 2 --max 90` record `Hi-Fi Cable Output` via
   ffmpeg dshow (first frame after ~0.45 s) and post to Scribe; another participant's line came back verbatim.
   Zoom speech is ~1000-3000 RMS on this cable, silence is 1, so the default `ZOOM_SPEECH_RMS=300` is fine.
5. Turn-taking: `python scripts\speak.py --if-quiet --max-wait 40 --voice Roger "..."` held off while Devin Linux
   talked ("someone is talking; waiting for them to finish") and spoke 2 s after the line ended.
6. Leave: **Leave > Leave meeting**, then `Get-Process Zoom* | Stop-Process -Force`. The Leave button does not
   always open the confirm menu; killing the process is a clean leave (it does not end a host-less meeting).

Gotchas (details in `docs/gotchas.md`, tag `[win]`):
- No `winget` on Server 2022; `choco install vb-cable` (pack 43) installs but enumerates nothing — use pack 45.
- Both Zoom drivers enumerate immediately, **no reboot** at any step.
- `HiFiCableAsioBridgeSetup.exe -i` is a toggle: guard it with `Get-PnpDevice -Class MEDIA -FriendlyName 'VB-Audio Hi-Fi Cable'`.
- Zoom desktop keeps retrying "The host has another meeting in progress" by itself and joins as soon as the other
  meeting ends (it did after ~25 min here); `--list-live` from a shell with the secrets tells you which meeting blocks.
- `ffmpeg` on PATH is a chocolatey *shim* that spawns the real binary; `Popen.kill()` only kills the shim, so
  `listen.py` uses `taskkill /T /F` on Windows (otherwise 2-4 s stall per capture and a traceback from the reader).
- dshow device name is exactly `Hi-Fi Cable Output (VB-Audio Hi-Fi Cable)` (`ffmpeg -list_devices true -f dshow -i dummy`);
  override with `ZOOM_OUT_DSHOW` if it ever differs.

### Web client comparison on Windows (`Start-Process msedge "https://app.zoom.us/wc/join/<id>?pwd=<enc>"`)
Does **not** work as a join path: the preview loads (after Edge's one-time welcome wizard and a
`ConsentStore\webcam` = `Allow` so Edge may ask for camera+mic) and its device picker lists all four VB-Audio
endpoints, but **Join** returns "Automated bots aren't allowed to join this meeting" (reCAPTCHA) even in plain,
non-automated Edge — unlike plain Chrome on Linux/macOS. Use the desktop app.

## 5. Talking like a person (ElevenLabs, `ELEVENLABS_API_KEY`) — and the fast loop (`converse.py`, `FIREWORKS_API_KEY`)

**Default for conversations: `scripts/converse.py`**, not a hand-driven listen/speak loop. One agent step per
turn (screenshot + reasoning + tool round-trips) was the latency: 20-40 s between hearing a line and answering
it. `converse.py` runs listen -> transcribe -> chat model -> TTS -> speak in one process; the model call is
~1 s (Fireworks `glm-5p3-fast`), so a turn is bounded by the speech itself (~1.2 s silence + Scribe ~3 s + TTS ~3 s).
Nothing is scripted: each line is generated live from the persona, the roster, the running transcript and a
steer file you edit between turns; the model can answer `PASS` (not addressed to me) or end with `DONE` (said goodbye).

```bash
python3 scripts/converse.py --name "Mac VM 1" --voice Roger --check      # preflight: keys, voice, one model call (~2 s)
cat > ~/persona.md <<'EOF'
Infrastructure/CI engineer. This week: cached VM snapshots between pipeline runs (12 min -> 4 min), rotating
runner images tonight. Wants: a review on the pipeline PR before the release cut.
EOF
echo "Keep it to 4-5 of your own lines, then wrap up." > ~/steer.txt
python3 scripts/converse.py --name "Mac VM 1" --voice Roger --persona ~/persona.md \
    --roster "Mac VM 2 (frontend), Windows VM (QA)" --steer ~/steer.txt --log ~/turns.jsonl \
    --open "Hi Mac VM 2, Mac VM 1 here. Quick standup: what have you been working on?"   # opener only; others omit --open
# while it runs (own shell, 10-15 min timeout): append to ~/steer.txt to steer ("ask Mac VM 2 what they need by
# Friday"), tail ~/turns.jsonl (heard/said/pass with timestamps), append a line `STOP` to take over with listen/speak.
```

- Keys: `ELEVENLABS_API_KEY` (Scribe + TTS) and `FIREWORKS_API_KEY` (org secret). There is no OpenAI fallback
  on purpose. `ZOOM_LLM_MODEL` overrides the model; probed 2026-09: `accounts/fireworks/routers/glm-5p3-fast`
  (default, 0.5-1.3 s), `accounts/fireworks/models/deepseek-v4p1-flash`, `accounts/fireworks/routers/kimi-k3-fast`.
  `gpt-oss`/`nemotron` put everything in reasoning and are unusable. `llama-v3p3-70b-instruct` 404s on this account.
- Secrets are injected at session start: a child started before a secret was saved never sees it. Run `--check`
  first thing; if it exits on a missing key, report it and stop (do not join half-configured).
- The model only ever speaks its final `SAY:` line; reasoning is never sent to TTS.
- If every listen comes back empty while the other VM is audibly talking (Wispr shows their line, listen.py does
  not), the Zoom **speaker** is on the wrong device — Zoom defaults it to BlackHole 2ch (the mic); set 16ch.

### Manual loop (fallback / when you want to think per turn yourself)

```bash
scripts/speak.py --list-voices                     # Roger, Sarah, George, ... (pick one per Devin persona)
scripts/speak.py --voice Roger "Hi everyone, Mac VM 2 here. The audio routing is done."
scripts/listen.py --seconds 15                     # transcript of the meeting audio, "Devin" spelled right
scripts/listen.py --seconds 15 --json              # words + speaker_id + timestamps
scripts/listen.py --until-silence 2 --max 90       # block until someone talks and then stops for 2 s
scripts/speak.py --if-quiet --voice Roger "..."    # wait a random 0.5-2 s gap; back off if someone starts
```

- `speak.py` plays into the Zoom mic device (Linux `paplay --device=devin_mic`; macOS `afplay`, so system output
  must be BlackHole 2ch; Windows `System.Media.SoundPlayer` on the default output, which the blueprint sets to
  CABLE Input). No key -> falls back to `say -a "BlackHole 2ch"` / `PULSE_SINK=devin_mic espeak-ng` / `System.Speech`.
- Opening the capture device is slow on the first call (~2 s on Linux, longer for ffmpeg/BlackHole on macOS, where
  it used to fail the whole listen with "recorder produced no audio for 3 s"). `listen.py` now waits
  `ZOOM_CAPTURE_START_TIMEOUT` (default 12 s) for the first frame and only then starts the `--max` clock, so a cold
  start neither fails nor eats the listening window; the 3 s stall detector still applies once audio is flowing.
- `listen.py` records the Zoom speaker device (Linux `zoom_out.monitor`; macOS `BlackHole 16ch` via ffmpeg,
  `brew install ffmpeg` first; Windows `Hi-Fi Cable Output` via ffmpeg dshow, preinstalled) and posts it to Scribe
  with `keyterms` for our names. Verified on Linux and Windows: a real Devin line from the meeting came back word
  for word on both.
- Zoom's *own* captions still write "Devon"/"Kevin": no custom vocabulary there. Accept it: the native captions
  are the visible proof that real speech is reaching Zoom, our Scribe transcript is what a Devin reasons over.
  (A "Devin Captioner" pushing text via the third-party caption token was tried and dropped: Zoom returned 200
  but never rendered the captions in a host-less meeting, and it reads as an overlay rather than speech.)
- Turn-taking, the way a human does it. Loop per Devin:
  1. `text=$(scripts/listen.py --until-silence 2)` — returns the moment the current speaker has been quiet for
     2 s (max 90 s; exits non-zero if nobody spoke). Read `text`, decide whether it was addressed to you and
     what to say.
  2. `scripts/speak.py --if-quiet "<reply>"` — synthesises first, then watches the line for a random 0.5-2 s;
     if another Devin got in first it waits for them to finish and re-checks (`--max-wait 30`, then speaks anyway).
  3. Back to 1. Occasional overlap when two Devins both jump in is realistic; don't engineer it away.
  Verified on Linux with espeak into `zoom_out` (`--until-silence` returned 1.5 s after the line ended, `--if-quiet`
  held a 4 s talker off then spoke 2 s later) and live on Windows against a talking Linux participant. Speech threshold `ZOOM_SPEECH_RMS` (default 300; Zoom
  speech is ~1000-4000 RMS). The trio test predates this and used a fixed stagger (Devin n waits (n-1) x 25 s).

## 6. Running the whole demo from one prompt (parent session)

A prompt like "have 2 Mac VMs and 1 Windows VM join the same Zoom and chat with one another" means:

1. `python3 scripts/zoom_meeting.py --list-live` — end any straggler first (one live meeting per host).
2. `python3 scripts/zoom_meeting.py --topic "Devin standup" --duration 60 --json` — one meeting for everyone.
3. Start one child Devin session per participant (`macos` / `windows` / default Linux VM), all on this repo,
   with a prompt that gives each: display name from the fixed scheme (`Mac VM 1`, `Mac VM 2`, `Windows VM`,
   ...), a persona, an ElevenLabs voice
   (`--voice Roger|Sarah|George|...`), the join URL (Mac/Linux: `scripts/join_zoom.sh "<join_url>" "<name>"`;
   Windows: `Start-Process "zoommtg://zoom.us/join?confno=<id>&pwd=<enc>&uname=<name>"`), the device checks
   from §2/§3/§4 (Zoom often defaults the speaker to the mic device), "turn captions on" (**off in a Wispr run**, §7),
   the sign-in-window decoy rule (`show_meeting_window.sh` / AppActivate — the child must end up in the meeting
   window, not on the Zoom sign-in page), and the conversation: `converse.py` from §5 with a persona file, the
   roster, a steer file and `--log` (Mac/Linux; Windows children use the manual loop until converse.py's
   Windows capture is verified). Tell exactly one child to `--open` once all names are in the roster; the others
   run without `--open` and speak only when addressed (the model answers PASS otherwise). Ask for screenshots of
   the participant list and the captions panel (own line + another Devin's line), the `turns.jsonl` log, and
   "leave, don't end".
   Put every rule in the *first* prompt — captions on/off, split-screen, Wispr yes/no, which branch to test and
   its known failure mode: each mid-run correction cost a child 5-15 min in the 2026-09-11 runs. Start from
   `docs/child-prompt-mac.md` (fill the `{{...}}` fields; drop its WISPR block unless your own prompt says
   `wispr`). Start children only after every secret they need is saved (secrets are injected at session start).
   Two things to put in the prompts, both cost turns otherwise: the opener's first listens come back empty while
   the others are still setting up (expected — re-open, don't debug), and the participant-list screenshot must be
   taken while everyone is still in the meeting, not at the end when children have already left. Close the
   participants panel again right after that screenshot (see §7).
   Watch each child's provisioning: a child that only emits `remote_provisioning_status: slow` and no shell
   activity after ~5 min never got a VM. Terminate it and start a replacement rather than waiting — a
   2026-09-11 Windows child sat in provisioning for 30+ min and missed the whole meeting.
4. **Recording:** nobody in the meeting is host so Zoom cloud recording is unavailable — instead designate one
   child (preferably a macOS VM) to record its screen with the built-in tools. Its prompt adds: after joining
   and setting audio, make the screen presentable — **non-Wispr run:** the Zoom meeting window maximized with no
   other app visible (green button > Fill/Zoom, `defaults write com.apple.dock autohide -bool true; killall Dock`);
   **Wispr run:** the verified split of §7 — screenshot it and check it before recording, then `recording_start`;
   during the conversation call
   `annotate_recording` — `setup` for join/audio config, `test_start` when its turn begins ("It should give
   the <persona> standup update"), `assertion` after each spoke/heard turn ("Mac VM 1's update appeared as
   captions"), and `recording_stop` (title + summary) right after leaving. The video is the demo evidence.
5. Optionally join from the parent VM as `Parent` (Linux §3) to screenshot the roster/captions yourself.
6. When the children report, `python3 scripts/zoom_meeting.py --end <id>` and confirm with `--list-live`.

Timing seen so far: children take 1-3 min to be in the meeting (snapshot with Zoom preinstalled; ~60 s more
if the blueprint has to run by hand), a manual listen/speak turn is 20-40 s (agent step), a converse.py turn
~6-9 s; a 6-8 turn conversation is ~8 min manual, ~2-3 min with converse.py. A Wispr run adds ~5 min per Mac
for login + permissions (§7).

## 7. Wispr Flow Notetaker on the Mac VMs — opt-in, verified 2026-09-11 on two macOS 26.5 VMs

**Only when the parent prompt contains the word `wispr`.** Otherwise: do not launch, sign in to, or configure
Wispr Flow (the cask may be preinstalled by the blueprint; leave it alone). Windows/Linux children are never
affected. Wispr Notetaker is a local Mac app that records system audio + the default mic and produces a live
transcript, a diarised refined transcript and an AI summary; no bot joins Zoom. It runs on **both** Mac VMs.

Rules for a Wispr run (put them in the children's first prompt):
- Zoom captions **off** (`More (…) > Hide captions` if on). The Wispr live transcript is the proof of speech.
- **Split screen is mandatory, and must be verified before anything is recorded or screenshotted for the user.**
  Zoom meeting window = exactly the left half, Wispr "Meeting Recorder" (notepad/live transcript) = exactly the
  right half, nothing else on screen: no Chrome, no Finder window, no Dock, no strip of wallpaper between or
  under the two halves. Half-width windows floating over the desktop look unfinished and are not acceptable.
  1. `scripts/wispr_notetaker.sh layout` — hides every other app, auto-hides the Dock, tiles both windows and
     then *checks* their frames. It exits non-zero and prints which window is off.
  2. If it fails: hover that window's **green button > Tile Window to Left/Right of Screen** (or drag-resize it),
     then `scripts/wispr_notetaker.sh layout --verify` until it passes. Never continue on a failing check.
  3. Take a screenshot and look at it: both halves flush to the screen edges and to each other, nothing visible
     behind them. Only then `recording_start` / send a screenshot to the user.
  Re-run `layout --verify` after anything that can move a window (leaving a panel open, a Wispr dialog, a
  re-join). The recorder child records this layout.
- Close the Zoom **participants panel** (⌘U, or its X) before `layout` and before `recording_start`, and keep it
  closed for the rest of the meeting. Docked, it widens the Zoom window over the right half and hides the Wispr
  live transcript for the whole recording (2026-09-11 run). Open it only for the roster screenshot, then ⌘U again.
- Credentials: `WISPR_FLOW_EMAIL` / `WISPR_FLOW_PASSWORD` (org secrets). Type them with `printenv X | pbcopy` + ⌘V;
  never echo, log or screenshot them. The same email/password is a throwaway Google account (Google sign-in uses it).

```bash
scripts/wispr_notetaker.sh install    # casks wispr-flow + google-chrome, Chrome = default browser, click-to-show-desktop off
scripts/wispr_notetaker.sh devices    # system output AND input -> BlackHole 2ch (Notetaker follows the default input)
scripts/wispr_notetaker.sh launch     # `open -a "Wispr Flow"` does not find it; the script opens the .app path
# sign in + permissions: GUI steps below
scripts/wispr_notetaker.sh authdb grant     # before the Accessibility toggle ...
scripts/wispr_notetaker.sh authdb restore   # ... and right after it is on
scripts/wispr_notetaker.sh layout     # once Zoom is joined and a note is running
scripts/wispr_notetaker.sh status
```

Sign-in (budget 5 min, then report and continue without Wispr):
1. App > **Sign in via browser** opens the default browser. **Never use the email + password form: its hCaptcha
   checkbox spins forever in Safari (both VMs, 3-20 min lost).** Chrome must be the default browser (`install` does
   it; confirm the "Use Chrome" dialog if one is up) — if Safari opened anyway, close it and re-click the button.
2. Click **Continue with Google**, paste email then password, **Continue** on the consent screen. No verification
   code / Gmail step was needed on either VM.
3. Handoff to the app needs a **second** click: Safari's `Open Wispr Flow` button a second time (then "Always
   Allow"), or in Chrome click **Sign in via browser** in the app a second time after "You're now logged in".
   The app then shows onboarding "Welcome, <name>". It stays signed in across quit/relaunch within the VM.

Onboarding/permissions (choose the Notetaker use-case, any survey answers, Esc closes the intro video):
- **Microphone** and **System Audio Recording**: plain TCC dialogs -> Allow (no password).
- **Accessibility** ("Allow Wispr to recognize meetings"; mandatory in onboarding): the System Settings toggle asks
  for the account password. Passwordless sudo does not help and allowing only `system.preferences*` does not stop
  the prompt (authd wants `com.apple.DiskManagement.reserveKEK`). What worked: `wispr_notetaker.sh authdb grant`
  (backs up + allows seven rights incl. reserveKEK), flip the toggle, `authdb restore` immediately. TCC.db is
  read-only (SIP) — do not try to write it. If the toggle still prompts, screenshot it and report; do not guess a password.
- The `devin-remote` mic TCC prompt appears again on the first `say`/TTS: Allow (approve_mic_prompts.sh may get it).

Notetaker:
- Start: menu bar **Notetaker > Start new note** (works with the virtual mouse). Wispr also pops "Transcribe this
  meeting with Wispr?" ~5 s after Zoom joins (needs Accessibility). **Toast buttons mostly do not take virtual-mouse
  clicks** — a missed click hits the wallpaper and macOS hides every window (`install` disables that). Prefer the
  menu bar; if a toast click does register you get a second parallel note, which is harmless.
- Test before joining Zoom: `say -a "BlackHole 2ch" "Wispr test one two three"` shows in the live transcript in ~5 s.
- Stop: green **Stop** at the bottom of the Meeting Recorder window — first click focuses Wispr/opens the confirm,
  second click stops. "Started by mistake?" -> **Keep**. Summary tab ~20 s, refined diarised transcript ~1 min.
  Copy icons in each tab header -> `pbpaste > ~/wispr_transcript.txt` / `~/wispr_summary.txt`; attach both.
- Notes live in `~/Library/Application Support/Wispr Flow/` (`flow.sqlite`, `meetings/<uuid>/`); never copy
  `session.json`/Cookies anywhere (Wispr rotates them; the user asked not to persist logins).

Speaker attribution — what to expect and claim:
- Live labels are **You** = default-input mic, **Them** = system audio. Our TTS is app audio played into BlackHole 2ch,
  which Wispr's system-audio tap also hears, so **own lines show as "Them"** (fragments as "You"). Setting the default
  output to BlackHole 16ch and playing TTS with `say -a "BlackHole 2ch"` does **not** change this (tested on both
  VMs) — the tap is not limited to the default output device. Don't repeat that experiment.
- The refined (post-meeting) transcript diarises by voice into Speaker 1/Speaker 2 correctly when the two VMs use
  different ElevenLabs voices (Roger/Sarah); same-voice `say` lines get merged. It maps one speaker to the account
  name, not to Zoom roster names. That refined transcript is the speaker-identification evidence; live You/Them is not.
- Wispr Settings > General > Microphone shows "Auto-detect (<default input>)"; Notetaker always uses auto-detect,
  so `devices` (input = BlackHole 2ch) is what matters. Settings > Notetaker: shortcut Opt+M (not exercised via the
  virtual keyboard), "Stop Notetaker when a call ends" on.

Order of operations for a Wispr child: `install` -> `devices` -> `launch` + sign-in + permissions -> test note ->
join Zoom (§2; mic BlackHole 2ch, speaker BlackHole 16ch, captions off) -> start note -> close the participants
panel -> `layout` -> recorder starts recording (do not maximize Zoom on a Wispr run; that hides the transcript) ->
`converse.py` (§5) -> stop note, export -> leave (don't end) -> attach transcript, summary, recording.

## Limits
- Paid host account: no 40-min cap. Free account: 40-min cap on 3+ participant meetings even with no host present.
- Nobody in the meeting is host, so nobody can start a cloud recording; record locally if needed.
- Web client vs desktop: web client cannot be host and has limited device controls (Safari: no speaker choice).
- Linux: `pulseaudio --start` is per-session (user daemon); `linux_audio.sh` restarts it and recreates the sinks if needed.
