#!/usr/bin/env bash
# THE DOCTOR'S SOURCE TABLE MUST COVER EVERY SOURCE THE CUSTOMER WAS ASKED FOR.
#
# ============================================================================
# WHAT A CUSTOMER SAW, MEASURED ON origin/main AT d0c207fd
# ============================================================================
#
# Reminders is ON BY DEFAULT and is in the Recommended preset. A customer ticks
# it, the extractor runs, and imports/fda/extraction_summary.json records the
# verdict. The panel headed "Where your data came from" then shows thirteen
# rows and none of them is Reminders. Its own copy promises the opposite:
#
#     "Every source Ostler reads, whether it has run, how much it found and
#      when it last looked. A source that has never run says so rather than
#      being left out."
#
# A register that silently omits a source is worse than one that lists it as
# failing, because the omission is invisible to the reader. Nothing was red.
#
# 🔴 AND THE OBVIOUS FIX WOULD HAVE CHANGED NOTHING. Writing reminders.done
# and photos.done, which is what "add them to OSTLER_SENTINEL_SOURCES" means,
# was MEASURED against the real vendored renderer with both files on disk and
# both parseable: 13 rows, no Reminders, no Photos, while the positive control
# imessage.done rendered its row. The table is not built from the sentinel
# directory. collect_hydrate_markers globs it and the TABLE does not call that;
# read_source_status iterates a hard-coded register. Writer and reader move
# together or the customer sees nothing change.
#
# ============================================================================
# WHAT THIS TEST ASSERTS
# ============================================================================
#
# PART 1, the durable half (#1587 asks for exactly this). Four declared sets
# must agree, in the directions that catch a source added to one of them and
# forgotten in the others:
#
#   every FDA source install.sh can enable   ==  the left column of
#                                                OSTLER_FDA_SOURCE_ROWS
#   that left column                         subset of the shipped extractor's
#                                                own vocabulary (ALL_SOURCES)
#   the right column (canonical rows)        subset of OSTLER_SENTINEL_SOURCES
#   the right column                         subset of the Doctor's row
#                                                register
#
# PART 2, the consumer-side half. It EXECUTES the real recorders out of
# install.sh against a synthetic extraction summary, one scenario per state the
# extractor can report, then EXECUTES the real vendored renderer and reads the
# CELLS a person sees. The subject is a row in an HTML table, never a dict.
#
# Everything here is synthetic. No real reminder, photo, name or count.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run. A CANNOT-RUN is not a pass: the
# whole class of defect above is a surface that could not be measured being
# recorded as fine.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
WEBUI="${REPO}/vendor/doctor/agent/web_ui.py"
EXTRACT="${REPO}/vendor/ostler_fda/extract_all.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cannot() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -f "$SUBJECT" ]  || cannot "no install.sh at ${SUBJECT}"
[ -f "$WEBUI" ]    || cannot "no web_ui.py at ${WEBUI}"
[ -f "$EXTRACT" ]  || cannot "no extract_all.py at ${EXTRACT}"
command -v python3 >/dev/null 2>&1 || cannot "no python3"

WORK="$(mktemp -d)" || cannot "no working directory"
trap 'rm -rf "$WORK"' EXIT

# ============================================================================
# PART 1 -- the four declared sets must agree
# ============================================================================
echo "PART 1: the registers agree"

python3 - "$SUBJECT" "$WEBUI" "$EXTRACT" <<'PY'
import ast, re, sys

subject, webui, extract = sys.argv[1], sys.argv[2], sys.argv[3]
PASS = FAIL = 0
def ok(m):
    global PASS; PASS += 1; print("  [PASS] " + m)
def bad(m):
    global FAIL; FAIL += 1; print("  [FAIL] " + m)
def cannot(m):
    print("CANNOT-RUN: " + m, file=sys.stderr); raise SystemExit(2)

sh = open(subject, encoding="utf-8", errors="replace").read().split("\n")

