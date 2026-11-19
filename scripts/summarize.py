#!/usr/bin/env python3
"""Summarize a Zoom meeting from its transcript: key points, decisions and action items, as Markdown.

  scripts/summarize.py ~/turns.jsonl --name "Mac VM 1" --out summary.md
  scripts/listen.py --seconds 300 --json > meeting.json && scripts/summarize.py meeting.json

Input is either the `--log` file of converse.py (one JSON line per event: {"t", "kind", "text"}; `heard`
lines are "Them", `said` lines are you, pass/info/warn are skipped) or the `listen.py --json` Scribe
response (words grouped into turns by `speaker_id`). The transcript goes to the same chat model as
converse.py (FIREWORKS_API_KEY on Fireworks' OpenAI-compatible endpoint; ZOOM_LLM_MODEL overrides the
model) and the summary is printed to stdout and, with --out, written to a file. Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import converse  # noqa: E402
import listen  # noqa: E402

PROMPT = """You are summarizing a Zoom meeting between engineers from its speech-to-text transcript (names may be
misheard: Devon/Kevin = Devin). Write a concise Markdown summary with exactly these sections:

## Key points
## Decisions
## Action items

Bullets only, one fact each, no filler. Action items name the owner when the transcript says who
("- Mac VM 2: cut the release branch"). Write "- None" for a section with nothing in it. Do not invent
anything that is not in the transcript. Output only the summary."""

# Reasoning models sometimes wrap the answer in a <think> block inside `content`.
THINK = re.compile(r"<think>.*?</think>", re.DOTALL)


def stamp(t: float | None) -> str:
    return time.strftime("%H:%M:%S", time.localtime(t)) + " " if t else ""


def turns_from_log(lines: list[str], name: str) -> list[str]:
    out = []
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            sys.exit(f"line {n} is not JSON: {line[:80]!r}")
        if not isinstance(ev, dict):
            continue
        text = str(ev.get("text", "")).strip()
        who = {"heard": "Them", "said": name}.get(ev.get("kind"))
        if who and text:
            out.append(f"{stamp(ev.get('t'))}{who}: {listen.fix_names(text)}")
    return out


def turns_from_scribe(result: dict) -> list[str]:
    out: list[tuple[str, str]] = []
    for w in result.get("words") or []:
        if w.get("type") == "audio_event":
            continue
        who = str(w.get("speaker_id") or "speaker")
        if out and out[-1][0] == who:
            out[-1] = (who, out[-1][1] + w.get("text", ""))
        else:
            out.append((who, w.get("text", "")))
    turns = [f"{who}: {listen.fix_names(text.strip())}" for who, text in out if text.strip()]
    if not turns and result.get("text", "").strip():
        turns = [listen.fix_names(result["text"].strip())]
    return turns


def load_turns(path: str, name: str) -> list[str]:
    if not os.path.exists(path):
        sys.exit(f"transcript not found: {path} (record one with converse.py --log or listen.py --json)")
    with open(path, encoding="utf-8", errors="replace") as f:
        raw = f.read()
    if not raw.strip():
        sys.exit(f"transcript is empty: {path}")
    try:
        doc = json.loads(raw)
    except ValueError:
        doc = None
    if isinstance(doc, dict) and ("words" in doc or "kind" not in doc):
        return turns_from_scribe(doc)
    return turns_from_log(raw.splitlines(), name)


def summarize(turns: list[str], max_tokens: int) -> str:
    content = converse.chat([{"role": "system", "content": PROMPT},
                             {"role": "user", "content": "Transcript:\n" + "\n".join(turns)}],
                            max_tokens=max_tokens, temperature=0.3)
    summary = THINK.sub("", content).strip()
    if not summary:
        raise RuntimeError(f"model returned no summary (try another ZOOM_LLM_MODEL; now {converse.MODEL})")
    return summary


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("transcript", nargs="?", help="converse.py --log JSONL or listen.py --json output (default turns.jsonl)")
    ap.add_argument("--transcript", dest="transcript_opt", metavar="PATH", help="same as the positional argument")
    ap.add_argument("--out", help="also write the summary to this file, e.g. summary.md")
    ap.add_argument("--name", default="You", help='label for your own (`said`) lines, e.g. "Mac VM 1"')
    ap.add_argument("--max-tokens", type=int, default=1500, help="cap on the summary length")
    a = ap.parse_args()
    if a.transcript and a.transcript_opt and a.transcript != a.transcript_opt:
        ap.error("give the transcript once (positional or --transcript)")
    if a.max_tokens < 1:
        ap.error("--max-tokens must be >= 1")
    path = a.transcript or a.transcript_opt or "turns.jsonl"

    turns = load_turns(path, a.name)
    if not turns:
        sys.exit(f"no spoken lines in {path} (only pass/info/warn events, or silence)")
    if not os.environ.get("FIREWORKS_API_KEY"):
        sys.exit("FIREWORKS_API_KEY not set (the summary comes from a chat model)")
    try:
        summary = summarize(turns, a.max_tokens)
    except RuntimeError as e:
        sys.exit(f"summary failed: {e}")
    print(summary)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(summary + "\n")
        print(f"wrote {a.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
