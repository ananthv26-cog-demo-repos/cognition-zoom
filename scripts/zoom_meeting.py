#!/usr/bin/env python3
"""Create a host-less Zoom meeting via Server-to-Server OAuth and print join info.

Env vars required:
  ZOOM_S2S_ACCOUNT_ID, ZOOM_S2S_CLIENT_ID, ZOOM_S2S_CLIENT_SECRET, ZOOM_HOST_EMAIL

Usage:
  python3 zoom_meeting.py [--topic "Devin standup"] [--duration 60] [--json]
  python3 zoom_meeting.py --end MEETING_ID        # scope meeting:update:status:admin
  python3 zoom_meeting.py --delete MEETING_ID     # scope meeting:delete:meeting:admin
  python3 zoom_meeting.py --list-live             # scope meeting:read:list_meetings:admin

Creating only needs meeting:write:meeting:admin. A join-before-host meeting stays
"in progress" while anyone is connected and blocks other meetings on the host
account, so the parent should --end it when the demo is over.
"""
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


def get_token() -> str:
    basic = base64.b64encode(
        f"{env('ZOOM_S2S_CLIENT_ID')}:{env('ZOOM_S2S_CLIENT_SECRET')}".encode()
    ).decode()
    body = urllib.parse.urlencode(
        {"grant_type": "account_credentials", "account_id": env("ZOOM_S2S_ACCOUNT_ID")}
    ).encode()
    data = http(
        "POST",
        TOKEN_URL,
        {"Authorization": f"Basic {basic}", "Content-Type": "application/x-www-form-urlencoded"},
        body,
    )
    return data["access_token"]


def create_meeting(token: str, topic: str, duration: int) -> dict:
    start = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    payload = {
        "topic": topic,
        "type": 2,
        "start_time": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "duration": duration,
        "timezone": "UTC",
        "settings": {
            "join_before_host": True,
            "jbh_time": 0,
            "waiting_room": False,
            "approval_type": 2,
            "meeting_authentication": False,
            "mute_upon_entry": False,
            "host_video": False,
            "participant_video": False,
        },
    }
    host = urllib.parse.quote(env("ZOOM_HOST_EMAIL"), safe="")
    return http(
        "POST",
        f"{API}/users/{host}/meetings",
        {"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json.dumps(payload).encode(),
    )


def delete_meeting(token: str, meeting_id: str) -> None:
    http("DELETE", f"{API}/meetings/{meeting_id}", {"Authorization": f"Bearer {token}"})


def end_meeting(token: str, meeting_id: str) -> None:
    http(
        "PUT",
        f"{API}/meetings/{meeting_id}/status",
        {"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json.dumps({"action": "end"}).encode(),
    )


def list_live_meetings(token: str) -> list[dict]:
    host = urllib.parse.quote(env("ZOOM_HOST_EMAIL"), safe="")
    data = http(
        "GET",
        f"{API}/users/{host}/meetings?type=live&page_size=300",
        {"Authorization": f"Bearer {token}"},
    )
    return data.get("meetings", [])


def summarize(m: dict) -> dict:
    mid = m["id"]
    pwd = m.get("encrypted_password", "")
    return {
        "id": mid,
        "topic": m.get("topic"),
        "passcode": m.get("password"),
        "join_url": m.get("join_url"),
        "web_client_url": f"https://app.zoom.us/wc/join/{mid}?pwd={pwd}",
        "join_before_host": m.get("settings", {}).get("join_before_host"),
        "waiting_room": m.get("settings", {}).get("waiting_room"),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--topic", default="Devin standup")
    ap.add_argument("--duration", type=int, default=60)
    ap.add_argument("--json", action="store_true", help="print machine-readable JSON only")
    cmd = ap.add_mutually_exclusive_group()
    cmd.add_argument("--delete", metavar="MEETING_ID")
    cmd.add_argument("--end", metavar="MEETING_ID", help="end an in-progress meeting")
    cmd.add_argument("--list-live", action="store_true", help="list in-progress meetings on the host")
    args = ap.parse_args()

    token = get_token()
    if args.list_live:
        live = [{"id": m["id"], "topic": m.get("topic"), "start_time": m.get("start_time")} for m in list_live_meetings(token)]
        print(json.dumps(live) if args.json else "\n".join(f"{m['id']}: {m['topic']}" for m in live) or "no live meetings")
        return
    if args.end:
        end_meeting(token, args.end)
        print(f"ended meeting {args.end}")
        return
    if args.delete:
        delete_meeting(token, args.delete)
        print(f"deleted meeting {args.delete}")
        return

    info = summarize(create_meeting(token, args.topic, args.duration))
    if args.json:
        print(json.dumps(info))
        return
    for k, v in info.items():
        print(f"{k}: {v}")


if __name__ == "__main__":
    main()
