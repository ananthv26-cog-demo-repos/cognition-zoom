#!/usr/bin/env python3
"""Transcribe what the Zoom meeting is saying (ElevenLabs Scribe STT) from the virtual speaker device.

  scripts/listen.py --seconds 15                 # record the meeting for 15 s, print the transcript
  scripts/listen.py --file meeting.wav           # transcribe an existing file
  scripts/listen.py --seconds 10 --json          # words with speaker_id + timestamps
  scripts/listen.py --until-silence 2            # wait for someone to talk, stop 2 s after they finish

Turn-taking (what a human does): `--until-silence` returns the moment the current speaker stops, so a
Devin can read the transcript, decide its reply and call speak.py --if-quiet, which re-checks the line
for a random 0.5-2 s before talking and backs off if someone else started first.

Capture path (the speaker device join_zoom.sh tells you to pick in Zoom):
  linux:   parecord --device=zoom_out.monitor       (Zoom speaker = ZoomOut)
  macos:   ffmpeg -f avfoundation -i ":BlackHole 16ch" (Zoom speaker = BlackHole 16ch; needs `brew install ffmpeg`)
  windows: ffmpeg -f dshow -i audio="Hi-Fi Cable Output (VB-Audio Hi-Fi Cable)"  (Zoom speaker = Hi-Fi Cable Input;
           ffmpeg from the windows blueprint; ZOOM_OUT_DSHOW overrides the device name)
Keyterms bias the model towards our names so "Devin" does not come back as Devon/Kevin. Stdlib only.
"""
from __future__ import annotations

import argparse
import array
import json
import math
import os
import platform
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
import wave

API = "https://api.elevenlabs.io/v1"
MODEL = os.environ.get("ELEVENLABS_STT_MODEL", "scribe_v2")
KEYTERMS = ["Devin", "Devin 1", "Devin 2", "Devin 3", "Cognition", "Wispr Flow", "Zoom"]
# Only rewrite when the word is used as one of our participant names ("Kevin 3", "Devon two"), so a real
# Kevin in ordinary prose is left alone.
MISHEARD = re.compile(r"\b(Devon|Devan|Deven|Kevin|Divin)('s)?(?=\s+(\d+|one|two|three)\b)", re.I)
LINUX_SOURCE = os.environ.get("ZOOM_OUT_SOURCE", "zoom_out.monitor")
WIN_SOURCE = os.environ.get("ZOOM_OUT_DSHOW", "Hi-Fi Cable Output (VB-Audio Hi-Fi Cable)")
RATE = 16000
FRAME = RATE // 10  # 100 ms of s16le mono
SPEECH_RMS = int(os.environ.get("ZOOM_SPEECH_RMS", "300"))  # Zoom's decoded speech sits around 1000-4000


class CaptureError(RuntimeError):
    """The recorder died or stopped delivering audio: the state of the line is unknown, not silent."""


def rms(buf: bytes) -> int:
    samples = array.array("h", buf)
    return int(math.sqrt(sum(s * s for s in samples) / len(samples))) if samples else 0


def ffmpeg_input() -> list[str] | None:
    """ffmpeg input args for the Zoom speaker device on macOS / Windows; None on Linux (parecord)."""
    if platform.system() == "Darwin":
        return ["-f", "avfoundation", "-i", ":BlackHole 16ch"]
    if platform.system() == "Windows":
        # dshow buffers ~500 ms by default; 100 ms keeps turn detection responsive
        return ["-f", "dshow", "-audio_buffer_size", "100", "-i", f"audio={WIN_SOURCE}"]
    return None


class Capture:
    """Raw s16le mono 16 kHz from the virtual speaker device, 100 ms frames via a reader thread so callers
    can enforce wall-clock deadlines even when the recorder stalls."""

    def __init__(self) -> None:
        if (src := ffmpeg_input()) is not None:
            cmd = ["ffmpeg", "-loglevel", "error", *src, "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-"]
        else:
            # default record latency is ~2 s of buffering, far too laggy for turn detection
            cmd = ["parecord", f"--device={LINUX_SOURCE}", "--raw", "--format=s16le", "--channels=1",
                   f"--rate={RATE}", "--latency-msec=100"]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
        self.q: queue.Queue[bytes | None] = queue.Queue()
        self.pump = threading.Thread(target=self._pump, daemon=True)
        self.pump.start()

    def _pump(self) -> None:
        # sole owner of the pipe: closes it on EOF, so teardown never closes it under a blocked read
        with self.proc.stdout as out:
            while True:
                buf = out.read(FRAME * 2)
                if len(buf) < FRAME * 2:
                    self.q.put(None)
                    return
                self.q.put(buf)

    def frames(self, deadline: float):
        """Yield (pcm, rms) until `deadline` (monotonic). Raises CaptureError on recorder EOF or a 3 s stall."""
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            try:
                buf = self.q.get(timeout=min(remaining, 3.0))
            except queue.Empty:
                if time.monotonic() >= deadline:
                    return
                raise CaptureError("recorder produced no audio for 3 s")
            if buf is None:
                raise CaptureError(f"recorder exited with status {self.proc.wait()}")
            yield buf, rms(buf)

    def __enter__(self) -> "Capture":
        return self

    def __exit__(self, *exc) -> None:
        if platform.system() == "Windows":
            # ffmpeg on PATH is usually a chocolatey shim: kill the tree so the real recorder goes with it
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(self.proc.pid)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            self.proc.kill()
        self.proc.wait()
        self.pump.join(timeout=5)
        if self.pump.is_alive():
            raise CaptureError("recorder still holds the audio pipe 5 s after being killed")


