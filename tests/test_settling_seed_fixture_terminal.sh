#!/usr/bin/env bash
#
# test_settling_seed_fixture_terminal.sh
#
# PROOF ON THE SPARSE SEED FIXTURE. The walk's seed fixture
# (scripts/box_walk_probes/fixtures/preference_seed, the one that
# assistant_answers_grounded seeds) has no settling source of its own: it is
# two export files and zero plays. This test sizes the sources from that
# fixture, drives the REAL settling path over it, and asserts that every
# shard reaches a terminal state and that the bar's arithmetic reads
# done == total across every channel that has work.
#
# What runs for real:
#   - lib/settling_progress.sh (the writer every producer uses)
#   - vendor/email_source/bin/email-bundle-tick.sh (the emails producer, run
#     as a process, with only its pipeline replaced by a stub that reports the
#     fixture's thread count)
#   - the contacts zero-yield branch of install.sh's contract, as
#     settling_skip contacts no_contacts
#   - the probe setup_progress_advancing.sh, judging the final state
#
# What is NOT proven here: that the Hub's rendered bar shows 100%. CM044
# compiler/hydration.py:1087 clamps the displayed percentage to 1..99, so it
# cannot show 100 whatever the shards say. That is a blocker in the other repo
# (docs/setup_progress_terminal_map.md, B1). This test proves the shards.
#
# Usage: bash tests/test_settling_seed_fixture_terminal.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/lib/settling_progress.sh"
TICK="$REPO_ROOT/vendor/email_source/bin/email-bundle-tick.sh"
PROBE="$REPO_ROOT/scripts/box_walk_probes/probes/setup_progress_advancing.sh"
FIXTURE_EXPORTS="$REPO_ROOT/scripts/box_walk_probes/fixtures/preference_seed/preferences/exports"
WORKFLOW="$REPO_ROOT/.github/workflows/tests-unwired-sweep-mz.yml"

pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

printf '== test_settling_seed_fixture_terminal ==\n'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 0. Size the sources from the fixture, not from a number typed here ──────

if [ ! -d "$FIXTURE_EXPORTS" ]; then
    bad "seed fixture exports directory missing: $FIXTURE_EXPORTS"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi
N_EXPORTS="$(find "$FIXTURE_EXPORTS" -maxdepth 1 -type f | wc -l | tr -d ' ')"
printf '  fixture: %s export file(s) in %s\n' "$N_EXPORTS" "$FIXTURE_EXPORTS"
if [ "$N_EXPORTS" -lt 1 ]; then
    bad "seed fixture has no export files, so there is nothing to size a source from"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi

# A Mail store with one .emlx per fixture export: the emails denominator the
# real settling_source_total() will measure from disk.
HOME_T="$TMP/home"
mkdir -p "$HOME_T/Library/Mail/V10/fixture"
find "$FIXTURE_EXPORTS" -maxdepth 1 -type f | while IFS= read -r f; do
    : > "$HOME_T/Library/Mail/V10/fixture/$(basename "$f" | sed 's/\.[^.]*$//').emlx"
done

STATE="$TMP/state"
mkdir -p "$STATE" "$TMP/src"

# A stub for the email pipeline: it reports one thread per fixture export,
# none dispatched, seeded or failed (a full-window run with nothing pending).
STUB="$TMP/stub-python"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
cat <<'JSON'
{
  "threads_scanned": $N_EXPORTS,
  "threads_dispatched": 0,
  "threads_seeded": 0,
  "threads_failed": 0
}
JSON
exit 0
EOF
chmod +x "$STUB"

ENVV=(HOME="$HOME_T" OSTLER_STATE_DIR="$STATE" OSTLER_SETTLING_LIB="$LIB"
      OSTLER_PYTHON="$STUB" OSTLER_SOURCE_DIR="$TMP/src" OSTLER_MAIL_DIR="$HOME_T/Library/Mail"
      OSTLER_INGEST_LOCK="$TMP/lock.d" OSTLER_INGEST_SLOT=0 OSTLER_INTERACTIVE_TTL_SECS=0
      OSTLER_RESOURCE_GOVERNOR=0 OSTLER_INGEST_OFFPEAK_ONLY=0
      OSTLER_INTERACTIVE_MARKER="$TMP/no-marker" OSTLER_RESOURCE_TIER_LIB="$TMP/no-tier")

field() {  # field <shard-file> <key>
    python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(d.get(sys.argv[2])))' "$1" "$2" 2>/dev/null
}

