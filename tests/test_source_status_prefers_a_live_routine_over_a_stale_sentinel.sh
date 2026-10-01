#!/usr/bin/env bash
# A source can have TWO producers, and the Doctor must believe the live one --
# without ever turning its last run's count into a claim about the total.
#
# WHY THIS EXISTS (CM051 #2526, same board as the Data sources tab redesign).
# MEASURED on a walk box: state/source_activity/ did not exist at all --
# com.ostler.fda-rerun, its only writer, had never fired. So /api/v1/sources
# reported ongoing=never for every source, AND for some of them the
# install-time verdict itself was stale, in this shape:
#
#     email     status=no_data item_count=0   while email-ingest had just
#                                              ingested a real, non-zero count
#     imessage  status=no_data item_count=0   while imessage-bundle was
#                                              running on schedule
#
# Two different sub-systems answer "email": the FDA extractor's own narrow
# correspondents-in-window check, and the dedicated full-history bundle
# routine. The row is customer-facing and labelled "Email"; a customer whose
# mailbox the dedicated routine has actually read must not be told no_data
# because the OTHER sub-system found nothing in its own, different window.
#
# TWO DEFECTS CAUGHT ON REVIEW (Archie, #2529), both pinned below:
#   - the first draft took the FIRST positive integer anywhere in a routine's
#     `latest` dict, so a payload shaped like {"errors": 5} would have read
#     as "5 items processed". Fixed with an explicit per-routine key table.
#   - the first draft wrote the routine's per-run count into `item_count`,
#     which is supposed to be a TOTAL. A routine only ever reports what it did
#     on ONE run; that lives in the separate `last_run_count` field, and
#     `item_count` is never touched by any of this.
#
# Counts and timestamps below are FABRICATED fixture values, not a real
# install's data.
#
# THREE OUTCOMES. CANNOT-RUN is not a pass.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MOD="${REPO}/vendor/doctor/agent/web_ui.py"
[ -f "$MOD" ] || { echo "CANNOT-RUN: no web_ui.py at ${MOD}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }

python3 - "$MOD" <<'PY'
import sys, types, tempfile, pathlib, ast

MOD = sys.argv[1]
PASS = FAIL = 0
def ok(m):
    global PASS; PASS += 1; print("  [PASS] " + m)
def bad(m):
    global FAIL; FAIL += 1; print("  [FAIL] " + m)

# ASSERT THE ROW CONTRACT, NOT THE IMPLEMENTATION. Only `read_source_status`
# and `_SOURCE_KINDS` are required to exist: both predate this fix and are
# present in the tree that SHIPS the defect too, so that tree runs this test
# and FAILS on the contract (status stays no_data) rather than reporting
# CANNOT-RUN, which would prove nothing about the regression.
src = pathlib.Path(MOD).read_text(encoding="utf-8")
need = ["def read_source_status("]
missing = [n for n in need if n not in src]
if missing:
    print("CANNOT-RUN: absent from the module: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(2)

# A fake `routine_status` module, injected BEFORE the function under test is
# defined, so `from routine_status import read_routine_status` inside
# read_source_status resolves to data this test controls -- not the real
# LaunchAgent/launchd reader, which this test must not depend on.
fake_routine_mod = types.ModuleType("routine_status")
_ROUTINE_ROWS = {"at": []}
fake_routine_mod.read_routine_status = lambda: _ROUTINE_ROWS["at"]
sys.modules["routine_status"] = fake_routine_mod

tree = ast.parse(src)
wanted = {"_source_activity_dir", "_read_source_activity", "_source_hydrate_dir",
          "_parse_source_sentinel", "read_source_status", "_routine_evidence",
          "_routine_run_count"}
ns = {"Path": pathlib.Path, "os": __import__("os")}
for node in tree.body:
    if isinstance(node, (ast.Assign, ast.AnnAssign)):
        try:
            exec(compile(ast.Module([node], []), "<const>", "exec"), ns)
        except Exception:
            pass
for node in tree.body:
    if isinstance(node, ast.FunctionDef) and node.name in wanted:
        exec(compile(ast.Module([node], []), "<fn>", "exec"), ns)
if "_SOURCE_KINDS" not in ns:
    print("CANNOT-RUN: _SOURCE_KINDS not found; the reader cannot be driven.", file=sys.stderr)
    raise SystemExit(2)

read_source_status = ns["read_source_status"]
KINDS = ns["_SOURCE_KINDS"]
if "email" not in KINDS or "imessage" not in KINDS or "browsing" not in KINDS:
    print("CANNOT-RUN: email/imessage/browsing are not canonical sources in this tree.",
          file=sys.stderr)
    raise SystemExit(2)

import os as _os

def fresh_dir():
    root = pathlib.Path(tempfile.mkdtemp())
    (root / "state" / "hydrate").mkdir(parents=True)
    (root / "state" / "source_activity").mkdir(parents=True)
    _os.environ["OSTLER_DIR"] = str(root)
    ns["os"].environ["OSTLER_DIR"] = str(root)
    return root

def sentinel(root, name, status, detail, count=0):
    (root / "state" / "hydrate" / (name + ".done")).write_text(
        "recorded_at=2026-09-04T08:39:15Z\nsource=%s\nstatus=%s\ndetail=%s\n"
        "item_count=%s\nlast_update_at=2026-09-04T08:39:15Z\n"
        % (name, status, detail, count), encoding="utf-8")

def row_for(name, rows):
    for r in rows:
        if r["source"] == name:
            return r
    return None

# Fixture count: fabricated, not a real install's figure.
FAKE_EMAIL_COUNT = 4200

# ── 1. THE REGRESSION ITSELF: RED on the old code, GREEN on the fix ───────
# status flips to ok and last_run_count carries the routine's figure. The
# ORIGINAL item_count (0, from the stale sentinel) is UNTOUCHED -- it is not
# a total the routine's single run is entitled to overwrite.
root = fresh_dir()
sentinel(root, "email", "no_data", "no_correspondents_in_window", 0)
_ROUTINE_ROWS["at"] = [{
    "routine": "com.creativemachines.ostler.email-ingest",
    "health": "ok", "last_run_at": "2026-09-04T09:17:19Z",
    "latest": {"emitted": FAKE_EMAIL_COUNT},
}]
r = row_for("email", read_source_status())
if r and r.get("status") == "ok" and r.get("last_run_count") == FAKE_EMAIL_COUNT:
    ok("a stale no_data sentinel is overridden, with the routine's count in last_run_count")
else:
    bad("email reported status=%r last_run_count=%r -- the live routine's evidence was not used"
        % (r.get("status") if r else None, r.get("last_run_count") if r else None))
if r and r.get("item_count") == 0:
    ok("CONTROL: item_count (the total) is left exactly as the sentinel wrote it")
else:
    bad("CONTROL failed: item_count=%r -- the per-run count overwrote the total"
        % (r.get("item_count") if r else None))
if r and r.get("ongoing") == "active" and r.get("last_run_at") == "2026-09-04T09:17:19Z":
    ok("ongoing flips to active with the routine's own run time")
else:
    bad("ongoing=%r last_run_at=%r" % (r.get("ongoing") if r else None, r.get("last_run_at") if r else None))

# ── 2. CONTROL: an errors-only payload is never read as a count ───────────
# Archie, #2529: the first draft took the first positive int anywhere in
# `latest`, so {"errors": 5} would have read as "5 items processed". There is
# no recognised key in this payload at all, so last_run_count must stay None
# and the stale no_data status must NOT be upgraded by it -- though ongoing
# still flips (the routine itself ran and is healthy; that is a fact
# independent of whether it logged a trustworthy count this time).
root = fresh_dir()
sentinel(root, "email", "no_data", "no_correspondents_in_window", 0)
_ROUTINE_ROWS["at"] = [{
    "routine": "com.creativemachines.ostler.email-ingest",
    "health": "ok", "last_run_at": "2026-09-04T09:17:19Z",
    "latest": {"errors": 5},
}]
r = row_for("email", read_source_status())
if r and r.get("last_run_count") is None and r.get("status") == "no_data":
    ok("CONTROL: an errors-only payload is never read as a count, and does not upgrade status")
else:
    bad("CONTROL failed: last_run_count=%r status=%r -- an unrecognised key was trusted as a count"
        % (r.get("last_run_count") if r else None, r.get("status") if r else None))

# ── 3. CONTROL: no numeric evidence means no invented count ───────────────
# imessage-bundle is running (health=ok) but its log tail had nothing
# parseable this cycle. The source must flip to ongoing=active (the routine
# IS alive) without fabricating a count the evidence does not contain.
root = fresh_dir()
sentinel(root, "imessage", "no_data", "ran_ok_no_new_or_enriched_people", 0)
_ROUTINE_ROWS["at"] = [{
    "routine": "com.creativemachines.ostler.imessage-bundle",
    "health": "ok", "last_run_at": "2026-09-04T09:20:00Z", "latest": {},
}]
r = row_for("imessage", read_source_status())
if r and r.get("ongoing") == "active" and r.get("last_run_count") is None and r.get("status") == "no_data":
    ok("CONTROL: a live routine with no numeric evidence flips ongoing=active without inventing a count")
else:
    bad("CONTROL failed: status=%r last_run_count=%r ongoing=%r"
        % (r.get("status") if r else None, r.get("last_run_count") if r else None, r.get("ongoing") if r else None))

# ── 4. CONTROL: an unwell routine must not be believed ─────────────────────
# Same email shape, but the routine itself is failing. Overriding here would
# tell the customer "ok" from a routine that is not, which is worse than the
# defect this closes.
root = fresh_dir()
sentinel(root, "email", "no_data", "no_correspondents_in_window", 0)
_ROUTINE_ROWS["at"] = [{
    "routine": "com.creativemachines.ostler.email-ingest",
    "health": "failing", "last_run_at": "2026-09-04T09:17:19Z",
    "latest": {"emitted": FAKE_EMAIL_COUNT},
}]
r = row_for("email", read_source_status())
if r and r.get("status") == "no_data" and r.get("ongoing") == "never" and r.get("last_run_count") is None:
    ok("CONTROL: a failing routine's count is never trusted, even though it is numeric")
else:
    bad("CONTROL failed: status=%r ongoing=%r last_run_count=%r -- an unwell routine was believed"
        % (r.get("status") if r else None, r.get("ongoing") if r else None, r.get("last_run_count") if r else None))

# ── 5. CONTROL: a direct activity record still wins outright ──────────────
# fda-rerun's own evidence (when it exists) must not be second-guessed by the
# routine-evidence path; this proves the short-circuit fires.
root = fresh_dir()
sentinel(root, "email", "no_data", "no_correspondents_in_window", 0)
(root / "state" / "source_activity" / "apple_mail.tsv").write_text(
    "source=apple_mail\nlast_run_at=2026-09-04T10:00:00Z\nlast_status=ok\n"
    "last_success_at=2026-09-04T10:00:00Z\n", encoding="utf-8")
_ROUTINE_ROWS["at"] = [{
    "routine": "com.creativemachines.ostler.email-ingest",
    "health": "ok", "last_run_at": "2026-09-04T09:17:19Z", "latest": {"emitted": 1},
}]
r = row_for("email", read_source_status())
if r and r.get("last_run_at") == "2026-09-04T10:00:00Z" and r.get("last_run_count") is None:
    ok("CONTROL: a direct activity record wins outright; the routine path never ran")
else:
    bad("CONTROL failed: last_run_at=%r last_run_count=%r -- the direct activity record was overridden"
        % (r.get("last_run_at") if r else None, r.get("last_run_count") if r else None))

# ── 6. CONTROL: a source with no mapped routine is untouched ──────────────
# If the lookup were fuzzy rather than table-driven, "browsing" could pick up
# an unrelated routine row. It must not.
root = fresh_dir()
sentinel(root, "browsing", "ok", "sent=650,skipped=12", 650)
_ROUTINE_ROWS["at"] = [{
    "routine": "com.ostler.fda-rerun", "health": "ok",
    "last_run_at": "2026-09-04T10:00:00Z", "latest": {"emitted": 999},
}]
r = row_for("browsing", read_source_status())
if r and r.get("ongoing") == "never" and r.get("item_count") == 650 and r.get("last_run_count") is None:
    ok("CONTROL: a source with no mapped routine is not joined to an unrelated one")
else:
    bad("CONTROL failed: ongoing=%r item_count=%r last_run_count=%r"
        % (r.get("ongoing") if r else None, r.get("item_count") if r else None, r.get("last_run_count") if r else None))

print()
print("== %d pass / %d fail / %d total ==" % (PASS, FAIL, PASS + FAIL))
raise SystemExit(1 if FAIL else 0)
PY