# ── the set of FDA sources install.sh can put into OSTLER_FDA_SOURCES ─────
# Derived, not transcribed: a transcription is a second copy that drifts, and
# drift between two copies of one list is the defect being gated.
#
# Three shapes carry a source name: the preset assignments, the per-source
# picker call, and the :- default on OSTLER_FDA_SOURCES. The default is read
# from INSIDE the expansion; stripping ${...} wholesale drops apple_notes,
# which was measured while writing this and is why the two substitutions are
# ordered rather than combined.
offerable = set()
for line in sh:
    m = re.match(r'\s*_ask_source\s+"([a-z0-9_]+)"', line)
    if m:
        offerable.add(m.group(1))
        continue
    m = re.match(r'\s*(RECOMMENDED|EVERYTHING|OSTLER_FDA_SOURCES)="([^"]*)"\s*$',
                 line)
    if m:
        rhs = re.sub(r'\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]*)\}', r'\1', m.group(2))
        rhs = re.sub(r'\$\{[^}]*\}', '', rhs)
        for tok in rhs.split(","):
            tok = tok.strip()
            if re.fullmatch(r'[a-z][a-z0-9_]*', tok):
                offerable.add(tok)

# POSITIVE CONTROL ON THE SCANNER ITSELF. `reminders` is on a RECOMMENDED=
# line and on an _ask_source line, so a scanner that works finds it by two
# independent routes. If it is missing, the scanner is broken and every
# "absent" verdict below would be a false one -- investigate the control, not
# the subject.
if "reminders" not in offerable:
    cannot("the install.sh source scanner found no 'reminders'; it is on both "
           "a RECOMMENDED= line and an _ask_source line, so the scanner is "
           "blind and its other answers cannot be trusted")
if len(offerable) < 8:
    cannot("the install.sh source scanner found only %d sources; the picker "
           "offers ten or more, so this is a broken predicate and not a "
           "shrunken picker" % len(offerable))
print("  install.sh can enable %d FDA sources: %s"
      % (len(offerable), " ".join(sorted(offerable))))

# ── the declared map ──────────────────────────────────────────────────────
decl = [l for l in sh if l.startswith("OSTLER_FDA_SOURCE_ROWS=")]
if not decl:
    bad("OSTLER_FDA_SOURCE_ROWS is not declared in install.sh, so nothing "
        "records which Doctor row reports which extractor source")
    rows_map = {}
else:
    raw = decl[0].split("=", 1)[1].strip().strip('"')
    rows_map = {}
    for pair in raw.split():
        if ":" not in pair:
            bad("OSTLER_FDA_SOURCE_ROWS entry %r is not <source>:<row>" % pair)
            continue
        k, v = pair.split(":", 1)
        rows_map[k] = v
    ok("OSTLER_FDA_SOURCE_ROWS declares %d source-to-row pairs" % len(rows_map))

sentinel_decl = [l for l in sh if l.startswith("OSTLER_SENTINEL_SOURCES=")]
if not sentinel_decl:
    cannot("OSTLER_SENTINEL_SOURCES is not declared; there is nothing to "
           "compare the canonical rows against")
sentinel_sources = set(
    sentinel_decl[0].split("=", 1)[1].strip().strip('"').split())

# ── the shipped extractor's own vocabulary ────────────────────────────────
ex_src = open(extract, encoding="utf-8", errors="replace").read()
ns = {"frozenset": frozenset}
for node in ast.parse(ex_src).body:
    if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id in ("DEFAULT_SOURCES", "ALL_SOURCES")
            for t in node.targets):
        try:
            exec(compile(ast.Module([node], []), "<ex>", "exec"), ns)
        except Exception:
            pass
all_sources = ns.get("ALL_SOURCES")
if not all_sources:
    cannot("could not read ALL_SOURCES from %s; without the extractor's own "
           "vocabulary the left column cannot be checked against anything"
           % extract)
# CONTROL: a vocabulary that came back as a handful of names would let every
# membership test pass by accident.
if len(all_sources) < 8:
    cannot("ALL_SOURCES has only %d entries; that is a parse failure, not a "
           "small extractor" % len(all_sources))
print("  the shipped extractor recognises %d sources" % len(all_sources))

# ── the Doctor's row register ─────────────────────────────────────────────
wu_src = open(webui, encoding="utf-8", errors="replace").read()
wns = {}
for node in ast.parse(wu_src).body:
    if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id in ("_SOURCE_KINDS",
                                                 "_FDA_EXTRACT_KINDS")
            for t in node.targets):
        try:
            exec(compile(ast.Module([node], []), "<wu>", "exec"), wns)
        except Exception:
            pass
