#!/usr/bin/env python3
"""Transcribe what the Zoom meeting is saying (ElevenLabs Scribe STT) from the virtual speaker device.

  scripts/listen.py --seconds 15                 # record the meeting for 15 s, print the transcript
  scripts/listen.py --file meeting.wav           # transcribe an existing file
  scripts/listen.py --seconds 10 --json          # words with speaker_id + timestamps

Capture path (the speaker device join_zoom.sh tells you to pick in Zoom):
  linux: parecord --device=zoom_out.monitor       (Zoom speaker = ZoomOut)
  macos: ffmpeg -f avfoundation -i ":BlackHole 16ch" (Zoom speaker = BlackHole 16ch; needs `brew install ffmpeg`)
Keyterms bias the model towards our names so "Devin" does not come back as Devon/Kevin. Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import uuid

API = "https://api.elevenlabs.io/v1"
MODEL = os.environ.get("ELEVENLABS_STT_MODEL", "scribe_v2")
KEYTERMS = ["Devin", "Devin 1", "Devin 2", "Devin 3", "Cognition", "Wispr Flow", "Zoom"]
MISHEARD = re.compile(r"\b(Devon|Devan|Deven|Kevin|Divin|Devin's|Devon's)\b(?=\s*(\d|one|two|three|\.|,|!|\?|$|\s))", re.I)
LINUX_SOURCE = os.environ.get("ZOOM_OUT_SOURCE", "zoom_out.monitor")


def record(seconds: int, path: str) -> None:
    if platform.system() == "Darwin":
        cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "avfoundation", "-i", ":BlackHole 16ch",
               "-t", str(seconds), "-ac", "1", "-ar", "16000", path]
    else:
        cmd = ["parecord", f"--device={LINUX_SOURCE}", "--file-format=wav", "--channels=1", "--rate=16000",
               f"--process-time-msec={seconds * 1000}", path]
        cmd = ["timeout", "--preserve-status", str(seconds), *cmd[:-1], path]
    subprocess.run(cmd, check=False)
    if not os.path.exists(path) or os.path.getsize(path) < 1000:
        sys.exit(f"recording failed or empty: {path}")


def transcribe(path: str) -> dict:
    key = os.environ.get("ELEVENLABS_API_KEY") or sys.exit("ELEVENLABS_API_KEY not set")
    boundary = uuid.uuid4().hex
    parts: list[bytes] = []

    def field(name: str, value: str) -> None:
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode())

    field("model_id", MODEL)
    field("language_code", "en")
    field("diarize", "true")
    field("tag_audio_events", "false")
    for k in KEYTERMS:
        field("keyterms", k)
    with open(path, "rb") as f:
        parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{os.path.basename(path)}\"\r\n"
            f"Content-Type: audio/wav\r\n\r\n".encode() + f.read() + b"\r\n"
        )
    parts.append(f"--{boundary}--\r\n".encode())
    req = urllib.request.Request(
        f"{API}/speech-to-text", data=b"".join(parts), method="POST",
        headers={"xi-api-key": key, "Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        sys.exit(f"POST /speech-to-text -> HTTP {e.code}: {e.read().decode(errors='replace')[:300]}")


def fix_names(text: str) -> str:
    return MISHEARD.sub(lambda m: "Devin's" if m.group(1).lower().endswith("'s") else "Devin", text)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--seconds", type=int, help="record the meeting audio for N seconds")
    src.add_argument("--file", help="transcribe this audio file instead of recording")
    ap.add_argument("--keep", help="save the recording to this path")
    ap.add_argument("--json", action="store_true", help="print the raw Scribe response")
    a = ap.parse_args()

    path = a.file or a.keep or tempfile.mkstemp(suffix=".wav", prefix="listen-")[1]
    if a.seconds:
        record(a.seconds, path)
    result = transcribe(path)
    if a.seconds and not a.keep:
        os.unlink(path)

    if a.json:
        print(json.dumps(result, indent=2))
        return
    text = fix_names(result.get("text", ""))
    print(text if text else "(silence)")


if __name__ == "__main__":
    main()
