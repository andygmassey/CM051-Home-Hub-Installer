#!/usr/bin/env python3
"""Capture the REAL Hub's responses for the pre-meeting brief into fixtures.

Runs the vendored ical-server over an in-memory SPARQL store seeded with the
fictional graph in tests/helpers/real_hub_seed.py, and writes exactly what the
handlers return for the three endpoints the brief composer reads plus the
attendee record /meeting/upcoming hands the sender. Nothing is hand written.

  scripts/capture_meeting_brief_hub_fixtures.py --write DIR   write fixtures
  scripts/capture_meeting_brief_hub_fixtures.py --check DIR   exit 1 on drift

The oa repo (ostler-ai/ostler-assistant) vendors DIR so its composer tests
consume real Hub output. --check is the drift gate: if a Hub change alters any
field the composer reads, this fails in CM051 before oa is out of date.
Exit 2 = CANNOT-RUN (no pyoxigraph / server would not start); never a pass.
"""
import json
import pathlib
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests/helpers"))
from real_hub import RealHub, RealHubUnavailable, _free_port  # noqa: E402
import real_hub_seed as seed  # noqa: E402

VOLATILE_MEETING_KEYS = ("start", "start_iso")


def capture():
    class Cal(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            body = json.dumps({"events": seed.calendar_events()}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    cal_port = _free_port()
    cal = ThreadingHTTPServer(("127.0.0.1", cal_port), Cal)
    threading.Thread(target=cal.serve_forever, daemon=True).start()
    out = {}
    try:
        with RealHub({"CALENDAR_API_URL": f"http://127.0.0.1:{cal_port}"}) as hub:
            seed.seed(hub)
            upcoming = hub.get("/api/v1/meeting/upcoming?within_minutes=30")
            by_name = {m["attendees"][0]["name"]: m["attendees"][0]
                       for m in upcoming["meetings"]}
            for key, p in (("rich", seed.RICH), ("none", seed.NONE), ("thin", seed.THIN)):
                q = urllib.parse.quote(p["name"])
                out[f"{key}.context.json"] = hub.get(f"/api/v1/people/context?name={q}")
                out[f"{key}.timeline.json"] = hub.get(f"/api/v1/person/{p['slug']}/timeline")
                out[f"{key}.attendee.json"] = by_name[p["name"]]
            out["commitments.user.json"] = hub.get("/api/v1/commitments?owner=user&status=open")
    finally:
        cal.shutdown()
    return out


def render(obj):
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main(argv):
    if len(argv) != 3 or argv[1] not in ("--write", "--check"):
        print(__doc__)
        return 3
    dest = pathlib.Path(argv[2])
    try:
        files = capture()
    except RealHubUnavailable as exc:
        print("CANNOT-RUN:", exc)
        return 2
    if argv[1] == "--write":
        dest.mkdir(parents=True, exist_ok=True)
        for name, obj in files.items():
            (dest / name).write_text(render(obj))
        print(f"wrote {len(files)} files to {dest}")
        return 0
    drift = []
    for name, obj in files.items():
        f = dest / name
        if not f.exists() or f.read_text() != render(obj):
            drift.append(name)
    stale = sorted(p.name for p in dest.glob("*.json") if p.name not in files)
    if drift or stale:
        print("DRIFT: real Hub output differs from committed fixtures:", drift, "unexpected:", stale)
        print("Regenerate with --write and copy to ostler-assistant if a composer field moved.")
        return 1
    print(f"ok: {len(files)} fixtures match the real Hub")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
