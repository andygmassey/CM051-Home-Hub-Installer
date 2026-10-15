#!/usr/bin/env bash
# =============================================================================
# Every Doctor source row shows ONE honest total, in the unit it names
# (v1.0.107 walk #28, Andy's console walk of candidate #28)
# =============================================================================
#
# WHAT THE WALK FOUND, one row at a time:
#
#   Mail      the last tick's delta (email-ingest's per-run "emitted"), not the
#             mail Ostler has read
#   WhatsApp  people_added (roughly one per DM chat) under a "messages" label
#   Safari    visits under a "web pages" label
#   Photos    a bare number with no unit in the Doctor's own table
#   Notes     four different numbers across the surfaces that show it
#
# WHAT THIS ASSERTS. A fixture with KNOWN totals, every one of them a
# different number from the wrong population it could be confused with, then
# the REAL vendored reader (/api/v1/sources rows: item_count + item_unit) and
# the REAL vendored renderer (the "Where your data came from" Items cell).
#
#   Mail      emails.json done=4321 (cumulative)  vs  tick emitted=37,
#             install messages=300; Mail store 353,842
#                                     -> 4,321 of 353,842 emails read
#   WhatsApp  messages.whatsapp.json done=9876    vs  people_added=58 -> 9,876 messages
#   Safari    5 distinct urls over 13 visits      vs  sent=13         -> 5 web pages
#   Photos    extraction_summary photo_events=55  vs  install 40      -> 55 photos
#   Notes     extraction_summary notes=23         vs  install 20,
#             Evernote settling done=999                              -> 23 notes
#
# Controls: calendar keeps its sentinel figure (500 events), and imessage's
# people=6719 is never printed as messages.
#
# MAIL'S DENOMINATOR (follow-up on #2920). The Mail store size is counted at
# EXTRACT time by vendor/ostler_fda apple_mail.envelope_index_total over a
# synthetic Envelope Index (deleted rows left out), recorded by extract_all as
# apple_mail.mailbox_total, and read by the Doctor. When it cannot be read, or
# is smaller than what Ostler holds, the row shows only the held count: no
# "of", never "of 0".
#
# COUNT KIND (from the closed duplicate #2922). Every row with a figure says
# count_kind "total" or "last_check"; a row whose only figure is a per-run
# delta is labelled "in the last check", never as a total.
#
# Fixture values are FABRICATED. No real person, url or message appears.
#
# THREE OUTCOMES: 0 pass, 1 a row says something untrue, 2 CANNOT-RUN.
# =============================================================================
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WEBUI="${REPO}/vendor/doctor/agent/web_ui.py"
[ -f "$WEBUI" ] || { echo "CANNOT-RUN: no web_ui.py at ${WEBUI}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/honesttotal-XXXXXX")" || { echo "CANNOT-RUN: mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# OSTLER_DIR and OSTLER_HOME both sandboxed: the reader resolves the hydrate
# dir from one and the settling / extract dirs from the other, and either one
# unset would fall through to the REAL ~/.ostler of whoever runs this.
OSTLER_HOME="${WORK}/box" OSTLER_DIR="${WORK}/box" python3 - "$WEBUI" <<'PY'
import html, json, os, re, sys, types
from pathlib import Path

PASS = FAIL = 0
def ok(m):
    global PASS; PASS += 1; print("  [PASS] " + m)
def bad(m):
    global FAIL; FAIL += 1; print("  [FAIL] " + m)

root = Path(os.environ["OSTLER_DIR"])
hyd = root / "state" / "hydrate"
settle = root / "state" / "settling_progress.d"
fda = root / "imports" / "fda"
for d in (hyd, settle, fda):
    d.mkdir(parents=True, exist_ok=True)

def sentinel(name, payload, count, status="ok"):
    (hyd / (name + ".done")).write_text(
        "recorded_at=2026-10-01T08:00:00Z\nsource=%s\nstatus=%s\n"
        "item_count=%d\nlast_update_at=2026-10-01T08:00:00Z\npayload=%s\n"
        % (name, status, count, payload), encoding="utf-8")

def ledger(fname, done, total):
    (settle / fname).write_text(json.dumps({"done": done, "total": total}), encoding="utf-8")

def visits(fname, urls):
    (fda / fname).write_text(json.dumps([
        {"type": "web_visit", "timestamp": "2026-10-01T08:00:00+00:00",
         "url": u, "domain": "example.test", "title": None,
         "visit_count": 1, "source": fname.split(".")[0]} for u in urls]),
        encoding="utf-8")

# ── the fixture: known totals, each distinct from its wrong population ──
sentinel("email", "people=12,messages=300", 300)
ledger("emails.json", 4321, 5000)
MAIL_STORE = 353842
sentinel("whatsapp", "people_added=58", 58)
ledger("messages.whatsapp.json", 9876, 12000)
sentinel("browsing", "sent=13,skipped=0", 13)
visits("safari_history.json",
       ["https://example.test/a"] * 4 + ["https://example.test/b"] * 3
       + ["https://example.test/c"] * 2 + ["https://example.test/d"])
