#!/usr/bin/env python3
"""Withdrawing the public-lookups consent stops the next enrichment request.

GDPR Art.7(3): withdrawal must be as easy as giving. This drives the writer
that the owner's settings toggle calls (vendor/doctor/agent/consent_enrichment.py) and
then the two gates a public look-up must pass, both read fresh from the file:

  gate 1  the tick's ostler_public_lookups_flag (extracted from the shipped
          wiki-recompile-tick.sh, byte for byte) -> "agreed" or "off"
  gate 2  the CM019 enrich consent gate public_lookup_allowed()

A request is issued only when both allow. The request goes through a local
recording proxy (127.0.0.1, CONNECT counted, answered 502, never forwarded),
so the count is taken at the socket boundary the request would cross, not in
a mock above it. Synthetic data only: sandboxed HOME and OSTLER_DIR, no real
Keychain, no real network.

ARMS
  A  writer: other lines kept, one key line, mode 0600, no temp file left,
     one JSONL event per write with a UTC timestamp and the previous value.
  B  CONTROL: consent given -> the same run makes >= 1 request at the proxy.
  C  withdrawn -> the same run makes 0 requests at the proxy.
  D  re-given after withdrawal -> requests resume (the toggle is two-way).
  E  MUTANT: a gate that ignores the file (returns True) in the withdrawn
     state must make >= 1 request, and the arm-C assertion must go RED on it.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""
from __future__ import annotations

import http.server
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import types
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TICK_SH = Path(os.environ.get("WITHDRAW_TEST_TICK_SH") or (ROOT / "wiki-recompile" / "bin" / "wiki-recompile-tick.sh"))
WRITER = ROOT / "vendor" / "doctor" / "agent" / "consent_enrichment.py"
GATE_DIR = ROOT / "vendor" / "cm019_preferences" / "services" / "enrich" / "src"

passes = fails = cannots = 0


def ok(msg: str) -> None:
    global passes
    passes += 1
    print(f"  ok    {msg}")


def bad(msg: str) -> None:
    global fails
    fails += 1
    print(f"  FAIL  {msg}")


def cant(msg: str) -> None:
    global cannots
    cannots += 1
    print(f"  CANNOT-RUN  {msg}")


def check(name: str, want, got) -> None:
    if want == got:
        ok(f"{name} -> {got!r}")
    else:
        bad(f"{name}: want {want!r}, got {got!r}")


# -- recording proxy: the socket boundary -----------------------------------

class _Recorder(http.server.BaseHTTPRequestHandler):
    hits: list = []

    def do_CONNECT(self):  # noqa: N802
        type(self).hits.append(self.path)
        self.send_error(502, "recorded; not forwarded")

    def do_GET(self):  # noqa: N802
        type(self).hits.append(self.path)
        self.send_error(502, "recorded; not forwarded")

    def log_message(self, *a):  # keep the test output clean
        pass


def start_proxy():
    handler = type("H", (_Recorder,), {"hits": []})
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, handler


# -- the two gates -----------------------------------------------------------

def extract_flag_fn() -> str:
    text = TICK_SH.read_text(encoding="utf-8")
    lines, grab, out = text.split("\n"), False, []
    for ln in lines:
        if ln.startswith("ostler_public_lookups_flag() {"):
            grab = True
        if grab:
            out.append(ln)
            if ln == "}":
                break
    return "\n".join(out)


def tick_flag(base: Path, fn_src: str, env: dict) -> str:
    script = fn_src + '\nostler_public_lookups_flag "$OSTLER_DIR"\n'
    res = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"flag function failed rc={res.returncode}: {res.stderr.strip()}")
    return res.stdout.strip()


def load_cm019_gate():
    sys.path.insert(0, str(GATE_DIR))
    try:
        import consent  # noqa: F401  (vendored CM019 gate)
    except ImportError:
        # click is only used for CLI decorators in this module; the gate
        # function does not call it. Stub it so the real gate can load.
        stub = types.ModuleType("click")
        stub.ClickException = type("ClickException", (Exception,), {})
        sys.modules["click"] = stub
        import consent  # noqa: F401
    import consent as mod
    return mod


def one_run(label: str, base: Path, fn_src: str, proxy_url: str, handler, gate_override=None) -> dict:
    """Run the next-compile path once and return what reached the wire."""
    env = {k: v for k, v in os.environ.items() if k != "OSTLER_CONSENT_ENRICHMENT_DECISION"}
    env["OSTLER_DIR"] = str(base)
    env["HOME"] = str(base.parent)
    flag = tick_flag(base, fn_src, env)
    os.environ["OSTLER_DIR"] = str(base)
    os.environ.pop("OSTLER_CONSENT_ENRICHMENT_DECISION", None)
    gate = gate_override if gate_override is not None else _GATE.public_lookup_allowed
    allowed = bool(gate())
    before = len(handler.hits)
    if flag == "agreed" and allowed:
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({"https": proxy_url, "http": proxy_url}))
        try:
            opener.open("https://www.wikidata.org/w/api.php?action=wbsearchentities", timeout=5)
        except Exception:  # the proxy answers 502 by design
            pass
    sent = len(handler.hits) - before
    return {"label": label, "flag": flag, "gate": allowed, "requests": sent}


def write_decision(base: Path, decision: str):
    res = subprocess.run(
        [sys.executable, str(WRITER), "set", decision, "--ostler-dir", str(base)],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        raise RuntimeError(f"writer rc={res.returncode}: {res.stderr.strip()}")
    return json.loads(res.stdout)


def main() -> int:
    global _GATE
    if not TICK_SH.exists() or not WRITER.exists() or not GATE_DIR.exists():
        cant("a required file is missing from the checkout")
        return 2
    fn_src = extract_flag_fn()
    if "ostler_public_lookups_flag" not in fn_src or fn_src.count("\n") < 3:
        cant("could not extract ostler_public_lookups_flag from the tick")
        return 2
    try:
        _GATE = load_cm019_gate()
    except Exception as exc:  # noqa: BLE001
        cant(f"CM019 gate did not import: {exc}")
        return 2

    sandbox = Path(tempfile.mkdtemp(prefix="withdraw-134-"))
    srv, handler = start_proxy()
    proxy_url = f"http://127.0.0.1:{srv.server_address[1]}"
    try:
        base = sandbox / ".ostler"
        (base / "config").mkdir(parents=True)
        env_file = base / "config" / ".env"
        env_file.write_text('USER_NAME="synthetic-owner"\nOSTLER_CONSENT_ARTICLE_9_DECISION="declined"\n')

        print("A. writer")
        ev = write_decision(base, "accepted")
        check("give: event", "given", ev["event"])
        check("give: previous was absent", None, ev["previous"])
        text = env_file.read_text()
        check("give: other lines kept", True,
              'USER_NAME="synthetic-owner"' in text and 'OSTLER_CONSENT_ARTICLE_9_DECISION="declined"' in text)
        check("give: one decision line", 1, text.count("OSTLER_CONSENT_ENRICHMENT_DECISION="))
        mode = stat.S_IMODE(env_file.stat().st_mode)
        check("config/.env mode", 0o600, mode)
        check("no temp file left", [], sorted(p.name for p in (base / "config").iterdir() if p.name.endswith(".tmp")))
        ev2 = write_decision(base, "declined")
        check("withdraw: event", "withdrawn", ev2["event"])
        check("withdraw: previous was accepted", "accepted", ev2["previous"])
        check("withdraw: timestamp is UTC Z", True, ev2["recorded_at"].endswith("Z"))
        events = [json.loads(x) for x in (base / "posture" / "consent-events.jsonl").read_text().splitlines()]
        check("event log has both writes in order", ["given", "withdrawn"], [e["event"] for e in events])
        check("snapshot file says declined", "declined",
              json.loads((base / "posture" / "enrichment-decision.json").read_text())["decision"])
        write_decision(base, "accepted")  # leave the sandbox in the given state for the control

        print("B. control: consent given, next run reaches the wire")
        b = one_run("given", base, fn_src, proxy_url, handler)
        check("given: flag", "agreed", b["flag"])
        check("given: gate", True, b["gate"])
        if b["requests"] >= 1:
            ok(f"given: {b['requests']} request(s) at the proxy (counter is live)")
        else:
            bad("CONTROL dead: consent given but 0 requests reached the proxy")

        print("C. withdrawn: next run sends nothing")
        write_decision(base, "declined")
        c = one_run("withdrawn", base, fn_src, proxy_url, handler)
        check("withdrawn: flag", "off", c["flag"])
        check("withdrawn: gate", False, c["gate"])
        check("withdrawn: requests at the proxy", 0, c["requests"])

        print("D. re-given: requests resume")
        write_decision(base, "accepted")
        d = one_run("re-given", base, fn_src, proxy_url, handler)
        check("re-given: requests", True, d["requests"] >= 1)

        print("E. mutants: each withdrawn-state assertion must go RED on a gate that ignores the file")
        write_decision(base, "declined")
        real_flag_src, real_gate = fn_src, _GATE.public_lookup_allowed
        cases = {
            # the tick's flag ignores the file and says agreed; the CM019 gate still reads the file
            "E1 flag ignores the file": ("flag", None),
            # the CM019 gate ignores the file and says True; the tick flag still reads the file
            "E2 gate ignores the file": ("gate", lambda: True),
            # both ignore the file: nothing stops the request, so the boundary count must move
            "E3 both ignore the file": ("both", lambda: True),
        }
        for label, (kind, gate_fn) in cases.items():
            mut_flag_src = fn_src
            if kind in ("flag", "both"):
                mut_flag_src = "ostler_public_lookups_flag() { printf 'agreed'; }\n"
            _GATE.public_lookup_allowed = gate_fn if gate_fn else real_gate
            try:
                e = one_run(label, base, mut_flag_src, proxy_url, handler)
            finally:
                _GATE.public_lookup_allowed = real_gate
            red = []
            if e["flag"] != "off": red.append(f"flag {e['flag']!r} != 'off'")
            if e["gate"] is not False: red.append("gate True while withdrawn")
            if e["requests"] != 0: red.append(f"{e['requests']} request(s) at the proxy")
            if red:
                ok(f"{label}: RED as required ({'; '.join(red)})")
            else:
                bad(f"{label}: NOT DETECTED, withdrawn state looked clean")
    finally:
        srv.shutdown()
        shutil.rmtree(sandbox, ignore_errors=True)

    print(f"\n{passes} passed, {fails} failed, {cannots} cannot-run")
    if cannots:
        return 2
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
