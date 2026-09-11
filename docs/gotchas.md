# Gotchas and workarounds (everything that bit us, 2026-09-10/11)

Each entry: symptom -> cause -> fix. Platform tags: [api] [mac] [linux] [win] [all]. Where the fix is code, the
script that implements it is named so nobody has to rediscover it.

## Zoom API (Server-to-Server OAuth)

- [api] **`POST /users/me/meetings` fails with an S2S token.** S2S tokens are not bound to a user, so `me` is
  invalid. Use `POST /users/{host_email}/meetings` with the host's email URL-encoded (`zoom_meeting.py:create_meeting`).
- [api] **Guests get "waiting for the host" instead of the meeting.** `join_before_host` is ignored for instant
  meetings (`type: 1`). Create a *scheduled* meeting (`type: 2`) with
  `join_before_host: true, jbh_time: 0, waiting_room: false, approval_type: 2, meeting_authentication: false`.
  Account settings must also allow it: "Allow participants to join before host" on; "Only authenticated users
  can join meetings from Web client" off; "Show a Join from your browser link" on.
- [api] **HTTP 400, Zoom code 4711 ("Invalid access token, does not contain scopes ...").** The S2S app lacks the
  scope for that endpoint. Add it in Marketplace > Scopes and re-Activate; credentials stay the same. Needed set:
  `meeting:write:meeting:admin`, `meeting:read:meeting:admin`, `meeting:update:status:admin` (`--end`),
  `meeting:delete:meeting:admin` (`--delete`), `meeting:read:list_meetings:admin` (`--list-live`).
- [api] **"The host has another meeting in progress" when a child joins.** One live meeting per host account. A
  join-before-host meeting stays "in progress" as long as any guest is connected, even with no host. Fix: all
  Devins join the *same* meeting; the parent runs `zoom_meeting.py --end <id>` when done and `--list-live` to
  find stragglers. Leaving as a participant does *not* end the meeting.
- [api] **Passcode handling.** `join_url` already carries `?pwd=<encrypted>`; reuse that value in the web-client
  URL (`https://app.zoom.us/wc/join/<id>?pwd=<enc>`) and the desktop deep link
  (`zoommtg://zoom.us/join?confno=<id>&pwd=<enc>&uname=<name>`) to skip every passcode prompt. Never paste the
  `pwd` into chat, PRs, or logs: it is a credential.
- [api] **Event Subscriptions / webhook secret token are not needed.** The scripts only make outbound calls.

## Joining

- [linux] **"Automated bots aren't allowed to join this meeting" (reCAPTCHA) in the web client.** Devin's own
  Chrome runs with `--enable-automation` and a `Devin/1.0` user agent. Launch a *separate* plain Chrome process
  with its own `--user-data-dir` (`join_zoom.sh` chrome mode); the datacenter IP is not the problem. macOS VMs have
  no Devin-default Chrome, so this never triggers there. The desktop app avoids it entirely.
- [all] **"Cannot detect your camera".** VMs have no camera; dismiss and continue, joining still works.
- [all] **Zoom desktop app asks to sign in / opens a second "Zoom Workplace" home window.** Ignore it. The
  `zoommtg://` deep link joins as a guest; `uname=` pre-fills the display name so no typing is needed.
- [all] **Zoom "update being installed" dialog on first launch (mac).** Click **Not Now**.
- [all] **Live captions without a host.** Any participant can turn them on: **More (...) > Show captions**. This
  is the visible proof that Zoom hears the synthetic speech; use it in demos.
- [all] **Zoom remembers device choices per install** ("Custom audio combination" on the next join), so pick
  mic/speaker once per VM.

## macOS audio (BlackHole)

- [mac] **`brew install --cask blackhole-*` says "You must reboot".** Not needed: `sudo killall coreaudiod`
  and both devices enumerate immediately (`system_profiler SPAudioDataType`).
- [mac] **`open` fails with `-10669` / "Bad CPU type" after installing Zoom.pkg.** The unsuffixed
  `https://zoom.us/client/latest/Zoom.pkg` is x86_64-only. Use `Zoom.pkg?archType=arm64` on the arm64 Devin VM.
  `join_zoom.sh` checks `lipo -archs` against `uname -m` and falls back to a browser if the arch is wrong.
