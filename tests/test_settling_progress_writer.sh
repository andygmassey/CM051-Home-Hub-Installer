#!/usr/bin/env bash
#
# test_settling_progress_writer.sh
#
# Proves the `contacts` and `emails` settling channels actually reach the
# customer's wiki homepage.
#
# WHY THIS EXISTS
# ---------------
# The settling-progress feature shipped once as a flawless Python writer with
# 17 tests, an acceptance gate, and ZERO production callers. Everything was
# green and the panel stayed blank. A writer nobody calls is indistinguishable
# from one that was never written.
#
# `contacts` (CM041 contact_syncer) and `emails` (CM021 pwg-email-ingest) can
# NEVER call that Python writer: install.sh copies contact_syncer,
# meeting_syncer and identity_resolver into PIPELINE_DIR and never ostler_fda,
# so the import raises at runtime on a customer's Mac. lib/settling_progress.sh
# IS their writer.
#
# So this test asserts the three things that each independently reduce the
# feature to nothing:
#   1. the writer emits the exact JSON contract CM044's reader consumes;
#   2. install.sh actually CALLS it, on every branch including the skips;
#   3. the .app build BUNDLES it -- an unbundled lib means install.sh silently
#      no-ops and both channels ship permanently blank.
#
# Usage: bash tests/test_settling_progress_writer.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/lib/settling_progress.sh"
INSTALL="$REPO_ROOT/install.sh"
PROJECT_YML="$REPO_ROOT/gui/project.yml"

pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

printf '== test_settling_progress_writer ==\n'
[[ -f "$LIB" ]] || { echo "lib not found: $LIB" >&2; exit 3; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

bash -n "$LIB" && ok "library parses" || bad "library has a syntax error"

# ── 1. The JSON contract ─────────────────────────────────────────────────────
# Field names are shared with CM044/compiler/hydration.py::_read_progress_shards
# and HR015/ostler_fda/settling_progress.py. A rename on any side empties the
# panel silently, so they are asserted literally.

run_writer() {  # run_writer <state_dir> <args...>
    local dir="$1"; shift
    OSTLER_STATE_DIR="$dir" bash -c '. "$0"; settling_report "$@"' "$LIB" "$@"
}

S1="$TMP/s1"
run_writer "$S1" contacts 900 1200 >/dev/null 2>&1
SHARD="$S1/settling_progress.d/contacts.json"
if [[ -f "$SHARD" ]]; then
    ok "writes <channel>.json into settling_progress.d/"
else
    bad "no shard written at $SHARD"
fi

if [[ -f "$SHARD" ]] && python3 - "$SHARD" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
required = {"key", "done", "total", "needs_source", "started_at", "updated_at"}
missing = required - set(d)
assert not missing, f"missing fields: {sorted(missing)}"
assert d["key"] == "contacts", d["key"]
assert d["done"] == 900 and d["total"] == 1200, d
assert isinstance(d["needs_source"], bool), "needs_source must be a JSON bool"
PY
then ok "payload carries the exact six-field contract, correct types"
else bad "payload does not match the CM044 reader contract"
fi

# ── 2. started_at is preserved (it anchors CM044's ETA) ──────────────────────

FIRST="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["started_at"])' "$SHARD")"
sleep 1
run_writer "$S1" contacts 1000 1200 >/dev/null 2>&1
SECOND="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["started_at"])' "$SHARD")"
UPDATED="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["updated_at"])' "$SHARD")"
if [[ "$FIRST" == "$SECOND" ]]; then
    ok "started_at preserved across writes (ETA anchor holds)"
else
    bad "started_at was rewritten ($FIRST -> $SECOND); the ETA resets forever"
fi
if [[ "$UPDATED" != "$FIRST" ]]; then
    ok "updated_at advances (A9 can detect a stalled producer)"
else
    bad "updated_at did not advance"
fi

# ── 3. Unknown channels are refused, but never fatally ───────────────────────
# `email` singular and `meetings` are the near-misses; CM044 renders an unknown
# key as generic copy, so a typo is invisible in production.

for badch in email meetings "" bogus; do
    if run_writer "$TMP/s2" "$badch" 1 1 >/dev/null 2>&1; then
        rc=0
    else
        rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
        bad "unknown channel '${badch:-<empty>}' returned $rc; must never fail the install"
    fi
    if [[ -e "$TMP/s2/settling_progress.d/${badch}.json" ]]; then
        bad "unknown channel '${badch:-<empty>}' wrote a shard"
    fi
done
ok "unknown channels refused, no shard written, exit status still 0"

for goodch in contacts calendar messages emails notes; do
    run_writer "$TMP/s3" "$goodch" 1 2 >/dev/null 2>&1
    [[ -f "$TMP/s3/settling_progress.d/${goodch}.json" ]] \
        || bad "valid channel '$goodch' was rejected"
done
ok "all five valid channels accepted"

# ── 4. needs_source + sharding ───────────────────────────────────────────────

run_writer "$TMP/s4" notes 0 0 true >/dev/null 2>&1
if python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d["needs_source"] is True else 1)' \
   "$TMP/s4/settling_progress.d/notes.json"; then
    ok "needs_source=true survives as a JSON bool"