if "_SOURCE_KINDS" not in wns:
    cannot("could not read _SOURCE_KINDS from %s" % webui)
doctor_rows = set(wns["_SOURCE_KINDS"]) | set(wns.get("_FDA_EXTRACT_KINDS", {}))
print("  the Doctor table can print %d rows" % len(doctor_rows))

# ── the four assertions ───────────────────────────────────────────────────
missing = sorted(offerable - set(rows_map))
if missing:
    bad("install.sh can enable %s, and OSTLER_FDA_SOURCE_ROWS does not say "
        "which Doctor row reports %s. A source added to the picker and to "
        "nothing else is invisible on the panel."
        % (", ".join(missing), "them" if len(missing) > 1 else "it"))
else:
    ok("every one of the %d sources install.sh can enable maps to a Doctor row"
       % len(offerable))

stale = sorted(set(rows_map) - offerable)
if stale:
    bad("OSTLER_FDA_SOURCE_ROWS maps %s, which install.sh can no longer "
        "enable. A map with a dead left-hand name stops being a description "
        "of the product." % ", ".join(stale))
else:
    ok("the map carries no source the picker cannot offer")

unknown = sorted(set(rows_map) - set(all_sources))
if unknown:
    bad("OSTLER_FDA_SOURCE_ROWS names %s, which the shipped extractor does "
        "not recognise (extract_all.ALL_SOURCES). A typo here maps a row to "
        "nothing." % ", ".join(unknown))
else:
    ok("every mapped source name is one the shipped extractor recognises")

canonical = sorted(set(rows_map.values()))
# A ZERO DENOMINATOR READS AS SUCCESS, and it did here on the first run of
# this test against the tree that shipped the defect: with no map declared,
# "all 0 canonical rows are declared" and "every canonical row is printable"
# both printed PASS. Two green lines asserting nothing, beside the red that
# mattered. Refuse to grade a subset check over an empty subject.
if not canonical:
    bad("there are no canonical rows to check: OSTLER_FDA_SOURCE_ROWS is "
        "absent or empty, so the two subset checks below have no subject and "
        "are not being graded")
    print("  PART 1: %d pass, %d fail" % (PASS, FAIL))
    raise SystemExit(1)

unregistered = [r for r in canonical if r not in sentinel_sources]
if unregistered:
    bad("canonical row(s) %s are not in OSTLER_SENTINEL_SOURCES, so the "
        "declared writer vocabulary does not admit the sentinel that reports "
        "them" % ", ".join(unregistered))
else:
    ok("all %d canonical rows are declared in OSTLER_SENTINEL_SOURCES"
       % len(canonical))

unprintable = [r for r in canonical if r not in doctor_rows]
if unprintable:
    bad("canonical row(s) %s cannot be printed by the Doctor: absent from "
        "both _SOURCE_KINDS and _FDA_EXTRACT_KINDS in web_ui.py. This is the "
        "exact half of #1587 that a sentinel alone does not fix."
        % ", ".join(unprintable))
else:
    ok("every canonical row is in the Doctor's row register")

print("  PART 1: %d pass, %d fail" % (PASS, FAIL))
raise SystemExit(1 if FAIL else 0)
PY
_p1=$?
if [ "$_p1" -eq 2 ]; then exit 2; fi
if [ "$_p1" -ne 0 ]; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi

# ============================================================================
# PART 2 -- run the real writer, render the real panel, read the real cells
# ============================================================================
echo "PART 2: the panel a customer opens"

# Lift the recorders verbatim. The count helpers are lifted too, NOT stubbed:
# the number in the Items column is the thing under test, so a stub would be
# asserting the harness. Each function is taken from its `name() {` line to
# the first line that is exactly `}`.
python3 - "$SUBJECT" "${WORK}/recorders.sh" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8", errors="replace").read().split("\n")
names = ["_hydrate_payload_count", "_hydrate_payload_is_all_zero",
         "_hydrate_compute_change",
         "_hydrate_sentinel_record", "_hydrate_sentinel_record_no_data",
         "_hydrate_sentinel_record_error", "_hydrate_sentinel_record_cannot_run",
         "_hydrate_fda_decision",
         "_hydrate_fda_record_photos", "_hydrate_fda_record_reminders",
         "_hydrate_record_fda_extract"]