- [mac] **Notification banners cover the Zoom window and eat clicks** ("Zoom can run in the background",
  "Google Chrome Notifications"). `scripts/dismiss_notifications.sh` closes them via the Accessibility API
  (no TCC prompt on the VM); `join_zoom.sh` runs it first. Re-run whenever a screenshot shows a banner.
- [mac] **macOS TCC prompt "devin-remote would like to access the Microphone".** Click **Allow** once.
- [mac] **Routing TTS into Zoom.** `SwitchAudioSource -s "BlackHole 2ch"` makes system output the Zoom mic, so
  plain `say "..."` is heard by Zoom. Pick speaker = BlackHole 16ch in Zoom, *not* "Same as System": with
  system output on BlackHole 2ch, "Same as System" would send the meeting's audio straight back into the mic.
- [mac] **Safari web client shows no mic level on `say`** and offers only "Same as System" for the speaker.
  Treat Safari as join-only; use the desktop app.

## Linux audio (PulseAudio)

- [linux] **`pactl: command not found`.** The VM ships without PulseAudio:
  `sudo apt-get install -y pulseaudio pulseaudio-utils espeak-ng` (in the blueprint).
- [linux] **Zoom says "Zoom cannot detect your microphone" although `devin_mic.monitor` exists.** Zoom's Linux
  client filters out `*.monitor` sources. Wrap the monitor in a remap source
  (`pactl load-module module-remap-source master=devin_mic.monitor source_name=devin_mic_src ...`); that one
  (`DevinMicSrc`) appears in the picker. Done by `scripts/linux_audio.sh`.
- [linux] **Meeting audio echoes back into the meeting.** If the default sink is the mic sink and Zoom's speaker
  is "Same as System", Zoom's output feeds `devin_mic_src`. `linux_audio.sh` therefore sets the default sink to
  `zoom_out`; TTS targets `devin_mic` explicitly (`PULSE_SINK=devin_mic espeak-ng ...`, `paplay --device=devin_mic`).
- [linux] **Devices vanish after `pulseaudio --kill` or a new session.** PulseAudio is a per-user daemon; the
  sinks are not persistent. `linux_audio.sh` is idempotent, re-run it (join_zoom.sh does) before starting Zoom.
- [linux] **Zoom window is behind Chrome / not visible.** `DISPLAY=:0 wmctrl -a "<meeting topic>"` raises the
  preview or meeting window; `wmctrl -l` lists windows to confirm Zoom started (`~/zoom-desktop.log` has stderr).
- [linux] **`pkill -f zoom` killed my shell.** `-f` matches the full command line, including the shell running
  the `pkill`. Use `pkill -f /opt/zoom/zoom` from a one-shot command, or `pkill -x zoom`.
- [linux] **espeak-ng captions mishear names** ("Bevin", "Popley Pot"). The voice is robotic; fine as proof,
  use a real TTS (ElevenLabs/OpenAI -> WAV -> `paplay --device=devin_mic`) for the demo.

## Windows audio (VB-Audio cables) and Zoom desktop

- [win] **`Get-AudioDevice -List` / `Get-CimInstance Win32_SoundDevice` return nothing, even after installing a
  virtual cable.** The Server 2022 Devin VM boots with `Audiosrv` and `AudioEndpointBuilder` **Stopped/Disabled**.
  `Set-Service <svc> -StartupType Automatic; Start-Service <svc>` for both (first blueprint step); endpoints then
  appear without a reboot.
- [win] **`winget` is not installed.** Server 2022 has no App Installer. Use direct downloads (`curl.exe -sL`) and
  `msiexec`; `choco` exists but see the next entry.
- [win] **`choco install vb-cable -y` succeeds but no `CABLE Input`/`CABLE Output` appear.** The chocolatey package
  ships VB-CABLE driver pack 43, which does not enumerate on this VM. Download pack 45 from
  `https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip` and run `VBCABLE_Setup_x64.exe -i -h`
  (`-i` install, `-h` hidden): `CABLE Input` (playback), `CABLE In 16ch`, `CABLE Output` (recording) show up in
  ~1 s, no reboot. Re-running it is a harmless reinstall.
- [win] **`HiFiCableAsioBridgeSetup.exe -i -h` hangs on a "Windows Security: Would you like to install this device
  software?" dialog.** The Hi-Fi Cable driver (2015) is signed by VB-Audio (Vincent Burel) but not WHQL, so
  Windows asks before trusting the publisher. Pre-trust it: `certutil -addstore -f TrustedPublisher
  scripts\windows\vb-audio-driver-signer.cer` (the cert exported from the `.cat` file), then the same command
  finishes silently in 1.5 s.