def is_quiet(seconds: float) -> bool:
    """True if nobody in the meeting spoke during the next `seconds`. Raises CaptureError if we could not
    observe the whole interval (never reports quiet it did not hear)."""
    with Capture() as cap:
        n = 0
        for _, level in cap.frames(time.monotonic() + seconds + 10.0):  # slack for a slow (suspended) sink
            if level >= SPEECH_RMS:
                return False
            n += 1
            if n * 0.1 >= seconds:
                return True
    raise CaptureError(f"only {n * 0.1:.1f}s of {seconds:g}s captured")


def until_silence(silence: float, max_seconds: float, keep: bool = True, heard: bool = False) -> bytes | None:
    """Listen from the first speech until `silence` seconds of quiet (or max_seconds total).
    Pass heard=True when the caller already knows someone is talking, so quiet counts from the first frame.

    Returns the raw PCM from the first speech frame on (empty if keep=False), or None if nobody spoke."""
    pcm: list[bytes] = []
    quiet = 0.0
    with Capture() as cap:
        for buf, level in cap.frames(time.monotonic() + max_seconds):
            if keep and (heard or level >= SPEECH_RMS):
                pcm.append(buf)
            if level >= SPEECH_RMS:
                heard, quiet = True, 0.0
            elif heard:
                quiet += 0.1
                if quiet >= silence:
                    break
    return b"".join(pcm) if heard else None


def record_until_silence(silence: float, max_seconds: float, path: str) -> None:
    try:
        pcm = until_silence(silence, max_seconds)
    except CaptureError as e:
        sys.exit(f"capture failed: {e}")
    if pcm is None:
        sys.exit(f"nobody spoke within {max_seconds:g}s")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)


def record(seconds: int, path: str) -> None:
    if os.path.exists(path):
        os.remove(path)
    if (src := ffmpeg_input()) is not None:
        cmd = ["ffmpeg", "-y", "-loglevel", "error", *src, "-t", str(seconds), "-ac", "1", "-ar", str(RATE), path]
        ok = subprocess.run(cmd, check=False).returncode == 0
    else:
        cmd = ["parecord", f"--device={LINUX_SOURCE}", "--file-format=wav", "--channels=1", "--rate=16000",
               f"--process-time-msec={seconds * 1000}", path]
        # parecord runs until killed; timeout ends it with SIGTERM, so its status is not meaningful
        subprocess.run(["timeout", "--preserve-status", str(seconds), *cmd], check=False)
        ok = True
    if not ok or not os.path.exists(path) or os.path.getsize(path) < 1000:
        sys.exit(f"recording failed or empty: {path}")


def transcribe(path: str) -> dict:
    key = os.environ["ELEVENLABS_API_KEY"]
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
    except (urllib.error.URLError, OSError, ValueError) as e:
        sys.exit(f"POST /speech-to-text failed: {e}")


def fix_names(text: str) -> str:
    return MISHEARD.sub(lambda m: "Devin" + (m.group(2) or ""), text)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--seconds", type=int, help="record the meeting audio for N seconds")
    src.add_argument("--file", help="transcribe this audio file instead of recording")
    src.add_argument("--until-silence", type=float, metavar="SECS",
                     help="wait for speech, then stop after SECS of silence (turn-taking)")
    ap.add_argument("--max", type=float, default=90, help="cap for --until-silence in seconds (default 90)")
    ap.add_argument("--keep", help="save the recording to this path")
    ap.add_argument("--json", action="store_true", help="print the raw Scribe response")
    a = ap.parse_args()

    for name in ("seconds", "until_silence", "max"):
        v = getattr(a, name)
        if v is not None and not (0 < v < 3600):
            ap.error(f"--{name.replace('_', '-')} must be between 0 and 3600 seconds")
    if not os.environ.get("ELEVENLABS_API_KEY"):
        sys.exit("ELEVENLABS_API_KEY not set (listen.py has no offline STT fallback)")

    tmp = None
    if not a.file and not a.keep:
        fd, tmp = tempfile.mkstemp(suffix=".wav", prefix="listen-")
        os.close(fd)
    path = a.file or a.keep or tmp
    try:
        if a.seconds:
            record(a.seconds, path)
        elif a.until_silence is not None:
            record_until_silence(a.until_silence, a.max, path)
        result = transcribe(path)
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)

    if a.json:
        print(json.dumps(result, indent=2))
        return
    text = fix_names(result.get("text", ""))
    print(text if text else "(silence)")


if __name__ == "__main__":
    main()