visits("chrome_history.json",
       ["https://example.test/a", "https://example.test/e", "https://example.test/e"])
sentinel("photos", "recognised_people=0,photo_events=40", 40)
sentinel("apple_notes", "notes=20", 20)
ledger("notes.json", 999, 999)          # Evernote's channel, NOT Apple Notes
(fda / "extraction_summary.json").write_text(json.dumps({"sources": {
    "photos": {"status": "ok", "recognised_people": 0, "photo_events": 55},
    "apple_notes": {"status": "ok", "notes": 23, "total_words": 4100},
    "apple_mail": {"status": "ok", "total_messages": 4400, "mailbox_total": MAIL_STORE},
}}), encoding="utf-8")
sentinel("calendar", "events=500", 500)
sentinel("imessage", "people=6719", 6719)

# The tick's per-run figure: the number Mail used to print.
fake = types.ModuleType("routine_status")
fake.read_routine_status = lambda: [{
    "routine": "com.creativemachines.ostler.email-ingest", "health": "ok",
    "last_run_at": "2026-10-01T09:00:00Z", "latest": {"emitted": 37}}]
sys.modules["routine_status"] = fake

# ── lift the SHIPPED reader and renderer (fastapi is not on every runner) ──
src = Path(sys.argv[1]).read_text(encoding="utf-8")
def block(a, b, what):
    try:
        i, j = src.index(a), src.index(b)
    except ValueError:
        print("CANNOT-RUN: could not locate %s in web_ui.py" % what, file=sys.stderr)
        sys.exit(2)
    return src[i:j]
reader = block("_SOURCE_KINDS = {", '@app.get("/api/v1/sources"', "the reader")
render = block("def render_source_status() -> str:", "def render_dashboard(", "the renderer")
ns = {"html": html}
try:
    exec("from pathlib import Path\nimport os, json\n" + reader, ns)
    exec(render, ns)
    rows = {r["source"]: r for r in ns["read_source_status"]()}
    page = ns["render_source_status"]()
except Exception as exc:  # noqa: BLE001
    print("CANNOT-RUN: shipped reader/renderer raised %s: %s"
          % (type(exc).__name__, exc), file=sys.stderr)
    sys.exit(2)

cells = {}
for tr in re.findall(r"<tr>(.*?)</tr>", page, re.S):
    tds = re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)
    if len(tds) >= 3:
        plain = [re.sub(r"<[^>]+>", "", c).strip() for c in tds]
        cells[plain[0]] = plain[2]
if len(cells) < 10:
    print("CANNOT-RUN: the renderer produced %d rows" % len(cells), file=sys.stderr)
    sys.exit(2)

def check(label, source, cell_name, want_n, want_unit, wrong, want_cell=None):
    r = rows.get(source) or {}
    n, unit = r.get("item_count"), r.get("item_unit")
    if n == want_n and unit == want_unit:
        ok("%s: /api/v1/sources says %s %s" % (label, want_n, want_unit))
    else:
        bad("%s: /api/v1/sources says item_count=%r item_unit=%r, expected %r %r (%s)"
            % (label, n, unit, want_n, want_unit, wrong))
    want_cell = want_cell or "{:,} {}".format(want_n, want_unit)
    if r.get("count_kind") == "total":
        ok("%s: count_kind is total" % label)
    else:
        bad("%s: count_kind=%r, expected 'total'" % (label, r.get("count_kind")))
    got = cells.get(cell_name)
    if got == want_cell:
        ok("%s: the Doctor table reads '%s'" % (label, want_cell))
    else:
        bad("%s: the Doctor table reads %r, expected %r (%s)" % (label, got, want_cell, wrong))

check("Mail", "email", "email", 4321, "emails",
      "37 is the last tick's delta, 300 the install-time run",
      want_cell="4,321 of 353,842 emails read")
check("WhatsApp", "whatsapp", "whatsapp", 9876, "messages",
      "58 is people added, one per DM chat")
check("Safari", "browsing", "browsing", 5, "web pages",
      "13 is visits; there are 5 distinct pages")
check("Photos", "photos", "photos", 55, "photos",
      "40 is the frozen install-time figure")
check("Notes", "apple_notes", "apple notes", 23, "notes",
      "20 is CM024 'Files written' at install, 999 is Evernote")

# ── controls ──
check("CONTROL calendar", "calendar", "calendar", 500, "events",
      "a sentinel already in its unit must survive untouched")
im = rows.get("imessage") or {}
if im.get("item_count") != 6719 and "6,719" not in (cells.get("imessage") or ""):
    ok("CONTROL imessage: people=6719 is not printed as messages")
else:
    bad("CONTROL imessage: people=6719 shown as the message total (%r / %r)"
        % (im.get("item_count"), cells.get("imessage")))

