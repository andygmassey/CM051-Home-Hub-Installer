#!/usr/bin/env python3
"""CM041 9b88b3e1, grafted. Every httpx call to a LOCAL store must set
`trust_env=False`, so a customer's proxy cannot capture traffic meant for
127.0.0.1.

THE DEFECT. httpx reads HTTP_PROXY / HTTPS_PROXY from the environment by
default. The pipeline talks to Oxigraph, Qdrant, Ollama and the unified
calendar API on the loopback. A customer who has a proxy configured -- common
on a corporate Mac -- had their LOCAL store traffic routed through it. It fails
in the direction that looks like the store being down, which is the expensive
kind: the machine note for this whole class reads "a local proxy may answer for
EVERY host you probe".

WHY A STRUCTURAL TEST AND NOT A LIVE ONE. Proving it end-to-end needs a running
store, a configured proxy, and a way to observe the socket -- three things a CI
runner does not have, and a skip reads as a pass. The property is decidable from
the source: it is a keyword on a call. So this parses the shipped vendored tree
with `ast` and asserts the keyword is present and False, which cannot be faked
by a comment, a docstring or a nearby string literal the way a grep can.

WHAT IT DELIBERATELY DOES NOT ASSERT. It does not require `trust_env=False` on
calls to EXTERNAL hosts. A customer's proxy SHOULD be used for those, and
blanket-applying it would be a different defect pointing the other way. The
file list below is therefore explicit rather than a glob: every entry was read
and confirmed to target a local service (an Oxigraph URL, a Qdrant URL, an
Ollama URL, or the unified calendar API on the loopback).
"""
import ast
import io
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
VENDOR = REPO / "vendor" / "cm041"

# Explicit, not a glob. Each was read and confirmed local -- see the docstring.
EXPECTED = {
    "contact_syncer/syncer.py": 5,
    "contact_syncer/backfill_photos.py": 2,
    "contact_syncer/dedup.py": 1,
    "identity_resolver/batch_resolver.py": 2,
    "identity_resolver/pre_ingest_hook.py": 1,
    "identity_resolver/resolver.py": 1,
    "meeting_syncer/brief.py": 1,
    "meeting_syncer/calendar_client.py": 1,
    "meeting_syncer/decision_extractor.py": 2,
    "meeting_syncer/syncer.py": 2,
}
FUNCS = {"post", "get", "put", "delete", "request", "stream", "Client", "AsyncClient"}

PASS = FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print(f"  [PASS] {m}")


def bad(m):
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {m}")


def httpx_calls(src):
    """Every httpx.<verb>(...) call, with whether it sets trust_env=False."""
    out = []
    for node in ast.walk(ast.parse(src)):
        if (isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "httpx"
                and node.func.attr in FUNCS):
            kw = next((k for k in node.keywords if k.arg == "trust_env"), None)
            guarded = (kw is not None
                       and isinstance(kw.value, ast.Constant)
                       and kw.value.value is False)
            out.append((node.lineno, node.func.attr, guarded))
    return out


def main():
    print("== local stores do not route through a customer's proxy (CM041 9b88b3e1) ==")

    if not VENDOR.is_dir():
        print(f"  [CANNOT-RUN] {VENDOR} does not exist. NOTHING was measured.")
        return 2

    total = 0
    for rel, expect in EXPECTED.items():
        p = VENDOR / rel
        if not p.is_file():
            bad(f"{rel} is absent from the vendored tree -- the file list is stale, "
                f"which is a broken predicate rather than a passing one")
            continue
        calls = httpx_calls(io.open(p, encoding="utf-8").read())
        if not calls:
            bad(f"{rel}: ZERO httpx calls parsed. A file that was grafted for having "
                f"them now has none -- predicate broken, not property satisfied")
            continue
        unguarded = [(ln, fn) for ln, fn, g in calls if not g]
        total += len(calls)
        if unguarded:
            bad(f"{rel}: {len(unguarded)} httpx call(s) without trust_env=False "
                f"at line(s) {[ln for ln, _ in unguarded]} -- a customer's proxy "
                f"can capture this local traffic")
        elif len(calls) != expect:
            bad(f"{rel}: expected {expect} httpx call(s), parsed {len(calls)}. "
                f"All are guarded, but the count moved: re-read the new site and "
                f"confirm it is LOCAL before updating this number. An external "
                f"host must NOT get trust_env=False.")
        else:
            ok(f"{rel}: {len(calls)}/{len(calls)} local httpx call(s) guarded")

    # ── CONTROL THAT MUST FAIL ────────────────────────────────────────────
    # If the detector cannot see an unguarded call, every PASS above is noise.
    probe = httpx_calls(
        "import httpx\n"
        "a = httpx.post('http://127.0.0.1:7878/query', content='x')\n"
        "b = httpx.post('http://127.0.0.1:7878/query', content='x', trust_env=False)\n"
        "c = httpx.Client(timeout=1.0, trust_env=True)\n")
    guarded = [g for _, _, g in probe]
    if len(probe) == 3 and guarded == [False, True, False]:
        ok("CONTROL: the detector reports unguarded=True for a bare call, "
           "guarded for trust_env=False, and UNGUARDED for trust_env=True "
           "(so it reads the value, not merely the keyword)")
    else:
        bad(f"CONTROL FAILED: detector returned {probe} on a synthetic triple. "
            f"Every verdict above is unsafe.")

    print(f"\n== {PASS} pass / {FAIL} fail / {PASS + FAIL} total, "
          f"{total} httpx call site(s) examined ==")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
