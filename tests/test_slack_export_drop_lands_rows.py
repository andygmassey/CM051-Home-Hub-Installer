#!/usr/bin/env python3
"""A Slack workspace export dropped in Downloads lands conversations, and
sends nothing off the Mac.

WHAT THIS PROVES, END TO END THROUGH THE SHIPPED PATH (not a unit of the
importer): the real `ostler-import` script, extracted byte for byte from
install.sh, is run over a Downloads folder holding a synthetic Slack export.
It must find the export, run the VENDORED cm052 slack importer, and deliver
conversations to the Hub's conversation endpoint (a local stub that records
each POST). Then, with the same drop:

  * the first import is free without Pro; a LATER, different export needs Pro
    and is refused (nothing posted), and the refusal is not a failure;
  * with Pro, the same export again posts nothing new (unchanged);
  * a conversation the owner took no part in is posted as L3;
  * a folder with a channels.json that is not Slack is left alone;
  * an owner address that is not in the export refuses (rc 2, nothing posted)
    rather than importing the owner as a stranger;
  * the detector labels both the unpacked folder and the still-zipped export
    "Slack";
  * NO connection to a non-loopback address is attempted. The egress guard is
    a sitecustomize hook on the importer's interpreter that records every
    non-loopback connect and refuses it. Its control: a connect to a
    documentation address (192.0.2.1) IS recorded, so an empty log means "no
    attempt", not "could not see".

Synthetic data only: example.com addresses, invented names.

Exit: 0 all pass, 1 a real failure, 2 CANNOT-RUN (no httpx or PyYAML on the
interpreter running this test: the importer's own runtime deps).
"""
from __future__ import annotations

import http.server
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import threading
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INSTALL_SH = REPO / "install.sh"
DETECT = REPO / "lib" / "ostler-detect-exports.sh"
CM052 = REPO / "vendor" / "cm052_ai_conversations"

PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  [PASS] {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {msg}")


def check(cond, msg):
    (ok if cond else bad)(msg)


for mod in ("httpx", "yaml"):
    try:
        __import__(mod)
    except ImportError:
        print(f"CANNOT-RUN: {mod} is not importable on {sys.executable}", file=sys.stderr)
        sys.exit(2)


# ── the shipped importer script, extracted from install.sh ────────────────
def extract_ostler_import(dest: Path) -> None:
    text = INSTALL_SH.read_text(encoding="utf-8")
    m = re.search(
        r"cat > \"\$IMPORT_SCRIPT\" <<'IMPORTEOF'\n(.*?)\nIMPORTEOF\n", text, re.S)
    if not m:
        print("CANNOT-RUN: ostler-import heredoc not found in install.sh", file=sys.stderr)
        sys.exit(2)
    dest.write_text(m.group(1) + "\n", encoding="utf-8")
    dest.chmod(dest.stat().st_mode | stat.S_IEXEC)


# ── synthetic Slack export ───────────────────────────────────────────────
OWNER_EMAIL = "alex@example.com"


def _write(p: Path, obj) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj, indent=1), encoding="utf-8")


def make_export(root: Path, *, extra_message: bool = False) -> Path:
    users = [
        {"id": "U0000000001", "team_id": "T0000000001", "name": "alex",
         "real_name": "Alex Example", "is_bot": False,
         "profile": {"real_name": "Alex Example", "display_name": "Alex",
                     "email": OWNER_EMAIL}},
        {"id": "U0000000002", "team_id": "T0000000001", "name": "sam",
         "real_name": "Sam Example", "is_bot": False,
         "profile": {"real_name": "Sam Example", "display_name": "Sam",
                     "email": "sam@example.com"}},
    ]
    _write(root / "users.json", users)
    _write(root / "channels.json", [
        {"id": "C0000000001", "name": "general", "members": ["U0000000001", "U0000000002"]},
        {"id": "C0000000002", "name": "sam-only", "members": ["U0000000002"]},
    ])
    msgs = [
        {"type": "message", "ts": "1772496000.000100", "user": "U0000000001",
         "text": "Morning, the launch checklist is in the shared doc."},
        {"type": "message", "ts": "1772496060.000200", "user": "U0000000002",
         "text": "Thanks, I will review it before lunch."},
    ]
    if extra_message:
        msgs.append({"type": "message", "ts": "1772496120.000300", "user": "U0000000002",
                     "text": "One more thing: the venue is booked."})
    _write(root / "general" / "2026-03-03.json", msgs)
    _write(root / "sam-only" / "2026-03-03.json", [
        {"type": "message", "ts": "1772496000.000100", "user": "U0000000002",
         "text": "Notes to self about the supplier."}])
    return root


