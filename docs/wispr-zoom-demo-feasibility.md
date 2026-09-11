# Wispr Flow x Devin: 3 Mac VMs on one Zoom call

## Verdict

Both ideas are feasible on Devin macOS VMs without any hypervisor changes. BlackHole is the key piece and it works in a VM that has no audio hardware because it is a user-space CoreAudio HAL plugin, not a kernel extension and not a hardware device. The recommended path is a 1-session spike on a single Mac VM, then scale to three.

## Verified facts (from devin-webapp source and warehouse data)

Mac VM platform (`apps/devin/firecracker/macos-hypervisor`, `mac-image-py`):
- Virtualization.framework VM. Devices attached: NBD/virtio block disk, Mac graphics, virtio network, trackpad, USB keyboard, vsock, VirtioFS share. There is no `VZVirtioSoundDeviceConfiguration`, so the guest boots with zero audio devices.
- Guest is macOS 26.5.2. User `devin` has passwordless sudo. Homebrew, Chrome, ffmpeg, node, python are preinstalled. Chrome has its quarantine xattr stripped so it launches without Gatekeeper prompts.
- TCC pre-grants cover only `devin-remote` (Screen Capture, Accessibility, Post/Listen Event, Developer Tools). There is no Microphone grant for anything. Zoom, Chrome, and Wispr Flow will each show a mic permission prompt on first use, which Devin can click through with computer use.
- `corespeechd` is disabled in the image. This does not affect BlackHole, Zoom, or third-party STT/TTS; it only affects Apple's own on-device speech services.
- macOS sessions are gated per org by the `macos-devin-creation` Unleash flag (`apps/webserver/utils/machine_config.py`). The deployed-engineering org has 0 macOS sessions on record, so the flag is likely not on here yet. Wispr Flow's org has 47 macOS sessions in the last 60 days.

Wispr Flow's own sessions (metadata only, message content is redacted cross-org):
- "setup mac", "End-to-end dictation keyboard test" (98 browser actions, completed), "Verify Notetaker iOS dictation tab" (50 browser actions, recorded), "Implement permission onboarding drag icon", "Update macOS Blueprint Chrome", plus Notetaker PR monitoring.
- Takeaway: they already run Flow desktop QA and dictation E2E on our Mac VMs, and they already deal with the permission onboarding flow (mic + accessibility) inside the VM. Whether they used BlackHole to feed audio into dictation tests is not visible in the data.

## Audio architecture (per VM)

Install two BlackHole devices so send and receive never share a device (prevents self-echo):
- `brew install --cask blackhole-2ch blackhole-16ch` (needs sudo, which we have; restarts coreaudiod)
- BlackHole 2ch = "mouth": Zoom microphone input
- BlackHole 16ch = "ears": Zoom speaker output; Wispr Flow and/or ffmpeg capture from here

```
TTS (ElevenLabs / OpenAI / macOS say) --afplay--> BlackHole 2ch --> Zoom mic
Zoom speaker --> BlackHole 16ch --> Wispr Flow (input device) --> typed transcript --> Devin reads it
                                 \-> ffmpeg avfoundation capture --> STT or Realtime API
```

Zoom: either the desktop client (`Zoom.pkg` from zoom.us, join as guest via meeting link + passcode, display name "Devin 1/2/3") or the web client in Chrome. Desktop client gives clean device selection; web client avoids an install. Both should work.

## Demo option A: Wispr Flow is Devin's ears (best fit for Wispr)

1. Each VM joins the same Zoom meeting.
2. To speak, Devin generates audio (ElevenLabs for quality, or `say` for zero deps) and plays it to BlackHole 2ch.
3. To listen, Wispr Flow's input device is set to BlackHole 16ch and its hotkey is held (or hands-free mode is on). Flow types the transcript into a focused TextEdit window or a file. Devin reads it and composes a reply.
4. Turn-taking: address by name ("Devin 2, what are you working on?"). Each Devin only speaks when addressed. Expect 15 to 30 seconds per turn because it goes through the full agent loop. Frame it as a standup, not a chat.

Why this is the wow: Flow is literally the product doing the hearing, on screen, in three VMs at once.

## Demo option B: live voice with a realtime model

Devin writes and runs a small bridge (Python or Node, ~150 lines) on each VM:
- capture BlackHole 16ch with `ffmpeg -f avfoundation -i ":BlackHole 16ch"` (16 kHz PCM)
- stream to the OpenAI Realtime API over WebSocket (speech in, speech out)
- play returned PCM to BlackHole 2ch

Sub-second turns, natural interruptions. The voice on the call is the realtime model wearing a persona; ground it in what Devin is actually doing via a tool call that reads a status file Devin updates (or hits the Devin API for the session). ElevenLabs can slot in two ways: as the TTS engine in option A (best voice quality), or via their Agents product for the full speech-to-speech loop. API specifics for both vendors should be confirmed against current docs before the spike; I have not verified them in this session.

Options A and B compose: A for the "Flow as ears" moment, B for a live back-and-forth finale.

## Unverified risks (all checkable in the spike)

1. coreaudiod enumerates BlackHole in a VM with zero physical audio devices. I believe yes; this is the first thing to test.
2. Zoom guest join and device selection inside the VM (Zoom runs fine in VMs generally).
3. Wispr Flow's default Fn hotkey through the virtual USB keyboard. Mitigation: set a custom hotkey or use hands-free mode.
4. Mic permission prompts for Zoom, Chrome, Flow. Mitigation: click Allow via computer use.
5. If BlackHole fails, fallback is a small hypervisor change: add `VZVirtioSoundDeviceConfiguration` in `configuration.rs` so the guest gets a virtio audio device. Not expected to be needed.

## What is needed before the spike

- macOS platform enabled for the org running the demo (flag), or run it in Wispr Flow's org.
- Network egress from the Mac VMs: zoom.us (and subdomains), api.openai.com, api.elevenlabs.io, github.com (BlackHole cask download), Wispr Flow's endpoints.
- Credentials: a Zoom meeting hosted by a human account, OpenAI and ElevenLabs API keys, three Wispr Flow logins.

## Estimate

- Spike, 1 session: one Mac VM installs BlackHole, joins a Zoom call, says a sentence a human hears, and Flow transcribes what the human says back.
- Option A with 3 VMs, 1 to 2 sessions: orchestrated from a parent session (or a workflow) that hands each child the meeting link, persona, and turn rule.
- Option B bridge, 1 session.
- External waits dominate: flag, network allowlist, API keys, Flow accounts.