body = []
for n in names:
    try:
        s = next(i for i, l in enumerate(lines) if l.startswith(n + "()"))
    except StopIteration:
        print("CANNOT-RUN: install.sh has no %s()" % n, file=sys.stderr)
        raise SystemExit(2)
    try:
        e = next(i for i in range(s + 1, len(lines)) if lines[i] == "}")
    except StopIteration:
        print("CANNOT-RUN: no closing brace for %s()" % n, file=sys.stderr)
        raise SystemExit(2)
    chunk = lines[s:e + 1]
    # An extraction that stopped early looks exactly like a short function.
    # _hydrate_record_fda_extract embeds a python heredoc, so assert the
    # heredoc closed inside the slice rather than trusting the brace scan.
    if n == "_hydrate_record_fda_extract" and "FDASUMEOF" not in "\n".join(chunk[1:]):
        print("CANNOT-RUN: %s() extraction stopped before its heredoc closed; "
              "a column-1 '}' inside the embedded python truncated it" % n,
              file=sys.stderr)
        raise SystemExit(2)
    body.append("\n".join(chunk))
open(out, "w", encoding="utf-8").write("\n\n".join(body) + "\n")
PY
[ $? -eq 0 ] || cannot "could not extract the recorders from install.sh"
[ -s "${WORK}/recorders.sh" ] || cannot "the extracted recorders are empty"

# The renderer finds the sentinels through its own path helper, which reads
# OSTLER_DIR and appends state/hydrate. So the fixture is built at exactly
# that path rather than somewhere the test then tells it about: a harness that
# hands the reader a path it would never compute itself is testing the
# harness.
mkdir -p "${WORK}/state/hydrate"
WORK_SENT="${WORK}/state/hydrate"

# Drives the real writer over one synthetic summary. Only gui_step_record_rc
# is stubbed -- it belongs to the GUI progress emitter, not to the record, and
# install.sh itself stubs it to `:` when no GUI is driving.
_drive() {
    local summary_json="$1" d="$WORK_SENT"
    rm -rf "$d"; mkdir -p "$d"
    printf '%s' "$summary_json" > "${WORK}/extraction_summary.json"
    {
        printf '%s\n' 'set -uo pipefail'
        printf '_HYDRATE_SENTINEL_DIR=%q\n' "$d"
        printf '%s\n' 'gui_step_record_rc() { :; }'
        cat "${WORK}/recorders.sh"
        printf '_hydrate_record_fda_extract %q %q\n' \
            "${WORK}/extraction_summary.json" "$(command -v python3)"
    } > "${WORK}/run.sh"
    bash "${WORK}/run.sh" >/dev/null 2>&1
}
_render() {
    OSTLER_SENT_DIR="$WORK_SENT" python3 - "$WEBUI" <<'PY'
import ast, os, pathlib, sys, html, json, re

mod = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
ns = {"Path": pathlib.Path, "os": os, "html": html, "json": json}
tree = ast.parse(mod)
for node in tree.body:
    if isinstance(node, (ast.Assign, ast.AnnAssign)):
        try:
            exec(compile(ast.Module([node], []), "<c>", "exec"), ns)
        except Exception:
            pass
want = {"_source_activity_dir", "_read_source_activity", "_source_hydrate_dir",
        "_parse_source_sentinel", "read_source_status", "render_source_status"}
for node in tree.body:
    if isinstance(node, ast.FunctionDef) and node.name in want:
        exec(compile(ast.Module([node], []), "<f>", "exec"), ns)
absent = [w for w in want if w not in ns]
if absent:
    print("CANNOT-RUN: web_ui.py has no " + ", ".join(sorted(absent)),
          file=sys.stderr)
    raise SystemExit(2)

root = pathlib.Path(os.environ["OSTLER_SENT_DIR"]).parent.parent
os.environ["OSTLER_DIR"] = str(root)
os.environ.pop("OSTLER_HOME", None)
ns["os"].environ["OSTLER_DIR"] = str(root)
ns["os"].environ.pop("OSTLER_HOME", None)
page = ns["render_source_status"]()
cells = re.compile(
    r"<tr><td>(.*?)</td><td><span[^>]*>(.*?)</span></td>"
    r'<td style="text-align:right">(.*?)</td>')
for name, status, items in cells.findall(page):
    print("%s|%s|%s" % (name, status, items))
PY
}

