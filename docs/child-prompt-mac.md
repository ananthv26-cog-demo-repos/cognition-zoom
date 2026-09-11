# Child prompt template: macOS VM

Fill the `{{...}}` fields and send as the child's *first* message. Everything the child needs is here on
purpose: each mid-run correction in the 2026-09-11 runs cost 5-15 min. Delete the `WISPR` block unless the
parent's own prompt contains the word `wispr`. Start the child only after every secret it needs exists
(`ELEVENLABS_API_KEY`, `FIREWORKS_API_KEY`; plus `WISPR_FLOW_EMAIL`/`WISPR_FLOW_PASSWORD` for a Wispr run).

---

Join a live Zoom meeting from this macOS VM and hold a real spoken conversation with the other Devin
sessions in it. Repo: ananthv26-cog-demo-repos/cognition-zoom (already cloned; work from that checkout,
branch `{{branch, e.g. main}}`).

FIRST ACTION: invoke the repo skill `zoom-meeting` (`.agents/skills/zoom-meeting/SKILL.md`): macOS section
(section 2), the converse.py loop (section 5), the recorder/deliverables in section 6{{, and section 7 (Wispr)}}.

Meeting (created by the parent; do NOT create a new one, do NOT end it):
- id: {{id}}   passcode: {{passcode}}   topic: "{{topic}}"
- join_url: {{join_url}}

You:
- Roster name: exactly `{{Mac VM 1 | Mac VM 2}}` (no "Devin" in the name; captions mishear it).
- Persona (write it to ~/persona.md): {{2-3 sentences: role, what you did this week, what you want from the meeting}}
- Voice: `--voice {{Roger | Sarah}}`
- Others in the meeting: {{"Mac VM 2 (frontend), Windows VM (QA)"}}
- {{You open the conversation once every name above is in the participant list. | You do not open; you speak when addressed (converse.py answers PASS otherwise).}}
- {{You are the recorder: `recording_start` before the conversation and `recording_stop` after leaving. | Take screenshots only; another VM records.}}

SCREEN (hard requirement — applies to every screenshot you send and to the recording):
- Nothing but the meeting may be on screen: no Chrome, no Finder window, no Dock, no wallpaper showing
  between or beside the windows. Auto-hide the Dock once: `defaults write com.apple.dock autohide -bool true; killall Dock`.