# ── Hub stub: records every conversation POST ────────────────────────────
class Hub(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        self.posts: list[dict] = []

        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):  # noqa: N802
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}")
                outer.posts.append(body)
                out = json.dumps({"status": "ok"}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

            def log_message(self, *a):
                pass

        super().__init__(("127.0.0.1", 0), H)


# ── the egress guard (sitecustomize on the importer's interpreter) ───────
GUARD = textwrap.dedent('''
    import os, socket
    _real = socket.socket.connect
    def _guard(self, address):
        host = address[0] if isinstance(address, tuple) else str(address)
        if isinstance(address, tuple) and host not in ("127.0.0.1", "::1", "localhost"):
            with open(os.environ["EGRESS_LOG"], "a") as f:
                f.write(host + "\\n")
            raise OSError("egress guard: non-loopback connect refused")
        return _real(self, address)
    socket.socket.connect = _guard
''')


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="slack-drop-"))
    hub = Hub()
    threading.Thread(target=hub.serve_forever, daemon=True).start()
    try:
        home = tmp / "home"
        (home / ".ostler" / "bin").mkdir(parents=True)
        (home / ".ostler" / "state").mkdir(parents=True)
        guard_dir = tmp / "guard"
        guard_dir.mkdir()
        (guard_dir / "sitecustomize.py").write_text(GUARD, encoding="utf-8")
        egress_log = tmp / "egress.log"

        # The cm052 venv interpreter the script looks for: the current
        # interpreter, with the vendored package on its path.
        slack_py = home / ".ostler" / "services" / "cm052" / ".venv" / "bin" / "python3"
        slack_py.parent.mkdir(parents=True)
        slack_py.write_text(f'#!/bin/sh\nexec "{sys.executable}" "$@"\n', encoding="utf-8")
        slack_py.chmod(0o755)

        imp = home / ".ostler" / "bin" / "ostler-import"
        extract_ostler_import(imp)

        sub = tmp / "sub.json"
        ledger = tmp / "first_imports.json"

        def set_pro(active: bool) -> None:
            if active:
                sub.write_text(json.dumps({
                    "status": "active", "source": "licence",
                    "last_validated_at": "2099-01-01T00:00:00Z",
                    "expires_at": "2099-12-31T00:00:00Z"}))
            else:
                sub.write_text(json.dumps({"status": "inactive", "source": "default"}))

        def run(downloads: Path, *, email: str = OWNER_EMAIL):
            env = {
                "HOME": str(home), "PATH": os.environ["PATH"],
                "PYTHONPATH": f"{CM052}:{guard_dir}",
                "EGRESS_LOG": str(egress_log),
                "CM052_USER_EMAIL": email,
                "CM052_CM048_ENDPOINT": f"http://127.0.0.1:{hub.server_port}/api/v1/conversation/process",
                "CM052_OUTBOX_DIR": str(tmp / "outbox"),
                "CM052_STATE_DIR": str(tmp / "state"),
                "OSTLER_AI_CONVERSATIONS_DIR": str(tmp / "ai"),
                "OSTLER_SUBSCRIPTION_STATE": str(sub),
                "OSTLER_FIRST_IMPORT_LEDGER": str(ledger),
                "NO_PROXY": "127.0.0.1,localhost",
                # Never write bytecode into the vendored tree under test.
                "PYTHONDONTWRITEBYTECODE": "1",
            }
            r = subprocess.run([str(imp), str(downloads)], env=env, text=True,
                               capture_output=True, timeout=120)
            return r

        downloads = tmp / "Downloads"
        make_export(downloads / "acme-slack-export")

        # 1. First import, no Pro: free, lands rows.
        set_pro(False)
        r = run(downloads)
        print(r.stdout.strip()[-600:], r.stderr.strip()[-600:])
        check(r.returncode == 0, f"first import, no Pro: ostler-import rc 0 (got {r.returncode})")
        n1 = len(hub.posts)
        check(n1 == 2, f"first import posted 2 conversations to the Hub (got {n1})")
        levels = sorted(p.get("metadata", {}).get("privacy_level") for p in hub.posts)
        check(levels == ["L2", "L3"],
              f"the owner's conversation is L2 and the one they took no part in is L3 (got {levels})")
        transcripts = " ".join(p.get("transcript", "") for p in hub.posts)
        check("launch checklist" in transcripts,
              "the message text reached the Hub (consumer-side: the content is there)")
        check(ledger.is_file() and "slack_export" in ledger.read_text(),
              "the free first import is recorded in the ledger only after it landed")

        # 2. A later, DIFFERENT export without Pro: refused, nothing posted, not a failure.
        make_export(downloads / "acme-slack-export", extra_message=True)
        r = run(downloads)
        check(r.returncode == 0, f"later import, no Pro: paused is not a failure (rc {r.returncode})")
        check(len(hub.posts) == n1, f"later import, no Pro: nothing posted (still {len(hub.posts)})")
        check("free first import is already used" in r.stdout,
              "later import, no Pro: the owner is told why")

        # 3. With Pro: the changed export posts; the identical re-run posts nothing new.
        set_pro(True)
        r = run(downloads)
        check(r.returncode == 0, f"Pro: rc 0 (got {r.returncode}; {r.stderr.strip()[-200:]})")
        n3 = len(hub.posts)
        check(n3 == n1 + 1, f"Pro: only the CHANGED conversation posts (+{n3 - n1}, expected +1)")
        r = run(downloads)
        check(r.returncode == 0 and len(hub.posts) == n3,
              f"Pro: re-import of an unchanged export posts nothing new (+{len(hub.posts) - n3})")

        # 4. Not Slack: a channels.json without a Slack team_id is left alone.
        other = tmp / "Downloads2"
        (other / "some-app").mkdir(parents=True)
        _write(other / "some-app" / "users.json", [{"id": 1, "name": "x"}])
        _write(other / "some-app" / "channels.json", [{"id": 1}])
        before = len(hub.posts)
        r = run(other)
        check(r.returncode == 0 and len(hub.posts) == before and "Slack export found" not in r.stdout,
              "a non-Slack users.json + channels.json pair is not imported")

        # 5. Owner not in the export: refuse, never import the owner as a stranger.
        set_pro(False)
        ledger.unlink(missing_ok=True)
        fresh = tmp / "Downloads3"
        make_export(fresh / "other-workspace")
        before = len(hub.posts)
        r = run(fresh, email="nobody@example.com")
        check(r.returncode == 2 and len(hub.posts) == before,
              f"owner address not in the export: rc 2 and nothing posted (rc {r.returncode})")
        check(not ledger.exists(), "a refused import does not burn the free first import")

        # 6. Egress: the guard saw no non-loopback attempt, and it can see one.
        seen = egress_log.read_text().split() if egress_log.exists() else []
        check(seen == [], f"no non-loopback connection attempted during any import (saw {seen})")
        ctl = subprocess.run(
            [sys.executable, "-c",
             "import socket; s=socket.socket();\n"
             "try: s.connect(('192.0.2.1', 80))\nexcept OSError: pass"],
            env={"PATH": os.environ["PATH"], "PYTHONPATH": str(guard_dir),
                 "EGRESS_LOG": str(egress_log)}, capture_output=True, text=True)
        seen = egress_log.read_text().split() if egress_log.exists() else []
        check(seen == ["192.0.2.1"],
              f"control: the guard records a non-loopback connect (saw {seen})")

        # 7. Detector: unpacked folder and still-zipped export are both labelled Slack.
        dl = tmp / "DetectDL"
        make_export(dl / "unpacked-slack")
        zsrc = tmp / "zsrc"
        make_export(zsrc)
        with zipfile.ZipFile(dl / "workspace-export.zip", "w") as z:
            for p in sorted(zsrc.rglob("*.json")):
                z.write(p, p.relative_to(zsrc))
        d = subprocess.run(["bash", str(DETECT), str(dl), "--unzip"],
                           capture_output=True, text=True)
        labels = sorted({ln.split("\t")[0] for ln in d.stdout.splitlines() if "\t" in ln})
        check(labels == ["Slack"] and d.returncode == 0,
              f"detector labels the Slack folder and the zipped export (labels {labels}, rc {d.returncode})")
        check((dl / "workspace-export" / "users.json").is_file(),
              "the zipped export was opened so the importer can read it")
    finally:
        hub.shutdown()
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n{PASS} pass, {FAIL} fail")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