- [win] **Hi-Fi Cable disappears after re-running the blueprint / setup.** `HiFiCableAsioBridgeSetup.exe -i` on
  an already installed Hi-Fi Cable *removes* it (toggle behaviour). Guard the install with
  `Get-PnpDevice -Class MEDIA -FriendlyName 'VB-Audio Hi-Fi Cable'` (done in `.devin/blueprint.yaml`).
- [win] **Zoom lands in `C:\Program Files (x86)\Zoom` and nags "upgrade to 64-bit".** The unsuffixed
  `https://zoom.us/client/latest/ZoomInstallerFull.msi` is the 32-bit build. Use
  `ZoomInstallerFull.msi?archType=x64` + `msiexec /i <msi> /qn /norestart` -> `C:\Program Files\Zoom\bin\Zoom.exe`
  (Zoom Workplace 7.1.8); it replaces the x86 install. Downloads of the 212 MB MSI ranged from 7 s to 14 min.
- [win] **Zoom preview says "Allow Zoom Workplace to access your microphone" and shows no mic.** Windows microphone
  privacy is off for desktop apps. Set `Value = Allow` on
  `HK{LM,CU}:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone` and
  `HKCU:...\microphone\NonPackaged` (blueprint does), or Settings > Privacy > Microphone > "Allow desktop apps".
- [win] **Routing TTS into Zoom.** `Set-AudioDevice` (AudioDeviceCmdlets) the *system* output to `CABLE Input`;
  `Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak("...")`
  then plays into the cable and Zoom's mic level meter moves with mic = `CABLE Output`. Voices on the VM:
  `Microsoft David Desktop`, `Microsoft Zira Desktop`.
- [win] **Meeting audio would loop back into the mic.** Same as mac/linux: with system output on `CABLE Input`,
  Zoom speaker = "Same as System" feeds the meeting into the mic. Pick speaker = `Hi-Fi Cable Input` (the second,
  independent cable installed by the blueprint), microphone = `CABLE Output`. Zoom remembers it ("Custom combination").
- [win] **Both `zoommtg://` and the Edge web client say "The host has another meeting in progress".** Not a Windows
  problem: another Devin's meeting on the same host account was live (`--list-live` showed it). Zoom desktop keeps
  retrying by itself and joined ~25 min later when that meeting ended (see the [api] entry above).
- [win] **Edge web client: "Automated bots aren't allowed to join this meeting" even in plain Edge.** Unlike plain
  Chrome on Linux/macOS, Zoom's reCAPTCHA check rejects the Devin Windows VM's Edge (cause not identified; the
  desktop app on the same IP joins fine, so it is not the IP alone). Its device picker does list all VB-Audio endpoints, but it cannot join: use the desktop app.
- [win] **First `Start-Process msedge <url>` shows Edge's welcome wizard instead of the page.** Click through
  ("Confirm and continue" / skip import) once. The web client then asks "give Edge access" for the camera: set
  `ConsentStore\webcam` = `Allow` like the microphone key (no camera exists, Edge still needs the permission).
- [win] **`-Verb RunAs` is unnecessary.** The Devin Windows shell is already elevated and UAC (`EnableLUA`) is 0,
  so driver installers and `msiexec` run unattended from a plain `Start-Process -Wait`.

## Devin-side

- [all] **Secrets in builds.** `ZOOM_S2S_*` / `ZOOM_HOST_EMAIL` are personal-scoped: present in sessions, absent
  during snapshot builds. Blueprint `initialize` must not call the API.
- [all] **Blueprint drift banner on a snapshot.** Means the settings-side blueprint differs from
  `.devin/blueprint.yaml` on main. "Sync from repo + build" adopts the file (git-backed mode).
- [all] **Only put commands in a platform's blueprint doc that actually ran on that platform.** macOS and Linux
  each have their own YAML document (`runs-on: macos` vs default); Windows is `runs-on: windows` +
  `shell: powershell`, one `initialize` list item per native installer so a failure is attributed to its step.
- [all] **`python3 -m py_compile` leaves `scripts/__pycache__/`.** Ignored via `.gitignore`.