- {{Non-Wispr run: the Zoom meeting window maximized (hover the green button > Fill / Zoom), nothing else visible. | Wispr run: clean split screen — Zoom meeting window on the exact left half, Wispr "Meeting Recorder" on the exact right half, flush to the screen edges and to each other. Do NOT maximize Zoom (it covers the transcript).}}
- {{ | Run `scripts/wispr_notetaker.sh layout`: it hides the other apps, tiles both windows and verifies the frames. If it exits non-zero it names the window that is off — hover that window's green button > **Tile Window to Left/Right of Screen** (or drag-resize it) and re-run `scripts/wispr_notetaker.sh layout --verify` until it passes.}}
- Then take a screenshot and *look* at it before continuing. If a window is short, offset, or something shows
  behind it, fix it and screenshot again. Never start the recording, and never send the user a screenshot,
  while the screen is not clean. Re-check after anything that moves a window (a panel, a dialog, a re-join).

Preflight (report and stop if any fails; do not join half-configured):
1. `python3 scripts/converse.py --name "{{name}}" --voice {{voice}} --check` (keys, voice, one model call, ~2 s).
2. `scripts/show_meeting_window.sh --snapshot` must exit 0 (empty output is fine; status 139 = the JXA
   enumeration regression, report it).

Join:
3. `SwitchAudioSource -s "BlackHole 2ch"`, then `scripts/join_zoom.sh "{{join_url}}" "{{name}}"` (blocks until
   the meeting window is up, 30-45 s). If a screenshot shows only the "Zoom Workplace" sign-in window, run
   `scripts/show_meeting_window.sh "{{join_url}}" "{{topic}}" "{{name}}"`. Never sign in; you are a guest.
4. Click Join. **Audio ^ > microphone = BlackHole 2ch, speaker = BlackHole 16ch** (Zoom defaults the speaker to
   2ch = the mic; verify). Captions: {{**More (...) > Show captions ON** | **OFF** (Wispr run: Wispr's live transcript is the proof of speech)}}.

Conversation (section 5; one process, nothing scripted, you steer it):
5. `echo "{{steer, e.g. Keep to 4-5 of your own lines, hand the floor to Windows VM once, then wrap up.}}" > ~/steer.txt`
6. `python3 scripts/converse.py --name "{{name}}" --voice {{voice}} --persona ~/persona.md --roster "{{others}}" --steer ~/steer.txt --log ~/turns.jsonl --max-minutes 10 {{--open "Hi everyone, {{name}} here. Quick standup: Mac VM 2, what are you working on?" | (no --open)}}`
   in its own shell with a 12-min timeout. While it runs: `tail -f ~/turns.jsonl`; append lines to ~/steer.txt to
   steer ("ask Windows VM about the release"); append `STOP` to take over with listen.py/speak.py. Screenshot the
   participant list with every name (open it with Participants/⌘U only if it is closed, then close it again with
   its X or ⌘U — leaving it docked covers the right half of the screen), and {{the captions panel | Wispr's live
   transcript}} showing your line and another Devin's line.
7. Leave (**Leave > Leave meeting**, then `pkill -x zoom.us`). Do NOT end the meeting for everyone.

WISPR (only because the parent prompt says "wispr"; both Mac VMs do this, before step 3):
- `scripts/wispr_notetaker.sh install && scripts/wispr_notetaker.sh devices && scripts/wispr_notetaker.sh launch`
- Sign in: app > **Sign in via browser** > **Continue with Google** (never the email+password form: its hCaptcha
  spins forever in Safari). Credentials: `WISPR_FLOW_EMAIL` / `WISPR_FLOW_PASSWORD` via `printenv X | pbcopy` +
  Cmd-V; never print, log or screenshot them. After "You're now logged in", click **Sign in via browser** a
  second time (or Safari's **Open Wispr Flow** twice) so the app receives the session. Budget 5 min, then report
  the screen and continue without Wispr.
- Onboarding: Microphone and System Audio Recording are plain Allow dialogs. The Accessibility toggle asks for
  a password: `scripts/wispr_notetaker.sh authdb grant`, flip the toggle in System Settings, then immediately
  `scripts/wispr_notetaker.sh authdb restore`. If it still prompts, screenshot and report; never guess a password.
- Test before Zoom: menu bar **Notetaker > Start new note**, `say -a "BlackHole 2ch" "Wispr test one two three"`,
  the line appears in the live transcript in ~5 s. Stop the note (green Stop, two clicks; "Keep").
- After joining Zoom (captions OFF): **Notetaker > Start new note** from the menu bar (do not click toast
  buttons; they fall through), then close the Zoom participants panel (⌘U) and run
  `scripts/wispr_notetaker.sh layout`, then verify the split per SCREEN above before recording anything. Keep the
  participants panel closed for the rest of the meeting: docked, it widens Zoom over the right half and hides
  Wispr's live transcript in every screenshot and in the recording.
- After the conversation: Stop the note, wait for the Summary (~20 s) and the refined transcript (~1 min), copy
  each (copy icon) to `~/wispr_transcript.txt` / `~/wispr_summary.txt` via `pbpaste`, attach both. Expect your
  own TTS lines to be labelled "Them" live; that is known and not to be debugged. Report what the refined
  transcript's Speaker 1/Speaker 2 split looks like.

Deliverables (message_user with attachments; also fill the structured output): {{recording |} screenshots, `~/turns.jsonl`
(and the median heard->said latency from it){{, `~/wispr_transcript.txt`, `~/wispr_summary.txt`}}. Report honestly if
any step failed; do not spend more than 10 min on any single blocker.