else
    bad "needs_source did not round-trip as true"
fi

run_writer "$TMP/s5" messages 3 9 false sms >/dev/null 2>&1
if [[ -f "$TMP/s5/settling_progress.d/messages.sms.json" ]]; then
    ok "shard tag produces <channel>.<shard>.json"
else
    bad "shard tag did not produce a sharded filename"
fi

# ── 5. Atomicity: no temp detritus, reader never sees a partial file ─────────

leftovers="$(find "$S1/settling_progress.d" -name '.settling.*' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$leftovers" == "0" ]]; then
    ok "atomic write leaves no temp files behind"
else
    bad "$leftovers temp file(s) left in the shard dir"
fi

# ── 6. A read-only state dir must not fail the install ───────────────────────

RO="$TMP/readonly"; mkdir -p "$RO"; chmod 500 "$RO"
if run_writer "$RO" contacts 1 1 >/dev/null 2>&1; then
    ok "unwritable state dir still exits 0 (install unaffected)"
else
    bad "unwritable state dir returned non-zero; would abort a customer install"
fi
chmod 700 "$RO"

# ── 7. install.sh sources it AND calls it ────────────────────────────────────

if grep -q 'lib/settling_progress.sh' "$INSTALL"; then
    ok "install.sh resolves lib/settling_progress.sh"
else
    bad "install.sh never sources the settling writer"
fi

if grep -q 'settling_report() { :; }' "$INSTALL"; then
    ok "install.sh defines a no-op fallback (call sites stay unguarded)"
else
    bad "no no-op fallback; an absent lib would crash the install under set -u"
fi

# The ships-dark check: both channels must have at least one real call site.
for ch in contacts emails; do
    n="$(grep -c "settling_report ${ch}" "$INSTALL" || true)"
    if [[ "${n:-0}" -ge 1 ]]; then
        ok "install.sh reports the '$ch' channel ($n call site(s))"
    else
        bad "install.sh never calls settling_report for '$ch' -- ships blank"
    fi
done

