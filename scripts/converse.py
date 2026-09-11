#!/usr/bin/env python3
"""Hold a conversation in the Zoom meeting from one process: listen -> think -> speak, ~5-8 s per turn.

  scripts/converse.py --name "Mac VM 1" --voice Roger --persona persona.md \
      --open "Hi everyone, Mac VM 1 here. Mac VM 2, what are you working on?" \
      --steer ~/steer.txt --log ~/turns.jsonl --max-minutes 10

Why: one turn of the "listen.py -> Devin reasons -> speak.py" loop costs a whole agent step (20-40 s of
screenshots and tool round-trips). This runs the same loop in-process: the reply for each turn is generated
live by an LLM from the persona, the running transcript and the steer file, so nothing is scripted, and
the Devin driving it stays in charge: it writes the persona and goals, appends steering lines to --steer
between turns ("wrap up after your next line", "ask about the release cut"), reads --log, and can stop the
loop (a line `STOP` in the steer file, or a plain kill) and take over with listen.py/speak.py at any time.

Per turn: listen.until_silence(--silence, default 1.2 s) -> Scribe transcript (listen.transcribe) -> chat
completion (FIREWORKS_API_KEY on Fireworks' OpenAI-compatible endpoint; ZOOM_LLM_MODEL overrides the
model, default GLM 5.3 fast, ~1 s) -> ElevenLabs wav (speak.tts_wav) ->
speak.wait_for_turn + speak.play into the Zoom mic device. The model may answer PASS (stay quiet: the line
was not for you) or end its line with DONE (it has said goodbye; the loop exits). Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import listen  # noqa: E402
import speak  # noqa: E402

LLM_API = "https://api.fireworks.ai/inference/v1"
# Probed 2026-09: glm-5p3-fast 0.5-1.2 s/turn, deepseek-v4p1-flash 0.6-1.7 s, kimi-k3-fast 1.4-5 s; all follow
# the SAY: format. gpt-oss/nemotron put the whole answer in reasoning and are unusable here.
MODEL = os.environ.get("ZOOM_LLM_MODEL", "accounts/fireworks/routers/glm-5p3-fast")

RULES = """You are {name}, a participant in a live Zoom meeting with other engineers. Everything you output is
spoken aloud by text-to-speech, so: plain spoken English, no markdown, no stage directions, 1-3 sentences
(under ~45 words), address people by their roster name when replying to them, never repeat something you
already said, do not narrate that you are an AI or a script. Only speak when the last line was addressed to
you, asked the group something you can answer, or the conversation clearly stalled; otherwise stay quiet.
When the meeting is wrapping up and you have said your goodbye, end your line with the word DONE.
Roster: {roster}. The transcript labels your own past lines "You" and everyone else "Them" (speech-to-text,
names may be misheard: Devon/Kevin = Devin).
Answer format: think as much as you like, then the LAST line of your answer must be either
`SAY: <the exact words to speak>` or `SAY: PASS` (stay quiet). Nothing after that line."""


def llm(messages: list[dict]) -> str:
    key = os.environ.get("FIREWORKS_API_KEY")
    if not key:
        raise RuntimeError("FIREWORKS_API_KEY not set")
    req = urllib.request.Request(
        f"{LLM_API}/chat/completions",
        data=json.dumps({"model": MODEL, "messages": messages, "max_tokens": 600, "temperature": 0.9}).encode(),
        method="POST",
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"chat/completions -> HTTP {e.code}: {e.read().decode(errors='replace')[:300]}")
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise RuntimeError(f"chat/completions failed: {e}")
    try:
        msg = body["choices"][0]["message"]
        content = msg.get("content") or ""
    except (KeyError, IndexError, TypeError, AttributeError):
        raise RuntimeError(f"chat/completions: unexpected body {json.dumps(body)[:300]}")
    return spoken_line(content)


def spoken_line(content: str) -> str:
    """The `SAY:` line of a reply, or PASS. Reasoning models think out loud (or put everything in
    reasoning_content and leave content empty): anything that is not a SAY: line is never spoken."""
    for line in reversed(content.strip().splitlines()):
        line = line.strip().strip("*`")
        if line.upper().startswith("SAY:"):
            text = line[4:].strip().strip('"')
            return text if text and text.upper().rstrip(".") != "PASS" else "PASS"
    return "PASS"


def read_file(path: str | None) -> str:
    if not path or not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().strip()


def transcribe_pcm(pcm: bytes) -> str:
    fd, path = tempfile.mkstemp(suffix=".wav", prefix="converse-")
    os.close(fd)
    try:
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(listen.RATE)
            w.writeframes(pcm)
        return listen.fix_names(listen.transcribe(path).get("text", "")).strip()
    finally:
        os.unlink(path)


class Conversation:
    def __init__(self, a: argparse.Namespace) -> None:
        self.a = a
        self.transcript: list[tuple[str, str]] = []  # ("You" | "Them", text)
        self.voice_id = speak.resolve_voice(a.voice) if os.environ.get("ELEVENLABS_API_KEY") else None
        self.said = 0
        self.log = open(a.log, "a", encoding="utf-8") if a.log else None

    def record(self, kind: str, text: str, **extra) -> None:
        print(f"[{time.strftime('%H:%M:%S')}] {kind}: {text}", flush=True)
        if self.log:
            self.log.write(json.dumps({"t": time.time(), "kind": kind, "text": text, **extra}) + "\n")
            self.log.flush()

    def steer(self) -> str:
        return read_file(self.a.steer)

    def stopped(self) -> bool:
        return any(line.strip() == "STOP" for line in self.steer().splitlines())

    def decide(self, stalled: bool) -> str:
        persona = read_file(self.a.persona) or f"You are {self.a.name}, an engineer giving a short standup update."
        system = RULES.format(name=self.a.name, roster=self.a.roster or "unknown") + "\n\nPersona and goals:\n" + persona
        if steer := self.steer():
            system += "\n\nLive instructions from the engineer driving you (follow the latest ones):\n" + steer
        lines = "\n".join(f"{who}: {text}" for who, text in self.transcript[-30:]) or "(nothing yet)"
        ask = ("Nobody has spoken for a while. Say something short that moves the meeting along, or SAY: PASS."
               if stalled else "What do you say next? End with your SAY: line (or SAY: PASS).")
        return llm([{"role": "system", "content": system},
                    {"role": "user", "content": f"Transcript so far:\n{lines}\n\n{ask}"}])

    def say(self, text: str) -> None:
        text = text.strip()
        done = text.endswith("DONE")
        text = text[: -len("DONE")].rstrip(" .,;") + "." if done else text
        try:
            if self.voice_id is None:
                raise RuntimeError("ELEVENLABS_API_KEY not set")
            wav = speak.tts_wav(text, self.voice_id, self.a.model)
        except RuntimeError as e:
            self.record("warn", f"elevenlabs unavailable ({e}); system TTS")
            speak.wait_for_turn(self.a.max_wait)
            speak.fallback(text)
        else:
            fd, path = tempfile.mkstemp(suffix=".wav", prefix="converse-")
            os.close(fd)
            try:
                with open(path, "wb") as f:
                    f.write(wav)
                speak.wait_for_turn(self.a.max_wait)
                speak.play(path)
            finally:
                os.unlink(path)
        self.transcript.append(("You", text))
        self.said += 1
        self.record("said", text, done=done)
        if done:
            raise SystemExit(0)

    def run(self) -> None:
        deadline = time.monotonic() + self.a.max_minutes * 60
        if self.a.open:
            self.say(self.a.open)
        empty = 0
        while time.monotonic() < deadline and self.said < self.a.max_turns:
            if self.stopped():
                self.record("info", "STOP in steer file; exiting")
                return
            try:
                pcm = listen.until_silence(self.a.silence, min(self.a.listen_max, deadline - time.monotonic()))
            except listen.CaptureError as e:
                sys.exit(f"cannot hear the meeting ({e}); check the Zoom speaker device / recorder")
            if pcm is None:
                empty += 1
                self.record("info", f"nobody spoke for {self.a.listen_max:g}s ({empty})")
                if empty < self.a.stall_after:
                    continue
                empty = 0
                heard = ""
            else:
                empty = 0
                heard = transcribe_pcm(pcm)
                if not heard:
                    self.record("info", "speech without words (noise); ignoring")
                    continue
                self.transcript.append(("Them", heard))
                self.record("heard", heard)
            try:
                reply = self.decide(stalled=not heard)
            except RuntimeError as e:
                self.record("warn", f"LLM failed ({e}); staying quiet this turn")
                continue
            if reply == "PASS":
                self.record("pass", "(not addressed to me)")
                continue
            self.say(reply)
        self.record("info", "time or turn budget reached; exiting")


def check(a: argparse.Namespace) -> None:
    """Preflight without touching the meeting: keys present, voice resolves, the model answers in SAY: form."""
    t0 = time.monotonic()
    voice = speak.resolve_voice(a.voice)
    print(f"elevenlabs: voice {a.voice} -> {voice} ({time.monotonic() - t0:.1f}s)")
    t0 = time.monotonic()
    reply = llm([{"role": "system", "content": RULES.format(name=a.name, roster=a.roster or "Mac VM 2")},
                 {"role": "user", "content": "Transcript so far:\nThem: Hi, how is the build looking today?\n\n"
                                             "What do you say next? End with your SAY: line (or SAY: PASS)."}])
    print(f"fireworks: {MODEL} -> {reply!r} ({time.monotonic() - t0:.1f}s)")
    if reply == "PASS":
        sys.exit("model answered PASS to a direct question; check ZOOM_LLM_MODEL (see the list in this file)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", required=True, help='roster name, e.g. "Mac VM 1"')
    ap.add_argument("--check", action="store_true", help="preflight: keys, voice and one model call; do not join the loop")
    ap.add_argument("--voice", default=os.environ.get("ELEVENLABS_VOICE", speak.DEFAULT_VOICE))
    ap.add_argument("--model", default=os.environ.get("ELEVENLABS_MODEL", speak.DEFAULT_MODEL), help="ElevenLabs model")
    ap.add_argument("--persona", help="file: who you are, what you worked on, what you want from this meeting")
    ap.add_argument("--roster", help='who else is in the meeting, e.g. "Mac VM 2 (frontend), Windows VM (QA)"')
    ap.add_argument("--open", help="say this first instead of waiting for someone else to start")
    ap.add_argument("--steer", help="file re-read every turn: live instructions; a line `STOP` ends the loop")
    ap.add_argument("--log", help="append one JSON line per heard/said/pass event")
    ap.add_argument("--silence", type=float, default=1.2, help="seconds of quiet that end the other speaker's turn")
    ap.add_argument("--listen-max", type=float, default=45, help="give up one listen after N s of nobody talking")
    ap.add_argument("--stall-after", type=int, default=2, help="empty listens before asking the model to fill the gap")
    ap.add_argument("--max-wait", type=float, default=20, help="speak anyway after waiting N s for a gap")
    ap.add_argument("--max-turns", type=int, default=12, help="stop after saying this many lines")
    ap.add_argument("--max-minutes", type=float, default=12)
    a = ap.parse_args()
    for name in ("silence", "listen_max", "max_wait", "max_minutes"):
        if not (0 < getattr(a, name) < 3600):
            ap.error(f"--{name.replace('_', '-')} must be between 0 and 3600")
    if a.max_turns < 1 or a.stall_after < 1:
        ap.error("--max-turns and --stall-after must be >= 1")
    if not os.environ.get("ELEVENLABS_API_KEY"):
        sys.exit("ELEVENLABS_API_KEY not set (listen.py has no offline STT)")
    if not os.environ.get("FIREWORKS_API_KEY"):
        sys.exit("FIREWORKS_API_KEY not set (the reply for each turn comes from a chat model)")
    if a.check:
        check(a)
        return
    Conversation(a).run()


if __name__ == "__main__":
    main()
