#!/usr/bin/env bash
# The rendered "Items" column must show the LIVE count, not a stale
# install-time one, whenever read_source_status has already found one.
#
# WHY THIS EXISTS (v1.0.107 walk candidate #9, Andy's console walk,
# read-only). /api/v1/sources answered correctly at the DATA layer:
#
#     email     status=ok  item_count=0  last_run_count=11883
#               detail="the store holds 11883"
#     imessage  status=ok  item_count=0  last_run_count=29157
#               detail="the store holds 29157"
#
# `last_run_count` is populated exactly as designed (#2526/#2529,
# test_source_status_prefers_a_live_routine_over_a_stale_sentinel.sh) --
# email from the email-ingest routine's own log ("Emitted 11883
# message(s)"), imessage from the settling-progress ledger
# (state/settling_progress.d/messages.imessage.json). Neither is a bug.
#
# The bug is one function downstream: render_source_status() -- the ONLY
# human-visible rendering of this data, the Doctor's own "Where your data
# came from" table -- read `item_count` alone. It had never been taught
# that `last_run_count` exists. So the table printed "email ... read in
# ... 0" next to a row the API itself already knew held 11,883 items.
# ANSWER to "can 'read in'/'ok' show 0 while an ingest has items?": yes,
# and it was doing so, on the one surface a human actually looks at. (The
# wiki's own "Nothing found to read yet" text is a SEPARATE renderer, in a
# different repo (CM044, not vendored here) that most likely has the same
# gap against the same API -- out of reach from this tree to prove, but
# the API shape it would be reading from is the one pinned below.)
#
# Fixed: render_source_status() now prefers `last_run_count` over
# `item_count` whenever it says MORE -- never less, so a stale sentinel
# can never make a demonstrably-larger real total disappear, and never
# when there is nothing live to prefer.
#
# Fabricated fixture counts throughout -- not a real install's figures.
#
# THREE OUTCOMES. CANNOT-RUN is not a pass.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MOD="${REPO}/vendor/doctor/agent/web_ui.py"
[ -f "$MOD" ] || { echo "CANNOT-RUN: no web_ui.py at ${MOD}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }

python3 - "$MOD" <<'PY'
import sys, types, tempfile, pathlib, ast, json, os, re, html

MOD = sys.argv[1]
PASS = FAIL = 0
def ok(m):
    global PASS; PASS += 1; print("  [PASS] " + m)
def bad(m):
    global FAIL; FAIL += 1; print("  [FAIL] " + m)

src = pathlib.Path(MOD).read_text(encoding="utf-8")

# Fake `routine_status` BEFORE the function under test is defined, so
# read_source_status's `from routine_status import read_routine_status`
# resolves to data this test controls -- never the real
# LaunchAgent/launchd reader (unavailable and irrelevant in CI).
fake_routine_mod = types.ModuleType("routine_status")
_ROUTINE_ROWS = {"at": []}
fake_routine_mod.read_routine_status = lambda: _ROUTINE_ROWS["at"]
sys.modules["routine_status"] = fake_routine_mod

tree = ast.parse(src)
wanted = {"_source_activity_dir", "_read_source_activity", "_source_hydrate_dir",
          "_parse_source_sentinel", "read_source_status", "render_source_status",
          "_routine_evidence", "_routine_run_count", "_best_routine_count",
          "_settling_progress_total"}
ns = {"Path": pathlib.Path, "os": os, "json": json, "html": html}
for node in tree.body:
    if isinstance(node, (ast.Assign, ast.AnnAssign)):
        try:
            exec(compile(ast.Module([node], []), "<const>", "exec"), ns)
        except Exception:
            pass
for node in tree.body:
    if isinstance(node, ast.FunctionDef) and node.name in wanted:
        exec(compile(ast.Module([node], []), "<fn>", "exec"), ns)

missing = [n for n in wanted if n not in ns]
if missing:
    print("CANNOT-RUN: absent from the module: " + ", ".join(sorted(missing)), file=sys.stderr)
    raise SystemExit(2)

render_source_status = ns["render_source_status"]
KINDS = ns.get("_SOURCE_KINDS", {})
if "email" not in KINDS or "imessage" not in KINDS or "calendar" not in KINDS:
    print("CANNOT-RUN: email/imessage/calendar are not canonical sources in this tree.",
          file=sys.stderr)
    raise SystemExit(2)


def fresh_dir():
    root = pathlib.Path(tempfile.mkdtemp())
    (root / "state" / "hydrate").mkdir(parents=True)
    (root / "state" / "source_activity").mkdir(parents=True)
    os.environ["OSTLER_DIR"] = str(root)
    os.environ["OSTLER_HOME"] = str(root)
    return root


def sentinel(root, name, status, detail, count=0):
    (root / "state" / "hydrate" / (name + ".done")).write_text(
        "recorded_at=2026-09-04T08:39:15Z\nsource=%s\nstatus=%s\ndetail=%s\n"
        "item_count=%s\nlast_update_at=2026-09-04T08:39:15Z\n"
        % (name, status, detail, count), encoding="utf-8")


def settling(root, filename, total):
    d = root / "state" / "settling_progress.d"
    d.mkdir(parents=True, exist_ok=True)
    (d / filename).write_text(json.dumps({"done": total, "total": total}), encoding="utf-8")


def cells(page):
    out = {}
    for tr in re.findall(r"<tr>(.*?)</tr>", page, re.S):
        tds = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
        if len(tds) < 3:
            continue
        plain = [re.sub(r"<[^>]+>", "", c).strip() for c in tds]
        out[plain[0]] = plain[2]
    return out


UNKNOWN = "&mdash;"

# ── 1. THE REGRESSION ITSELF: email's sentinel is stale, the routine log
#      is not. RED on the pre-fix render_source_status, GREEN on the fix. ──
root = fresh_dir()
sentinel(root, "email", "no_data", "no_correspondents_in_window", count=0)
sentinel(root, "imessage", "no_data", "ran_ok_no_new_or_enriched_people", count=0)
sentinel(root, "calendar", "ok", "events=500", count=500)
_ROUTINE_ROWS["at"] = [{
    "routine": "com.creativemachines.ostler.email-ingest",
    "health": "ok",
    "last_run_at": "2026-09-04T09:53:00Z",
    "latest": {"emitted": 4200},
}]
settling(root, "messages.imessage.json", 15000)

page = render_source_status()
row = cells(page)

if row.get("email") == "4,200":
    ok("THE REGRESSION: email's rendered Items cell shows the live routine "
       "count 4,200, not the stale sentinel's 0")
else:
    bad("email renders '%s', expected 4,200. The render layer is still "
        "reading item_count alone." % row.get("email"))

if row.get("imessage") == "15,000":
    ok("imessage's rendered Items cell shows the settling-ledger total "
       "15,000, not the stale sentinel's 0")
else:
    bad("imessage renders '%s', expected 15,000" % row.get("imessage"))

# ── 2. CONTROL: a source with NO live count must keep its sentinel figure,
#      unchanged -- the override must not fire on nothing. ─────────────────
if row.get("calendar") == "500":
    ok("CONTROL: calendar has no live-count producer, so its sentinel figure "
       "500 renders unchanged")
else:
    bad("calendar renders '%s', expected its own sentinel figure 500 "
        "unchanged" % row.get("calendar"))

# ── 3. CONTROL: the sentinel's figure must win when it is the LARGER one --
#      proves the comparison is "prefer whichever says more", not an
#      unconditional swap to whatever the live producer reports. ──────────
root2 = fresh_dir()
sentinel(root2, "email", "ok", "messages=9000", count=9000)
sentinel(root2, "imessage", "no_data", "ran_ok_no_new_or_enriched_people", count=0)
sentinel(root2, "calendar", "ok", "events=1", count=1)
_ROUTINE_ROWS["at"] = [{
    "routine": "com.creativemachines.ostler.email-ingest",
    "health": "ok",
    "last_run_at": "2026-09-04T09:53:00Z",
    "latest": {"emitted": 500},
}]

page2 = render_source_status()
row2 = cells(page2)

if row2.get("email") == "9,000":
    ok("CONTROL: the sentinel's 9,000 beats a SMALLER live count (500) -- "
       "the override only ever says MORE, never less")
else:
    bad("email renders '%s', expected the larger sentinel figure 9,000 to "
        "win over the smaller live count" % row2.get("email"))

print("\nCONCLUSION HISTOGRAM\n  PASS : %d\n  FAIL : %d\n  TOTAL: %d"
      % (PASS, FAIL, PASS + FAIL))
if PASS + FAIL < 4:
    print("CANNOT-RUN: only %d assertions ran" % (PASS + FAIL), file=sys.stderr)
    raise SystemExit(2)
raise SystemExit(1 if FAIL else 0)
PY