# One scenario per state the extractor can report. Counts are invented for the
# fixture and are deliberately unlike each other so a row cannot pass by
# printing the wrong source's number.
SUMMARY_OK='{"sources":{"reminders":{"status":"ok","total_reminders":87,"pending":12,"completed":75,"lists":4},"photos":{"status":"ok","recognised_people":0,"photo_events":412,"faces_enabled":false},"imessage":{"status":"ok","people":9}}}'
SUMMARY_NOFDA='{"sources":{"reminders":{"status":"no_fda"},"photos":{"status":"no_fda"}}}'
SUMMARY_DISABLED='{"sources":{"reminders":{"status":"disabled_by_user"},"photos":{"status":"disabled_by_user"}}}'
SUMMARY_ZERO='{"sources":{"reminders":{"status":"ok","total_reminders":0,"pending":0,"completed":0},"photos":{"status":"ok","recognised_people":0,"photo_events":0}}}'
SUMMARY_NOTFOUND='{"sources":{"reminders":{"status":"not_found"},"photos":{"status":"not_found"}}}'
SUMMARY_WEIRD='{"sources":{"reminders":{"status":"quantum"},"photos":{"status":"quantum"}}}'

_cell() { printf '%s\n' "$2" | awk -F'|' -v s="$1" '$1==s {print $2"|"$3}'; }

# ── the consented, successful case: the row exists and carries the total ──
_drive "$SUMMARY_OK"
OUT_OK="$(_render)" || cannot "the renderer could not be driven"
[ -n "$OUT_OK" ] || cannot "the renderer produced no rows at all"

# POSITIVE CONTROL, same shape, same run: a source that was ALWAYS in the
# register. If imessage is missing the harness is broken, not the subject.
_c="$(_cell imessage "$OUT_OK")"
if [ -z "$_c" ]; then
    cannot "the control row 'imessage' is absent from the rendered panel; the "\
"harness is not rendering the real table and no absence below can be believed"
fi
ok "control: the always-registered 'imessage' row renders (${_c})"

_c="$(_cell reminders "$OUT_OK")"
case "$_c" in
    "read in|87") ok "a customer who ticked Reminders sees 'reminders / read in / 87'" ;;
    "")           bad "Reminders is ABSENT from the panel after a successful extract. This is #1587: not reported as broken, not reported at all." ;;
    *)            bad "the Reminders row reads '${_c}', expected 'read in|87' (total_reminders, not pending and not a list count)" ;;
esac

_c="$(_cell photos "$OUT_OK")"
case "$_c" in
    "read in|412") ok "Photos reads 'read in / 412' (photo_events, not the 0 recognised people)" ;;
    "")            bad "Photos is ABSENT from the panel after a successful extract" ;;
    *)             bad "the Photos row reads '${_c}', expected 'read in|412'" ;;
esac

# ── Full Disk Access ungranted: CANNOT-RUN, and never a zero ─────────────
_drive "$SUMMARY_NOFDA"
OUT_NOFDA="$(_render)"
_c="$(_cell reminders "$OUT_NOFDA")"
case "$_c" in
    "could not look|"*"mdash"*|"could not look|&mdash;")
        ok "with Full Disk Access ungranted Reminders reads 'could not look' with a BLANK count" ;;
    "")  bad "Reminders vanished from the panel when Full Disk Access was ungranted; an absent row reads as fine" ;;
    "could not look|0")
        bad "Reminders reads 'could not look' beside a count of 0. Nothing looked, so 0 is fabricated -- the defect class this week." ;;
    "nothing to read|"*)
        bad "an ungranted Full Disk Access rendered as 'nothing to read', which tells the customer their Reminders are empty when in fact nobody looked" ;;
    *)   bad "the ungranted-FDA Reminders row reads '${_c}', expected 'could not look' with a blank count" ;;
esac