# Every call site must name a channel CM044 knows. A typo here renders as
# generic "Another part of your history" copy and nobody notices.
#
# 🔴 THE OLD PREDICATE WAS WRONG IN BOTH DIRECTIONS, and each was proved with
# a one-line fixture rather than argued:
#
#   grep -oE 'settling_report[[:space:]]+[a-z_]+'
#
#     "settling_report_measured contacts …"  ->  []                 MISSED
#     "settling_report contacts 0 0 true"    ->  [… contacts]       ok
#     "# settling_report has only two …"     ->  [… has]            INVENTED
#
#   INVENTS: it reads any line, so PROSE ABOUT settling_report becomes a call
#   site. That is not hypothetical -- it fired on CM051 #1457, where two lines
#   of a comment written to explain a review finding were reported as channels
#   "has" and "is". A gate that goes red when somebody DOCUMENTS the thing it
#   watches punishes exactly the behaviour this estate wants.
#
#   MISSES: `settling_report_measured` cannot match `settling_report` followed
#   by whitespace, so the _measured variant's channels were never validated at
#   all. Today both of its channels happen to appear in plain calls too, so the
#   set came out right by luck. A channel reported ONLY via _measured would
#   have shipped unchecked.
#
# Anchored so the name must be INVOKED, not mentioned, and both variants
# matched.
#
# ⚠️ MY FIRST ANCHOR WAS ALSO TOO LOOSE AND THE CONTROL BELOW CAUGHT IT. I
# allowed a preceding SPACE as command position, so the prose line
#
#     A third state in settling_report is the honest one
#
# yielded a channel "is" -- the same defect, from a sentence with no `#` in it
# at all. Dropping comment lines is not sufficient: prose is not always a
# comment. Command position means start-of-line, or after `;` `|` `&` `(`,
# or after `do`/`then`.
#
# ⚠️ AND MY SECOND ANCHOR WAS TOO TIGHT, caught by the same fixture set going
# the other way: `if true; then settling_report notes 0 0 true; fi` yielded
# NOTHING, because I required the delimiter to sit directly against the call.
# Over-broad first, then under-broad -- the fixtures found both, which is the
# entire argument for writing must-match and must-miss at the same time.
_settling_call_channels() {   # $1 = file
    grep -oE '^[[:space:]]*(.*([;|&(]|[[:space:]](do|then))[[:space:]]*)?settling_report(_measured)?[[:space:]]+[a-z_]+' "$1" \
        | grep -v '^[[:space:]]*#' \
        | sed -E 's/.*settling_report(_measured)?[[:space:]]+//' | sort -u
}

# CONTROLS BEFORE THE VERDICT. One must-match per variant and one MUST-MISS,
# because a predicate checked only against what it should find is how the old
# one passed review.
# Six lines: four that MUST be found (both call forms, plus a call after
# `then` and one after `do`) and two that MUST NOT be (a comment, and a plain
# prose sentence with no `#` in it). Both of my own anchors failed this set --
# the first invented a channel from the prose line, the second missed the
# `then` line -- which is why all six live here rather than in my shell history.
_ctl="$(mktemp)"; trap 'rm -f "$_ctl"' EXIT
{
    printf 'settling_report_measured contacts "$X" false\n'
    printf 'settling_report emails 0 0 true\n'
    printf 'if true; then settling_report notes 0 0 true; fi\n'
    printf 'for x in a; do settling_report messages 0 0 true; done\n'
    printf '# settling_report has only two states\n'
    printf 'A third state in settling_report is the honest one\n'
} > "$_ctl"
_got="$(_settling_call_channels "$_ctl" | tr '\n' ' ')"
_want="contacts emails messages notes "
if [[ "$_got" == "$_want" ]]; then
    ok "CONTROL: predicate finds all 4 call forms and ignores comment + prose (got: ${_got%% })"
else
    bad "CONTROL FAILED: expected '${_want}', got '${_got}'.
        The channel verdict below would be meaningless -- the predicate either
        misses call sites or invents them from text about them."
fi

strays="$(_settling_call_channels "$INSTALL" \
          | grep -vE '^(contacts|calendar|messages|emails|notes)$' || true)"
if [[ -z "$strays" ]]; then
    ok "every call site names a valid channel"
else
    bad "call sites use unknown channels: $(echo "$strays" | tr '\n' ' ')"
fi

# ── 8. The bundle. Unbundled == silently blank on every customer Mac. ────────

if grep -q 'lib/settling_progress.sh' "$PROJECT_YML"; then
    ok "gui/project.yml copies the lib into Contents/Resources/lib/"
else
    bad "gui/project.yml does NOT bundle it -- install.sh would no-op silently"
fi

if grep -q 'chmod 755.*settling_progress.sh' "$PROJECT_YML"; then
    ok "bundled lib is made executable"
else
    bad "bundled lib is not chmod 755"
fi

# release.sh ships the whole lib/ directory; assert that stays true rather
# than assuming, since a switch to an explicit file list would drop this.
if grep -qE '^[[:space:]]*"lib"' "$REPO_ROOT/release.sh"; then
    ok "release.sh tarball ships the whole lib/ directory"
else
    bad "release.sh no longer ships lib/ wholesale; add settling_progress.sh explicitly"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
