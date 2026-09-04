#!/usr/bin/env bash
# The source-status surface must answer TWO questions, not one.
#
# WHY THIS EXISTS. MEASURED on the Mini 16, 2026-09-04, during the v1.0.63
# walk. All eleven hydrate sentinels were frozen between 08:29Z and 08:45Z --
# install time -- while the fda-rerun tick rewrote imessage_conversations.json
# at 09:17Z with 167 conversations and 136 people created. /api/v1/sources
# still answered:
#
#     imessage  status=no_data  item_count=0  detail=zero_payload_undeclared
#
# The extract moved and the record did not, because nothing outside install.sh
# had ever written a sentinel. The route's own docstring promises it shows
# "whether a source landed AND WHETHER IT KEEPS UPDATING", and the second half
# was unanswerable by construction. A source that failed at install showed
# failed forever after it recovered; one that worked showed ok forever after it
# died.
#
# Andy, on being shown it: "THEN FIX IT!!!!!! I dont' EVER want to hear about
# this as a failure point AGAIN!!"
#
# THREE STATES: 0 pass, 1 fail, 2 cannot-run. CANNOT-RUN is not a pass --
# ingest_coverage was carried as CANNOT-RUN across four cuts and that is how
# these failures stayed invisible.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MOD="${REPO}/vendor/doctor/agent/web_ui.py"
[ -f "$MOD" ] || { echo "CANNOT-RUN: no web_ui.py at ${MOD}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }

python3 - "$MOD" <<'PY'
import sys, types, importlib.util, tempfile, pathlib

MOD = sys.argv[1]
PASS = FAIL = 0
def ok(m):
    global PASS; PASS += 1; print("  [PASS] " + m)
def bad(m):
    global FAIL; FAIL += 1; print("  [FAIL] " + m)

# Import ONLY the two functions under test, by source-extracting them, so this
# test needs neither fastapi nor httpx. Importing the whole module would make
# a missing web dependency look like a defect in the code under test -- a
# CANNOT-RUN wearing the costume of a FAIL.
src = pathlib.Path(MOD).read_text(encoding="utf-8")
# ASSERT THE ROW CONTRACT, NOT THE IMPLEMENTATION. An earlier draft of this
# test required the two new helper functions by name, so against the tree that
# SHIPPED the defect it reported CANNOT-RUN instead of FAIL -- and a red-first
# that cannot go red proves nothing. These two exist in every tree, so the test
# runs against old and new alike and the OLD one fails on the missing fields,
# which is the actual defect a customer sees.
need = ["def _parse_source_sentinel(", "def read_source_status("]
missing = [n for n in need if n not in src]
if missing:
    print("CANNOT-RUN: functions absent from the module: " + ", ".join(missing),
          file=sys.stderr)
    raise SystemExit(2)

import ast
tree = ast.parse(src)
wanted = {"_source_activity_dir", "_read_source_activity",
          "_source_hydrate_dir", "_parse_source_sentinel", "read_source_status"}
ns = {"Path": pathlib.Path, "os": __import__("os")}
# Module-level constants the reader depends on (_SOURCE_KINDS and the field
# coercion tables). Taken verbatim, best-effort: any assignment that needs an
# unavailable import is skipped rather than aborting, and the explicit
# _SOURCE_KINDS check below turns a genuinely missing one into CANNOT-RUN
# instead of a silent partial run.
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
    print("CANNOT-RUN: _SOURCE_KINDS not found; the reader cannot be driven.",
          file=sys.stderr)
    raise SystemExit(2)

read_source_status = ns["read_source_status"]
KINDS = ns["_SOURCE_KINDS"]
subject = "imessage" if "imessage" in KINDS else sorted(KINDS)[0]
other   = [k for k in sorted(KINDS) if k != subject][0]

# Driven entirely through OSTLER_DIR, which BOTH trees honour, so the same
# test exercises the old one-argument signature and the new two-argument one
# without knowing which it has.
import os as _os
tmp = pathlib.Path(tempfile.mkdtemp())
_os.environ["OSTLER_DIR"] = str(tmp)
ns["os"].environ["OSTLER_DIR"] = str(tmp)
hyd = tmp / "state" / "hydrate"; act = tmp / "state" / "source_activity"
hyd.mkdir(parents=True); act.mkdir(parents=True)

def sentinel(name, status, detail, count="0"):
    (hyd / (name + ".done")).write_text(
        "recorded_at=2026-09-04T08:39:15Z\nsource=%s\nstatus=%s\ndetail=%s\n"
        "item_count=%s\nlast_update_at=2026-09-04T08:39:15Z\npayload=people=0\n"
        % (name, status, detail, count), encoding="utf-8")

def activity(name, last_status, run_at, success_at):
    (act / (name + ".tsv")).write_text(
        "source=%s\nlast_run_at=%s\nlast_status=%s\nlast_success_at=%s\n"
        "last_detail={}\nwriter=ostler-fda\n"
        % (name, run_at, last_status, success_at), encoding="utf-8")

def row_for(name, rows):
    for r in rows:
        if r["source"] == name:
            return r
    return None

# ── 1. No ongoing record must read "never", NOT "failing" ────────────────
# Inventing a failure is exactly as wrong as hiding one, and a box installed
# before this record existed legitimately has nothing here.
sentinel(subject, "ok", "people=3284")
rows = read_source_status()
r = row_for(subject, rows)
if r is None:
    bad("the subject source is missing from the rows entirely")
elif r.get("ongoing") == "never":
    ok("no ongoing record reads 'never' rather than inventing a failure")
else:
    bad("no ongoing record reported ongoing=%r; it must be 'never'" % r.get("ongoing"))

# ── 2. THE REGRESSION ITSELF ─────────────────────────────────────────────
# install said no_data; the tick has since succeeded. This is the exact Mini 16
# state: no_data at 08:39Z, real work at 09:17Z.
sentinel(subject, "no_data", "zero_payload_undeclared")
activity(subject, "ok", "2026-09-04T09:17:19Z", "2026-09-04T09:17:19Z")
rows = read_source_status()
r = row_for(subject, rows)
if r.get("ongoing") == "active" and r.get("last_run_at") == "2026-09-04T09:17:19Z":
    ok("a source that failed at install but succeeded since reports ongoing=active with its run time")
else:
    bad("ongoing=%r last_run_at=%r -- the recovery is still invisible"
        % (r.get("ongoing"), r.get("last_run_at")))

# ── 3. CONTROL: the install verdict must NOT be overwritten ──────────────
# Two records answering two questions. If the ongoing record silently replaced
# the install one, this limb goes red -- which is the failure mode of
# "just repurpose the sentinel", the shortcut this design refused.
if r.get("status") == "no_data" and r.get("detail") == "zero_payload_undeclared":
    ok("CONTROL: the install-time verdict survives untouched beside the ongoing one")
else:
    bad("CONTROL: install verdict was overwritten (status=%r detail=%r). Two questions, two records."
        % (r.get("status"), r.get("detail")))

# ── 4. A failing tick must be visible, and must keep its last success ────
sentinel(other, "ok", "imported=2413")
activity(other, "error", "2026-09-04T10:00:00Z", "2026-09-04T08:29:38Z")
rows = read_source_status()
r2 = row_for(other, rows)
if r2.get("ongoing") == "failing":
    ok("a source that WORKED at install but whose tick now fails reports ongoing=failing")
else:
    bad("a currently-failing tick reported ongoing=%r; install-time ok must not mask it"
        % r2.get("ongoing"))
if r2.get("last_success_at") == "2026-09-04T08:29:38Z":
    ok("last_success_at is carried, so a failing source still shows when it last worked")
else:
    bad("last_success_at=%r -- history lost on the first bad tick" % r2.get("last_success_at"))

# ── 5. CONTROL: the predicate must be able to FAIL ───────────────────────
# Point the reader at an EMPTY activity dir with the same sentinels. If limb 2
# still reported "active" here, it would be reading something other than the
# activity record and every limb above would be meaningless.
# A whole second root with the SAME sentinels and NO activity dir.
empty_root = pathlib.Path(tempfile.mkdtemp())
(empty_root / "state").mkdir()
import shutil as _sh
_sh.copytree(hyd, empty_root / "state" / "hydrate")
ns["os"].environ["OSTLER_DIR"] = str(empty_root)
_os.environ["OSTLER_DIR"] = str(empty_root)
rows = read_source_status()
r3 = row_for(subject, rows)
if r3.get("ongoing") == "never":
    ok("CONTROL: with no activity dir the same source reports 'never' -- the limbs above read the real record")
else:
    bad("CONTROL: ongoing=%r with an EMPTY activity dir. The reader is not reading what this test writes."
        % r3.get("ongoing"))

# ── 6. The alias table must actually bridge the two naming schemes ───────
# MEASURED on the Mini 16: the tick writes apple_mail / browser_history /
# bookmarks / people_index, and the canonical names are email / browsing /
# people. Only 3 of 9 records matched by name, so three sources reported
# "never" while their ingest had just succeeded. The code was self-consistent
# and the tests passed, because both sides of the join were written from the
# same wrong assumption. This limb drives the alias explicitly.
aliases = ns.get("_SOURCE_ACTIVITY_ALIASES", {})
if not aliases:
    bad("no alias table -- the tick's key names cannot reach the canonical rows")
else:
    checked = 0
    for canon, alts in aliases.items():
        if canon not in KINDS:
            bad("alias table maps %r, which is not a canonical source" % canon)
            continue
        alt = alts[0]
        root = pathlib.Path(tempfile.mkdtemp())
        _os.environ["OSTLER_DIR"] = str(root)
        ns["os"].environ["OSTLER_DIR"] = str(root)
        h = root / "state" / "hydrate"; a = root / "state" / "source_activity"
        h.mkdir(parents=True); a.mkdir(parents=True)
        (h / (canon + ".done")).write_text(
            "source=%s\nstatus=ok\ndetail=x\nitem_count=1\n" % canon,
            encoding="utf-8")
        # Write the record under the TICK's name only, never the canonical one.
        (a / (alt + ".tsv")).write_text(
            "source=%s\nlast_run_at=2026-09-04T09:31:14Z\nlast_status=ok\n"
            "last_success_at=2026-09-04T09:31:14Z\n" % alt, encoding="utf-8")
        got = row_for(canon, read_source_status())
        if got and got.get("ongoing") == "active":
            checked += 1
        else:
            bad("alias %s -> %s did not bridge: ongoing=%r"
                % (alt, canon, got.get("ongoing") if got else None))
    if checked == len(aliases):
        ok("every alias bridges the tick's key to its canonical row (%d of %d)"
           % (checked, len(aliases)))

# ── 7. CONTROL: a source with NO alias must not be accidentally joined ────
# If the lookup were fuzzy rather than table-driven, apple_notes would pick up
# apple_mail's record and report a source as working on somebody else's
# evidence. That is a worse failure than the one being fixed.
if "apple_notes" in KINDS:
    root = pathlib.Path(tempfile.mkdtemp())
    _os.environ["OSTLER_DIR"] = str(root)
    ns["os"].environ["OSTLER_DIR"] = str(root)
    h = root / "state" / "hydrate"; a = root / "state" / "source_activity"
    h.mkdir(parents=True); a.mkdir(parents=True)
    (h / "apple_notes.done").write_text(
        "source=apple_notes\nstatus=no_data\ndetail=no_export_json\nitem_count=0\n",
        encoding="utf-8")
    (a / "apple_mail.tsv").write_text(
        "source=apple_mail\nlast_run_at=2026-09-04T09:31:14Z\nlast_status=ok\n"
        "last_success_at=2026-09-04T09:31:14Z\n", encoding="utf-8")
    got = row_for("apple_notes", read_source_status())
    if got and got.get("ongoing") == "never":
        ok("CONTROL: apple_notes is NOT joined to apple_mail's record by a loose match")
    else:
        bad("CONTROL: apple_notes picked up a foreign record (ongoing=%r). The lookup is not table-driven."
            % (got.get("ongoing") if got else None))

print()
print("== %d pass / %d fail / %d total ==" % (PASS, FAIL, PASS + FAIL))
raise SystemExit(1 if FAIL else 0)
PY