# ── 1. The emails channel (install measures, the hourly tick finishes) ──────

env "${ENVV[@]}" bash -c '. "$0"; settling_report_measured emails 0' "$LIB" >/dev/null 2>&1
E="$STATE/settling_progress.d/emails.json"
if [ "$(field "$E" total)" = "$N_EXPORTS" ] && [ "$(field "$E" complete)" = "false" ]; then
    ok "install measures the emails source from the fixture: total=$N_EXPORTS, not yet terminal"
else
    bad "install did not measure emails from the fixture (shard: $(cat "$E" 2>/dev/null || echo missing))"
fi

env "${ENVV[@]}" bash "$TICK" >"$TMP/tick.out" 2>&1
tick_rc=$?
if [ "$tick_rc" -eq 0 ] && [ "$(field "$E" complete)" = "true" ] \
   && [ "$(field "$E" done)" = "$N_EXPORTS" ] && [ "$(field "$E" total)" = "$N_EXPORTS" ]; then
    ok "the real email tick settles emails to $N_EXPORTS/$N_EXPORTS, complete:true (rc=$tick_rc)"
else
    bad "the email tick did not settle emails (rc=$tick_rc, shard: $(cat "$E" 2>/dev/null || echo missing), tick: $(tr '\n' ' ' < "$TMP/tick.out" | cut -c1-300))"
fi

# ── 2. The contacts channel: the fixture carries no address book ────────────

env "${ENVV[@]}" bash -c '. "$0"; settling_skip contacts no_contacts' "$LIB" >/dev/null 2>&1
C="$STATE/settling_progress.d/contacts.json"
if [ "$(field "$C" complete)" = "true" ] && [ "$(field "$C" skip_reason)" = '"no_contacts"' ]; then
    ok "contacts with no source settles as a terminal skip with its reason"
else
    bad "contacts zero-yield path did not settle (shard: $(cat "$C" 2>/dev/null || echo missing))"
fi

# ── 3. Every shard terminal, and the bar's arithmetic reads done == total ───

if [ -d "$STATE/settling_progress.d" ]; then
    # Exit 0 only when every shard is terminal AND done == total over the
    # channels with work. The verdict is computed here, not read off a string.
    summary="$(python3 -I - "$STATE/settling_progress.d" <<'PY'
import glob, json, os, sys
d = sys.argv[1]
done_sum = total_sum = open_n = 0
for p in sorted(glob.glob(os.path.join(d, "*.json"))):
    r = json.load(open(p, encoding="utf-8"))
    done = int(r.get("done") or 0); total = int(r.get("total") or 0)
    term = bool(r.get("complete")) or bool(r.get("skip_reason")) \
        or (total > 0 and done >= total) or (total == 0 and not r.get("needs_source"))
    if not term:
        open_n += 1
    # The reader (CM044 settling_progress) aggregates only channels with work.
    if total > 0:
        done_sum += min(done, total); total_sum += total
ok = open_n == 0 and total_sum > 0 and done_sum == total_sum
print("open=%d done=%d total=%d pct=%s" % (open_n, done_sum, total_sum,
      round(done_sum / total_sum * 100) if total_sum else "n/a"))
sys.exit(0 if ok else 1)
PY
)"
    srx=$?
    printf '  shards: %s\n' "$summary"
    if [ "$srx" -eq 0 ]; then
        ok "every shard is terminal and the bar arithmetic reads done == total on the seed fixture"
    else
        bad "seed-fixture end state is not terminal / done != total ($summary)"
    fi
else
    bad "no settling shards were written at all"
fi

# ── 4. The walk's probe agrees, with no settle wait needed for terminal shards

OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$STATE/settling_progress.d" \
    OSTLER_SETTLING_MANIFEST="$REPO_ROOT/lib/settling_channels.json" bash "$PROBE" >"$TMP/probe.out" 2>&1
prc=$?
if [ "$prc" -eq 0 ] && /usr/bin/grep -q 'VERDICT: PASS' "$TMP/probe.out"; then
    ok "setup_progress_advancing PASSes the seed-fixture end state (rc=0)"
else
    bad "setup_progress_advancing did not PASS the seed-fixture end state (rc=$prc): $(tr '\n' ' ' < "$TMP/probe.out" | cut -c1-300)"
fi

if /usr/bin/grep -q 'test_settling_seed_fixture_terminal.sh' "$WORKFLOW"; then
    ok "test is wired into tests-unwired-sweep-mz.yml"
else
    bad "test is not invoked by any workflow (unwired)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