# ── Mail's denominator: produced at extract time, read by the Doctor ──
import importlib, sqlite3
# apple_mail.py is loaded AS PART OF its package: since #2908 (V26) it does
# `from .tcc_refusal import is_fda_refusal`, which a bare file load cannot resolve.
sys.path.insert(0, str(Path(sys.argv[1]).parents[2]))
try:
    am = importlib.import_module("ostler_fda.apple_mail")
    count_fn = am.envelope_index_total
except Exception as exc:  # noqa: BLE001
    _why = "NOT IMPORTABLE (%s: %s)" % (type(exc).__name__, exc)
    count_fn = lambda _db: _why  # every extractor case below then FAILS, by name

def envelope(name, rows, with_deleted=True):
    db = root / name
    c = sqlite3.connect(db)
    if with_deleted:
        c.execute("CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER, deleted INTEGER)")
        c.executemany("INSERT INTO messages (subject, deleted) VALUES (?, ?)", rows)
    else:
        c.execute("CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, subject INTEGER)")
        c.executemany("INSERT INTO messages (subject) VALUES (?)", [(r[0],) for r in rows])
    c.commit(); c.close()
    return db

seven = [(1, 0), (2, 0), (3, 1), (4, 0), (5, 1), (6, 0), (7, None)]
for what, got, want in (
    ("deleted rows left out (7 rows, 2 deleted)", count_fn(envelope("ei_a", seven)), 5),
    ("no deleted flag in the schema: every row", count_fn(envelope("ei_b", seven, False)), 7),
    ("an empty store is unknown, not 0", count_fn(envelope("ei_c", [])), None),
    ("a missing store is unknown, not 0", count_fn(root / "no_such_envelope"), None),
):
    if got == want:
        ok("extractor: %s -> %r" % (what, got))
    else:
        bad("extractor: %s -> %r, expected %r" % (what, got, want))

ea = (Path(sys.argv[1]).parents[2] / "ostler_fda" / "extract_all.py").read_text(encoding="utf-8")
if 'stats["mailbox_total"] = mailbox_total' in ea and "envelope_index_total()" in ea:
    ok("extract_all records apple_mail.mailbox_total in the extraction summary")
else:
    bad("extract_all does not record apple_mail.mailbox_total")

def mail_after(summary_mail, sentinel_count=300, keep_ledger=True):
    doc = json.loads((fda / "extraction_summary.json").read_text(encoding="utf-8"))
    if summary_mail is None:
        doc["sources"].pop("apple_mail", None)
    else:
        doc["sources"]["apple_mail"] = summary_mail
    (fda / "extraction_summary.json").write_text(json.dumps(doc), encoding="utf-8")
    sentinel("email", "people=12,messages=%d" % sentinel_count, sentinel_count)
    if not keep_ledger:
        (settle / "emails.json").unlink(missing_ok=True)
    r = {x["source"]: x for x in ns["read_source_status"]()}["email"]
    pg = ns["render_source_status"]()
    cell = None
    for tr in re.findall(r"<tr>(.*?)</tr>", pg, re.S):
        tds = [re.sub(r"<[^>]+>", "", c).strip() for c in re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)]
        if len(tds) >= 3 and tds[0] == "email":
            cell = tds[2]
    return r, cell

for what, mail, want in (
    ("no mailbox_total recorded", {"status": "ok", "total_messages": 4400}, "4,321 emails read"),
    ("mailbox_total 0", {"status": "ok", "mailbox_total": 0}, "4,321 emails read"),
    ("no apple_mail record at all", None, "4,321 emails read"),
    ("store smaller than what Ostler holds", {"status": "ok", "mailbox_total": 4000}, "4,321 emails read"),
):
    r, cell = mail_after(mail)
    if cell == want and r.get("count_label") == want and " of " not in (cell or ""):
        ok("Mail, %s: '%s', no 'of'" % (what, cell))
    else:
        bad("Mail, %s: cell %r label %r, expected %r with no 'of'" % (what, cell, r.get("count_label"), want))

# Only a per-run figure left: labelled as the last check, never as a total.
r, cell = mail_after({"status": "ok", "mailbox_total": MAIL_STORE}, sentinel_count=0, keep_ledger=False)
want = "37 emails in the last check"
if r.get("count_kind") == "last_check" and cell == want and r.get("item_count") is None:
    ok("Mail, only the tick's delta: count_kind last_check, '%s'" % cell)
else:
    bad("Mail, only the tick's delta: kind %r cell %r item_count %r, expected last_check %r"
        % (r.get("count_kind"), cell, r.get("item_count"), want))

print("\nCONCLUSION HISTOGRAM\n  PASS : %d\n  FAIL : %d\n  TOTAL: %d" % (PASS, FAIL, PASS + FAIL))
if PASS + FAIL < 29:
    print("CANNOT-RUN: only %d assertions ran" % (PASS + FAIL), file=sys.stderr)
    sys.exit(2)
sys.exit(1 if FAIL else 0)
PY
