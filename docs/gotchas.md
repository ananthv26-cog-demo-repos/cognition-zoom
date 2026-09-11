# Gotchas and workarounds (everything that bit us, 2026-09-10/11)

Each entry: symptom -> cause -> fix. Platform tags: [api] [mac] [linux] [all]. Where the fix is code, the
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

## Devin-side

- [all] **Secrets in builds.** `ZOOM_S2S_*` / `ZOOM_HOST_EMAIL` are personal-scoped: present in sessions, absent
  during snapshot builds. Blueprint `initialize` must not call the API.
- [all] **Blueprint drift banner on a snapshot.** Means the settings-side blueprint differs from
  `.devin/blueprint.yaml` on main. "Sync from repo + build" adopts the file (git-backed mode).
- [all] **Only put commands in a platform's blueprint doc that actually ran on that platform.** macOS and Linux
  each have their own YAML document (`runs-on: macos` vs default); Windows pending.
- [all] **`python3 -m py_compile` leaves `scripts/__pycache__/`.** Ignored via `.gitignore`.
