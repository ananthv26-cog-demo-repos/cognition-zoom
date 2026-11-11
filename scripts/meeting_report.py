#!/usr/bin/env python3
"""Post-meeting report for a Zoom meeting: duration, participant count, join/leave times.

Env vars required (same Server-to-Server OAuth app as zoom_meeting.py):
  ZOOM_S2S_ACCOUNT_ID, ZOOM_S2S_CLIENT_ID, ZOOM_S2S_CLIENT_SECRET, ZOOM_HOST_EMAIL

Usage:
  python3 meeting_report.py MEETING_ID           # human-readable summary
  python3 meeting_report.py MEETING_ID --json    # machine-readable JSON only
  python3 meeting_report.py --check              # preflight: env vars, token, granted scopes

MEETING_ID is the numeric ID (latest ended instance) or an instance UUID. The meeting must
have ended; Zoom keeps past-meeting data for one year and the participant report needs a
paid (Pro or higher) account. Scopes on the S2S app:
  meeting:read:past_meeting:admin               GET /past_meetings/{id}
  report:read:list_meeting_participants:admin   GET /report/meetings/{id}/participants
Missing scopes fail with HTTP 400, Zoom code 4711 (docs/gotchas.md); --check lists them.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

TOKEN_URL = "https://zoom.us/oauth/token"
API = "https://api.zoom.us/v2"
ENV_VARS = ("ZOOM_S2S_ACCOUNT_ID", "ZOOM_S2S_CLIENT_ID", "ZOOM_S2S_CLIENT_SECRET", "ZOOM_HOST_EMAIL")
SCOPES = ("meeting:read:past_meeting:admin", "report:read:list_meeting_participants:admin")


def env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"missing env var {name}")
    return value


def http(method: str, url: str, headers: dict, body: bytes | None = None) -> dict:
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {url} -> HTTP {e.code}: {e.read().decode(errors='replace')}")
    except urllib.error.URLError as e:
        sys.exit(f"{method} {url} failed: {e.reason}")


def get_token() -> dict:
    basic = base64.b64encode(
        f"{env('ZOOM_S2S_CLIENT_ID')}:{env('ZOOM_S2S_CLIENT_SECRET')}".encode()
    ).decode()
    body = urllib.parse.urlencode(
        {"grant_type": "account_credentials", "account_id": env("ZOOM_S2S_ACCOUNT_ID")}
    ).encode()
    return http(
        "POST",
        TOKEN_URL,
        {"Authorization": f"Basic {basic}", "Content-Type": "application/x-www-form-urlencoded"},
        body,
    )


def meeting_path(meeting_id: str) -> str:
    """Zoom wants UUIDs that start with '/' or contain '//' double-encoded."""
    once = urllib.parse.quote(meeting_id, safe="")
    if meeting_id.startswith("/") or "//" in meeting_id:
        return urllib.parse.quote(once, safe="")
    return once


def past_meeting(token: str, meeting_id: str) -> dict:
    return http("GET", f"{API}/past_meetings/{meeting_path(meeting_id)}", {"Authorization": f"Bearer {token}"})


def participants(token: str, meeting_id: str) -> list[dict]:
    """Every join/leave record (one person who rejoined shows up more than once)."""
    rows: list[dict] = []
    next_token = ""
    while True:
        query = urllib.parse.urlencode({"page_size": 300, "next_page_token": next_token})
        data = http(
            "GET",
            f"{API}/report/meetings/{meeting_path(meeting_id)}/participants?{query}",
            {"Authorization": f"Bearer {token}"},
        )
        rows.extend(data.get("participants", []))
        next_token = data.get("next_page_token") or ""
        if not next_token:
            return rows


def build_report(meeting: dict, rows: list[dict]) -> dict:
    sessions = sorted(
        (
            {
                "name": r.get("name"),
                "email": r.get("user_email") or None,
                "join_time": r.get("join_time"),
                "leave_time": r.get("leave_time"),
                "duration_seconds": r.get("duration"),
            }
            for r in rows
        ),
        key=lambda s: s["join_time"] or "",
    )
    unique = {(s["email"] or s["name"] or "").lower() for s in sessions}
    return {
        "id": meeting.get("id"),
        "uuid": meeting.get("uuid"),
        "topic": meeting.get("topic"),
        "start_time": meeting.get("start_time"),
        "end_time": meeting.get("end_time"),
        "duration_minutes": meeting.get("duration"),
        "participant_count": len(unique),
        "participants": sessions,
    }


def clock(ts: str | None) -> str:
    if not ts:
        return "-"
    try:
        return dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").strftime("%H:%M:%S")
    except ValueError:
        return ts


def print_report(r: dict) -> None:
    print(f"{r['topic']} ({r['id']})")
    print(f"  {r['start_time']} -> {r['end_time']}, {r['duration_minutes']} min")
    print(f"  {r['participant_count']} participant(s), {len(r['participants'])} join record(s)")
    width = max((len(s["name"] or "") for s in r["participants"]), default=4)
    for s in r["participants"]:
        secs = s["duration_seconds"]
        stay = f"{secs // 60}m{secs % 60:02d}s" if isinstance(secs, int) else "-"
        print(f"  {(s['name'] or '?'):<{width}}  {clock(s['join_time'])} -> {clock(s['leave_time'])}  {stay}")


def require_env() -> None:
    missing = [n for n in ENV_VARS if not os.environ.get(n)]
    if missing:
        sys.exit(f"missing env var(s): {', '.join(missing)}")


def check() -> None:
    """Preflight without a meeting: token issued, required scopes granted."""
    granted = set(get_token().get("scope", "").split())
    print("token: ok")
    lacking = [s for s in SCOPES if s not in granted]
    for s in SCOPES:
        print(f"  {'ok     ' if s in granted else 'MISSING'} {s}")
    if lacking:
        sys.exit("add the missing scope(s) to the S2S app in Marketplace > Scopes and re-Activate")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("meeting_id", nargs="?", metavar="MEETING_ID", help="numeric meeting ID or instance UUID")
    ap.add_argument("--json", action="store_true", help="print machine-readable JSON only")
    ap.add_argument("--check", action="store_true", help="preflight: env vars, token and scopes; no meeting needed")
    args = ap.parse_args()

    require_env()
    if args.check:
        check()
        return
    if not args.meeting_id:
        ap.error("MEETING_ID is required (or use --check)")
    meeting_id = args.meeting_id.strip()
    if meeting_id.replace(" ", "").isdigit():
        meeting_id = meeting_id.replace(" ", "")

    token = get_token()["access_token"]
    report = build_report(past_meeting(token, meeting_id), participants(token, meeting_id))
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_report(report)


if __name__ == "__main__":
    main()