# ── declined: no row, because a declined source is not a failure ─────────
_drive "$SUMMARY_DISABLED"
OUT_OFF="$(_render)"
_c="$(_cell reminders "$OUT_OFF")"
if [ -z "$_c" ]; then
    ok "a source the customer declined prints no row rather than an amber 'not run yet'"
else
    bad "a declined source rendered '${_c}'; the customer chose not to have it and an amber row invents a failure"
fi
# CONTROL for that absence: the always-registered rows are still there, so
# "no reminders row" is a decision and not a dead renderer.
_c="$(_cell imessage "$OUT_OFF")"
[ -n "$_c" ] && ok "control: the panel still renders its always-on rows in the declined case (imessage ${_c})" \
             || bad "control: the panel rendered nothing at all in the declined case"

# ── ran and genuinely found nothing: that IS a zero, and must print one ──
_drive "$SUMMARY_ZERO"
OUT_ZERO="$(_render)"
_c="$(_cell reminders "$OUT_ZERO")"
case "$_c" in
    "nothing to read|0") ok "an empty Reminders list reads 'nothing to read / 0' -- a measured zero still prints" ;;
    "")  bad "a Reminders extract that ran and found nothing produced no row" ;;
    *)   bad "the empty-Reminders row reads '${_c}', expected 'nothing to read|0'" ;;
esac

# ── app absent from this Mac ─────────────────────────────────────────────
_drive "$SUMMARY_NOTFOUND"
_c="$(_cell photos "$(_render)")"
case "$_c" in
    "nothing to read|"*) ok "a source whose store is not on this Mac reads 'nothing to read'" ;;
    "")  bad "a not-found source produced no row" ;;
    *)   bad "the not-found Photos row reads '${_c}'" ;;
esac

# ── a state the reader has never seen must surface, not be absorbed ──────
_drive "$SUMMARY_WEIRD"
_c="$(_cell reminders "$(_render)")"
case "$_c" in
    "could not look|"*) ok "an unrecognised extractor status surfaces as 'could not look', never as healthy" ;;
    "read in|"*)        bad "an unrecognised extractor status was absorbed into 'read in'" ;;
    "")                 bad "an unrecognised extractor status produced no row" ;;
    *)                  bad "an unrecognised extractor status rendered '${_c}'" ;;
esac

# ── the summary itself missing: CANNOT-RUN, not zero ─────────────────────
rm -rf "$WORK_SENT"; mkdir -p "$WORK_SENT"
rm -f "${WORK}/extraction_summary.json"
{
    printf '%s\n' 'set -uo pipefail'
    printf '_HYDRATE_SENTINEL_DIR=%q\n' "$WORK_SENT"
    printf '%s\n' 'gui_step_record_rc() { :; }'
    cat "${WORK}/recorders.sh"
    printf '_hydrate_record_fda_extract %q %q\n' \
        "${WORK}/extraction_summary.json" "$(command -v python3)"
} > "${WORK}/run.sh"
bash "${WORK}/run.sh" >/dev/null 2>&1
_c="$(_cell reminders "$(_render)")"
case "$_c" in
    "could not look|"*) ok "no extract summary on disk reads 'could not look', not a zero" ;;
    "")                 bad "no extract summary produced no row; the customer cannot tell 'never looked' from 'fine'" ;;
    *)                  bad "with no extract summary the Reminders row reads '${_c}'" ;;
esac

# ============================================================================
printf '\n  %d pass, %d fail\n' "$PASS" "$FAIL"
# A FAIL IS GRADED BEFORE THE FLOOR. The floor below exists to stop a run that
# asserted almost nothing reading as a pass; a run carrying explicit FAILs
# plainly did assert things, and reporting it as CANNOT-RUN would downgrade a
# measured defect into "could not tell". Measured on the first mutation run of
# this file, which reported seven FAILs and exited 2.
[ "$FAIL" -eq 0 ] || exit 1
_TOTAL=$((PASS + FAIL))
if [ "$_TOTAL" -lt 11 ]; then
    echo "CANNOT-RUN: only ${_TOTAL} assertions were reached; expected 11 or more" >&2
    exit 2
fi
echo "PASS: the Doctor source table covers the FDA extract family"
exit 0
