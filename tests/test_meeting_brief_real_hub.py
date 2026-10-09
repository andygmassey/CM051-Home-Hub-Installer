#!/usr/bin/env python3
"""The pre-meeting brief, proven against the REAL Hub handler.

Issue ostler-ai/ostler-assistant#471. The composer (oa crates/zeroclaw-runtime
src/brief/meeting.rs) was first written against Hub field names that were
guesses, and the live sender stated guesses as facts ("no meetings logged"
became "first face-to-face meeting"). Hand-written JSON cannot catch that, so
nothing here is hand-written: the vendored ical-server runs unmodified over a
real SPARQL engine (pyoxigraph) seeded with a fictional graph.

Arms:
  1 control   the harness can see a seeded person and can see one that is absent
  2 contract  every Hub field the composer reads exists in the real response,
              and the fields the first draft guessed (mutual_contacts,
              first_contact, awaiting_reply ...) do not exist
  3 drift     the fixtures the oa composer tests consume equal a fresh capture
  4 sender    the sender as shipped in install.sh, driven against the real Hub:
              it authenticates, hands the composer the right arguments, sends
              exactly what the composer printed, and sends NOTHING when the
              composer is missing, fails, or prints a banned claim
  5 mutant    the pre-change sender body, which must fail the arms above, so
              they discriminate rather than merely pass

Exit 0 pass, 1 fail, 2 CANNOT-RUN (a missing dependency is never a pass).
"""
import json
import os
import pathlib
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests/helpers"))
sys.path.insert(0, str(ROOT / "scripts"))

try:
    from real_hub import RealHub, RealHubUnavailable, _free_port
    import real_hub_seed as seed
    import capture_meeting_brief_hub_fixtures as cap
except Exception as exc:  # pyoxigraph / cryptography / httpx missing
    print("CANNOT-RUN: could not import the real-Hub harness:", exc)
    sys.exit(2)

FIXTURES = ROOT / "tests/fixtures/meeting_brief_real_hub"
INSTALL = ROOT / "install.sh"
fails = 0


def check(label, ok, detail=""):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + label + (f"  [{detail}]" if detail and not ok else ""))
    if not ok:
        fails += 1


def extract_sender(text):
    m = re.search(r"cat > \"\$\{OSTLER_DIR\}/bin/ostler-meeting-brief-sender\" <<'BRIEFEOF'\n(.*?)\nBRIEFEOF\n",
                  text, re.S)
    return m.group(1) + "\n" if m else None


class Announce(BaseHTTPRequestHandler):
    sent = []

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        Announce.sent.append(json.loads(self.rfile.read(n)))
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")


