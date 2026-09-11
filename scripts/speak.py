#!/usr/bin/env python3
"""Speak text into the Zoom microphone with a natural ElevenLabs voice.

  ELEVENLABS_API_KEY=... scripts/speak.py "Hi everyone, this is Devin two."
  scripts/speak.py --voice Roger --wav-out line.wav "..."   # keep the wav
  scripts/speak.py --list-voices
  scripts/speak.py --if-quiet "..."       # wait a random 0.5-2 s; back off if someone else is talking

--if-quiet is the turn-taking half of listen.py --until-silence: the wav is synthesised first, then the
meeting audio is watched for a random 0.5-2 s (so two Devins that stop listening at the same moment
don't start together); if someone speaks, wait for them to finish and retry, up to --max-wait seconds.

Audio path (same devices join_zoom.sh sets up):
  linux:   paplay --device=devin_mic <wav>          (DevinMicSrc is Zoom's mic)
  macos:   afplay <wav>  with system output = BlackHole 2ch (SwitchAudioSource -s "BlackHole 2ch")
  windows: System.Media.SoundPlayer <wav> on the default output = CABLE Input (the blueprint sets it; Zoom mic = CABLE Output)
Falls back to espeak-ng / say / System.Speech when ELEVENLABS_API_KEY is unset or the API call fails, so a demo never
goes silent. Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import listen  # noqa: E402

API = "https://api.elevenlabs.io/v1"
DEFAULT_MODEL = "eleven_turbo_v2_5"
DEFAULT_VOICE = "Sarah"
RATE = 24000  # output_format=pcm_24000 -> 16-bit mono PCM
LINUX_SINK = os.environ.get("ZOOM_MIC_SINK", "devin_mic")


def api(method: str, path: str, body: dict | None = None) -> bytes:
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        raise RuntimeError("ELEVENLABS_API_KEY not set")
    req = urllib.request.Request(
        f"{API}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"xi-api-key": key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {e.read().decode(errors='replace')[:300]}")
    except (urllib.error.URLError, OSError) as e:  # DNS, refused, timeout
        raise RuntimeError(f"{method} {path} failed: {e}")


def list_voices() -> list[dict]:
    try:
        return json.loads(api("GET", "/voices"))["voices"]
    except (ValueError, KeyError) as e:
        raise RuntimeError(f"GET /voices returned unexpected body: {e}")


def resolve_voice(name_or_id: str) -> str:
    if len(name_or_id) >= 20 and " " not in name_or_id:
        return name_or_id
    for v in list_voices():  # names look like "Roger - Laid-Back, Casual, Resonant"
        if v["name"].split(" - ")[0].strip().lower() == name_or_id.lower():
            return v["voice_id"]
    sys.exit(f"no ElevenLabs voice named {name_or_id!r}; try --list-voices")


def tts_wav(text: str, voice: str, model: str) -> bytes:
    pcm = api(
        "POST",
        f"/text-to-speech/{resolve_voice(voice)}?output_format=pcm_{RATE}",
        {"text": text, "model_id": model},
    )
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + len(pcm), b"WAVE", b"fmt ", 16, 1, 1, RATE, RATE * 2, 2, 16, b"data", len(pcm),
    )
    return header + pcm


def ps(script: str) -> None:
    subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", script], check=True)


def ps_quote(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def arm_mic_approver() -> None:
    """Re-arm the TCC auto-approver: the first audio raises the devin-remote
    "would like to access the Microphone" dialog. The script is a
    singleton (lock dir) so repeat calls are cheap."""
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "approve_mic_prompts.sh")
    if os.path.exists(helper):
        subprocess.Popen([helper], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def play(wav_path: str) -> None:
    if platform.system() == "Darwin":
        arm_mic_approver()
        subprocess.run(["afplay", wav_path], check=True)
    elif platform.system() == "Windows":
        ps(f"(New-Object System.Media.SoundPlayer {ps_quote(os.path.abspath(wav_path))}).PlaySync()")
    else:
        subprocess.run(["paplay", f"--device={LINUX_SINK}", wav_path], check=True)


def wait_for_turn(max_wait: float) -> None:
    """Block until the meeting has been quiet for a random 0.5-2 s (or max_wait elapses)."""
    deadline = time.monotonic() + max_wait
    try:
        while (remaining := deadline - time.monotonic()) > 0:
            if listen.is_quiet(min(random.uniform(0.5, 2.0), remaining)):
                return
            print("someone is talking; waiting for them to finish", file=sys.stderr)
            if (remaining := deadline - time.monotonic()) > 0:
                listen.until_silence(1.5, remaining, keep=False, heard=True)
    except listen.CaptureError as e:
        sys.exit(f"--if-quiet cannot hear the meeting ({e}); check the Zoom speaker device / recorder")
    print(f"still busy after {max_wait:g}s; speaking anyway", file=sys.stderr)


def fallback(text: str) -> None:
    if platform.system() == "Darwin":
        arm_mic_approver()   # say -a raises the same devin-remote mic TCC prompt
        cmd = ["say", "-a", "BlackHole 2ch", text]
    elif platform.system() == "Windows":
        try:
            ps("Add-Type -AssemblyName System.Speech; "
               f"(New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak({ps_quote(text)})")
        except subprocess.CalledProcessError as e:
            sys.exit(f"fallback TTS System.Speech exited {e.returncode}")
        return
    elif shutil.which("espeak-ng"):
        cmd = ["espeak-ng", text]
    else:
        sys.exit("no TTS available (set ELEVENLABS_API_KEY or install espeak-ng)")
    rc = subprocess.run(cmd, env={**os.environ, "PULSE_SINK": LINUX_SINK}).returncode
    if rc:
        sys.exit(f"fallback TTS {cmd[0]} exited {rc}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("text", nargs="?")
    ap.add_argument("--voice", default=os.environ.get("ELEVENLABS_VOICE", DEFAULT_VOICE), help="voice name or id")
    ap.add_argument("--model", default=os.environ.get("ELEVENLABS_MODEL", DEFAULT_MODEL))
    ap.add_argument("--wav-out", help="also save the generated wav here")
    ap.add_argument("--no-play", action="store_true")
    ap.add_argument("--if-quiet", action="store_true", help="wait for a gap in the meeting audio before playing")
    ap.add_argument("--max-wait", type=float, default=30, help="give up waiting for a gap after N s (default 30)")
    ap.add_argument("--list-voices", action="store_true")
    a = ap.parse_args()
    if not (0 < a.max_wait < 3600):
        ap.error("--max-wait must be between 0 and 3600 seconds")

    if a.list_voices:
        for v in list_voices():
            print(f"{v['voice_id']}  {v['name']:<12} {v.get('labels', {}).get('gender', ''):<8} {v.get('labels', {}).get('accent', '')}")
        return
    if not a.text:
        ap.error("text is required")

    try:
        wav = tts_wav(a.text, a.voice, a.model)
    except RuntimeError as e:
        if a.no_play:
            sys.exit(f"elevenlabs unavailable ({e}); nothing to write")
        print(f"elevenlabs unavailable ({e}); falling back to system TTS", file=sys.stderr)
        if a.if_quiet:
            wait_for_turn(a.max_wait)
        fallback(a.text)
        return

    if a.wav_out:
        path = a.wav_out
    else:
        fd, path = tempfile.mkstemp(suffix=".wav", prefix="speak-")
        os.close(fd)
    try:
        with open(path, "wb") as f:
            f.write(wav)
        print(f"{len(wav) // 2 / RATE:.1f}s of audio -> {path}")
        if not a.no_play:
            if a.if_quiet:
                wait_for_turn(a.max_wait)
            play(path)
    finally:
        if not a.wav_out:
            os.unlink(path)


if __name__ == "__main__":
    main()