class Calendar(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        body = json.dumps({"events": seed.calendar_events()}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve(handler):
    port = _free_port()
    srv = ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, port


# The owner's brief channel, in the two spellings config.toml really has: the
# section-header form install.sh writes, and the inline table array the daemon
# rewrites it to. Recipients are reserved fictional values (Ofcom drama range,
# example domain).
WHATSAPP_CFG = (
    '[[cron.jobs]]\nid = "morning-brief"\n'
    'delivery = { mode = "announce", channel = "whatsapp", to = "+447700900123", best_effort = false }\n'
)
IMESSAGE_CFG = (
    '[cron]\njobs = [{ id = "morning-brief", delivery = { mode = "announce", '
    'channel = "imessage", to = "sam@fixture.example", best_effort = false } }]\n'
)
NO_CHANNEL_CFG = '[gateway]\nport = 8000\n'
GATE_SRC = ROOT / "vendor/cm041/assistant_api/subscription_gate.py"


def stage_gate(home, state):
    """Stage the canonical gate where the sender looks for it, and write the
    subscription state with the gate's OWN functions (never a hand-written
    status). state: ('trial', days_since_install) or ('paid', days_left)."""
    svc = home / ".ostler/services/ical-server"
    svc.mkdir(parents=True, exist_ok=True)
    shutil.copy(GATE_SRC, svc / "subscription_gate.py")
    kind, days = state
    code = (
        "import sys; sys.path.insert(0, sys.argv[1])\n"
        "from datetime import datetime, timezone, timedelta\n"
        "import subscription_gate as g\n"
        "now = datetime.now(timezone.utc)\n"
        "iso = lambda d: d.isoformat().replace('+00:00', 'Z')\n"
        f"if {kind!r} == 'trial':\n"
        f"    g.activate_first_month_free(iso(now - timedelta(days={days})))\n"
        "else:\n"
        "    g.activate_first_month_free(iso(now - timedelta(days=90)))\n"
        f"    g.refresh_from_companion('cmVjZWlwdA==', iso(now + timedelta(days={days})))\n"
    )
    subprocess.run([sys.executable, "-c", code, str(svc)], check=True,
                   env={"PATH": os.environ["PATH"], "HOME": str(home)})


def run_sender(script_text, hub, announce_port, composer, workdir, token=True,
               config=WHATSAPP_CFG, gate=None):
    """Run a sender script against the real Hub; return (rc, announced, log).
    config: the owner's config.toml text, or None for no file at all.
    gate:   None (gate not installed: fails open) or a stage_gate() state."""
    home = pathlib.Path(workdir) / "home"
    shutil.rmtree(home, ignore_errors=True)
    (home / ".ostler/secrets").mkdir(parents=True)
    if token:
        (home / ".ostler/secrets/service_token").write_text(hub.TOKEN + "\n")
    if config is not None:
        (home / ".ostler/assistant-config").mkdir(parents=True)
        (home / ".ostler/assistant-config/config.toml").write_text(config)
    if gate is not None:
        stage_gate(home, gate)
    script = pathlib.Path(workdir) / "sender.sh"
    script.write_text(script_text)
    script.chmod(0o755)
    Announce.sent.clear()
    env = {
        "PATH": os.environ["PATH"], "HOME": str(home),
        "OSTLER_HUB_HOST": hub.url,
        "OSTLER_ASSISTANT_URL": f"http://127.0.0.1:{announce_port}",
        "OSTLER_BRIEF_QUIET_START": "24", "OSTLER_BRIEF_QUIET_END": "0",
        "OSTLER_BRIEF_COMPOSER": str(composer),
        "OSTLER_BRIEF_OWNER_NAME": "Sam",
        "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
    }
    res = subprocess.run(["bash", str(script)], env=env, capture_output=True, timeout=120)
    log_file = home / ".ostler/logs/meeting-brief-sender.log"
    log = log_file.read_text() if log_file.exists() else ""
    # stderr is where launchd's StandardErrorPath (the .err the Doctor card
    # tails) gets the CANNOT-DELIVER line.
    run_sender.stderr = res.stderr.decode(errors="replace")
    return res.returncode, list(Announce.sent), log


def stub_composer(path, mode, calls_file):
    """A stand-in for the assistant binary. It records its argv and prints a
    canned brief per mode. The REAL composer is exercised by the oa tests
    (same real-Hub fixtures) and by the walk probe on the box."""
    script = f"""#!/usr/bin/env python3
import json, sys
argv = sys.argv[1:]
open({str(calls_file)!r}, "a").write(json.dumps(argv) + "\\n")
mode = {mode!r}
arg = lambda k: argv[argv.index(k) + 1] if k in argv else None
if mode == "fail":
    sys.stderr.write("boom")
    sys.exit(3)
if mode == "empty":
    sys.exit(0)
if mode == "claims":
    print("This is your first meeting with " + arg("--person") + ". A warm welcome would be appropriate.")
    sys.exit(0)
todos = json.load(open(arg("--todos-file")))
print("BRIEF-FOR " + arg("--person") + " slug=" + str(arg("--slug")) + " todos=" + str(len(todos)))
"""
    path.write_text(script)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def main():
    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        cal_srv, cal_port = serve(Calendar)
        ann_srv, ann_port = serve(Announce)
        try:
            with RealHub({"CALENDAR_API_URL": f"http://127.0.0.1:{cal_port}"}) as hub:
                seed.seed(hub)
                import urllib.parse as up
                ctx = lambda n: hub.get("/api/v1/people/context?name=" + up.quote(n))

                print("-- 1 control: the harness can see people and their absence --")
                check("a seeded person is found", ctx(seed.RICH["name"]).get("found") is True)
                check("an unseeded name is reported not found", ctx("Some Person").get("found") is False)
                try:
                    urllib.request.urlopen(hub.url + "/api/v1/people/context?name=x", timeout=5)
                    check("CONTROL: the Hub refuses a request with no service token", False)
                except urllib.error.HTTPError as e:
                    check("CONTROL: the Hub refuses a request with no service token (401)", e.code == 401)

                print("-- 2 contract: fields the composer reads, and fields it must not guess --")
                rich = ctx(seed.RICH["name"])["person"]
                for k in ("organisation", "title", "relationship", "how_we_met", "last_contact", "facts", "slug"):
                    check(f"people/context carries {k}", k in rich)
                tl = hub.get(f"/api/v1/person/{seed.RICH['slug']}/timeline")
                evs = tl["events"]
                check("timeline events carry type/channel/when_iso/when_human",
                      all(k in e for e in evs for k in ("type", "channel", "when_iso", "when_human")))
                check("timeline has a meeting event with summary and location",
                      any(e["type"] == "meeting" and e.get("summary") and e.get("location") for e in evs))
                check("timeline is newest first", [e["when_iso"] for e in evs] == sorted((e["when_iso"] for e in evs), reverse=True))
                none_tl = hub.get(f"/api/v1/person/{seed.NONE['slug']}/timeline")
                check("a contact with no logged meetings has zero meeting events (the 'first meeting' trap)",
                      none_tl["found"] and not [e for e in none_tl["events"] if e["type"] == "meeting"])
                up_ = hub.get("/api/v1/meeting/upcoming?within_minutes=30")
                att = {m["attendees"][0]["name"]: m["attendees"][0] for m in up_["meetings"]}
                check("meeting/upcoming returns all three seeded meetings", len(att) == 3, str(sorted(att)))
                todos = att[seed.RICH["name"]]["outstanding_todos"]
                check("attendee outstanding_todos carry text/owner/deadline",
                      len(todos) == 2 and all(k in t for t in todos for k in ("text", "owner", "deadline")))
                check("a done todo is not listed as open", not any("contract" in t["text"] for t in todos))
                cm = hub.get("/api/v1/commitments?status=open")
                check("commitments rows have no person field (so they cannot be attributed to a contact)",
                      cm["commitments"] and not any(k in r for r in cm["commitments"] for k in ("with", "person", "counterparty", "about")))
                blob = json.dumps([rich, tl, none_tl, up_, cm])
                for g in ("first_contact", "contact_frequency", "mutual_contacts", "org_contacts",
                          "meeting_count", "awaiting_reply", "first_seen", "known_since"):
                    check(f"the Hub has no '{g}' field", g not in blob)
                check("an L3 fact never leaves the Hub", "medical" not in blob.lower())

                print("-- 3 drift: oa fixtures equal a fresh capture of the real Hub --")
                fresh = cap.capture()
                drift = [n for n, o in fresh.items()
                         if not (FIXTURES / n).exists() or (FIXTURES / n).read_text() != cap.render(o)]
                check("committed fixtures match the real Hub output", not drift, str(drift))

                print("-- 4 sender: install.sh's script, real Hub, recorded composer --")
                script = extract_sender(INSTALL.read_text())
                if script is None:
                    print("CANNOT-RUN: could not lift the sender heredoc from install.sh by marker")
                    return 2
                if not shutil.which("sqlite3"):
                    print("CANNOT-RUN: sqlite3 not on PATH; the sender needs it")
                    return 2
                calls = work / "calls.jsonl"
                composer = work / "composer.py"

                stub_composer(composer, "ok", calls)
                calls.write_text("")
                rc, sent, log = run_sender(script, hub, ann_port, composer, work)
                argvs = [json.loads(l) for l in calls.read_text().splitlines()]
                check("sender exits 0", rc == 0, log[-300:])
                check("one announce per meeting (3)", len(sent) == 3, f"{len(sent)}; {log[-300:]}")
                check("every announce is kind=meeting_brief on whatsapp",
                      all(s["kind"] == "meeting_brief" and s["channel"] == "whatsapp" for s in sent))
                check("composer called once per attendee with the Hub URL and a slug",
                      len(argvs) == 3 and all("--hub-url" in a and "--slug" in a and a[0] == "meeting-brief" for a in argvs))
                by_uid = {s["meeting_uid"]: s["message"] for s in sent}
                rich_msg = by_uid.get("fixture-uid-0", "")
                check("the SENT text is the composer's text, not the old client-side render",
                      "BRIEF-FOR Alexandra Patel slug=alexandra-patel todos=2" in rich_msg, rich_msg)
                check("the old text is gone (no 'With:' / 'Wiki:' / 'Open:' lines)",
                      not any(re.search(r"^(With|Wiki|Last chat|Open|Location):", s["message"], re.M) for s in sent))
                check("the Hub answered the sender's authenticated call (not 'no meetings in window')",
                      "no meetings in window" not in log)

                for mode, why in (("fail", "a composer that exits non-zero"),
                                  ("empty", "a composer that prints nothing"),
                                  ("claims", "a composer that prints a banned claim")):
                    stub_composer(composer, mode, calls)
                    rc, sent, log = run_sender(script, hub, ann_port, composer, work)
                    check(f"NOTHING is sent for {why}", not sent, f"sent={sent}")
                    check(f"...and the log says why ({mode})", "skip" in log or "composer" in log, log[-200:])
                    check(f"...and it SURFACES: exit 75 with CANNOT-DELIVER on stderr ({mode})",
                          rc == 75 and "CANNOT-DELIVER" in run_sender.stderr, f"rc={rc} err={run_sender.stderr[-200:]}")

                rc, sent, log = run_sender(script, hub, ann_port, work / "missing-binary", work)
                check("NOTHING is sent when the composer binary is missing, and it surfaces (exit 75)",
                      rc == 75 and not sent, f"rc={rc}")

                print("-- 4b channel: the owner's configured brief channel, never a hardcoded one --")
                stub_composer(composer, "ok", calls)
                rc, sent, log = run_sender(script, hub, ann_port, composer, work, config=IMESSAGE_CFG)
                check("an iMessage-only owner gets every brief over iMessage (inline-table spelling)",
                      rc == 0 and len(sent) == 3 and all(s["channel"] == "imessage" for s in sent),
                      f"rc={rc} channels={[s.get('channel') for s in sent]} {log[-200:]}")
                rc, sent, log = run_sender(script, hub, ann_port, composer, work, config=WHATSAPP_CFG)
                check("a WhatsApp owner gets every brief over WhatsApp (section-header spelling)",
                      rc == 0 and len(sent) == 3 and all(s["channel"] == "whatsapp" for s in sent),
                      f"rc={rc} channels={[s.get('channel') for s in sent]}")
                for cfg, why in ((NO_CHANNEL_CFG, "a config with no brief channel"),
                                 (None, "no assistant config at all")):
                    rc, sent, log = run_sender(script, hub, ann_port, composer, work, config=cfg)
                    check(f"{why}: nothing sent, CANNOT-DELIVER logged and on stderr, exit 78 (not a silent drop)",
                          rc == 78 and not sent and "CANNOT-DELIVER" in log and "CANNOT-DELIVER" in run_sender.stderr,
                          f"rc={rc} sent={len(sent)} log={log[-200:]}")

                print("-- 4c Ostler Pro: the canonical subscription gate (Rule 0.8) --")
                rc, sent, log = run_sender(script, hub, ann_port, composer, work, gate=("trial", 5))
                check("day 5 of the included month: briefs are sent", rc == 0 and len(sent) == 3, f"rc={rc} sent={len(sent)} {log[-200:]}")
                rc, sent, log = run_sender(script, hub, ann_port, composer, work, gate=("paid", 20))
                check("a paying subscriber: briefs are sent", rc == 0 and len(sent) == 3, f"rc={rc} sent={len(sent)} {log[-200:]}")
                rc, sent, log = run_sender(script, hub, ann_port, composer, work, gate=("trial", 31))
                check("day 31, never paid: nothing sent, exit 0, and the log says Pro is not active",
                      rc == 0 and not sent and "Ostler Pro is not active" in log, f"rc={rc} sent={len(sent)} {log[-200:]}")

                stub_composer(composer, "ok", calls)
                rc, sent, log = run_sender(script, hub, ann_port, composer, work, token=False)
                check("no service token: CANNOT-RUN is logged and nothing is sent",
                      not sent and "CANNOT-RUN" in log, log[-200:])

                rc, first, _ = run_sender(script, hub, ann_port, composer, work)
                db = pathlib.Path(work) / "home/.ostler/state/sent_briefs.db"
                again = subprocess.run(["bash", str(work / "sender.sh")],
                                       env={"PATH": os.environ["PATH"], "HOME": str(work / "home"),
                                            "OSTLER_HUB_HOST": hub.url,
                                            "OSTLER_ASSISTANT_URL": f"http://127.0.0.1:{ann_port}",
                                            "OSTLER_BRIEF_QUIET_START": "24", "OSTLER_BRIEF_QUIET_END": "0",
                                            "OSTLER_BRIEF_COMPOSER": str(composer),
                                            "NO_PROXY": "127.0.0.1", "no_proxy": "127.0.0.1"},
                                       capture_output=True, timeout=120)
                check("a second tick sends nothing new (idempotent)", len(Announce.sent) == len(first), f"{len(first)} -> {len(Announce.sent)}")

                print("-- 5 mutant: the pre-change sender, on this same Hub, must NOT pass the arms above --")
                old_script = (ROOT / "tests/fixtures/meeting_brief_sender_pre_471.sh").read_text()
                stub_composer(composer, "ok", calls)
                rc, sent, log = run_sender(old_script, hub, ann_port, composer, work)
                check("MUTANT: the pre-change sender sends no composer text (it crashed reading its own stdin)",
                      not any("BRIEF-FOR" in s["message"] for s in sent), f"sent={len(sent)}")
                check("MUTANT: and it sent nothing at all on this Hub, so the old brief never arrived",
                      not sent, f"sent={len(sent)}")
        except RealHubUnavailable as exc:
            print("CANNOT-RUN:", exc)
            return 2
        finally:
            cal_srv.shutdown()
            ann_srv.shutdown()
    print(f"\n{'PASS' if fails == 0 else 'FAIL'}: {fails} failed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
