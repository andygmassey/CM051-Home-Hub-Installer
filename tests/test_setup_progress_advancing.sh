#!/usr/bin/env bash
#
# test_setup_progress_advancing.sh
#
# The Hub's "Setting up" percentage is done/total summed over the settling
# shards in ~/.ostler/state/settling_progress.d/. A shard that never reaches a
# terminal state holds the whole bar below 100% forever. On Mini16 (2026-11-11)
# it sat at 71%: emails 17080/121262 and contacts 2398/2443 had not been
# written since 2026-11-08, and whatsapp was 41205/42305.
#
# A terminal shard is one of:
#   complete:true               the writer finished this source (done == total)
#   skip_reason:"<text>"        the source yielded nothing by design or is
#                               unavailable; the reason is shown, not hidden
#   total>0 and done>=total     all the work it measured is done
#   total==0 and not needs_source   nothing to measure, nothing queued
#
# Usage: bash tests/test_setup_progress_advancing.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/lib/settling_progress.sh"
INSTALL="$REPO_ROOT/install.sh"
PROBE="$REPO_ROOT/scripts/box_walk_probes/probes/setup_progress_advancing.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/tests-unwired-sweep-mz.yml"

pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

printf '== test_setup_progress_advancing ==\n'

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── 1. The writer can mark a shard terminal ──────────────────────────────────

shard_field() {  # shard_field <file> <field>
    python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(d.get(sys.argv[2])))' "$1" "$2" 2>/dev/null
}

S1="$TMP/complete"
OSTLER_STATE_DIR="$S1" bash -c '. "$0"; settling_report contacts 2398 2443' "$LIB" >/dev/null 2>&1
OSTLER_STATE_DIR="$S1" bash -c '. "$0"; settling_complete contacts' "$LIB" >/dev/null 2>&1
SH1="$S1/settling_progress.d/contacts.json"
if [[ "$(shard_field "$SH1" complete)" == "true" ]] \
   && [[ "$(shard_field "$SH1" done)" == "$(shard_field "$SH1" total)" ]] \
   && [[ "$(shard_field "$SH1" done)" == "2443" ]]; then
    ok "settling_complete sets complete:true and done==total (2443/2443)"
else
    bad "settling_complete did not make a 2398/2443 shard terminal (shard: $(cat "$SH1" 2>/dev/null || echo missing))"
fi

S2="$TMP/skip"
OSTLER_STATE_DIR="$S2" bash -c '. "$0"; settling_skip contacts "no contacts found in Contacts"' "$LIB" >/dev/null 2>&1
SH2="$S2/settling_progress.d/contacts.json"
if [[ "$(shard_field "$SH2" complete)" == "true" ]] \
   && [[ "$(shard_field "$SH2" skip_reason)" == '"no contacts found in Contacts"' ]] \
   && [[ "$(shard_field "$SH2" needs_source)" == "false" ]]; then
    ok "settling_skip sets complete:true, carries the reason, clears needs_source"
else
    bad "settling_skip did not write a terminal skip with a reason (shard: $(cat "$SH2" 2>/dev/null || echo missing))"
fi

# A terminal write must never walk the bar backwards: done stays monotonic.
S3="$TMP/mono"
OSTLER_STATE_DIR="$S3" bash -c '. "$0"; settling_report emails 500 900' "$LIB" >/dev/null 2>&1
OSTLER_STATE_DIR="$S3" bash -c '. "$0"; settling_complete emails' "$LIB" >/dev/null 2>&1
SH3="$S3/settling_progress.d/emails.json"
if [[ "$(shard_field "$SH3" done)" == "900" ]] && [[ "$(shard_field "$SH3" total)" == "900" ]]; then
    ok "settling_complete on a 500/900 shard reads 900/900 (done monotonic, total kept)"
else
    bad "settling_complete did not complete the emails shard to its measured total"
fi

# ── 2. install.sh uses the terminal states where a channel is finished ──────

if /usr/bin/grep -q 'settling_skip contacts ' "$INSTALL"; then
    ok "install.sh marks a zero-yield contacts pass terminal with a reason"
else
    bad "install.sh still leaves a zero-yield contacts pass waiting on a source (needs_source, never terminal)"
fi

if /usr/bin/grep -q 'settling_complete contacts' "$INSTALL"; then
    ok "install.sh marks the finished contacts pass complete"
else
    bad "install.sh never marks the finished contacts pass complete"
fi

# ── 3. The probe: FAIL on any non-terminal shard, PASS only when all terminal

if [[ ! -f "$PROBE" ]]; then
    bad "probe missing: scripts/box_walk_probes/probes/setup_progress_advancing.sh"
else
    mkshard() {  # mkshard <dir> <name> <json>
        mkdir -p "$1/settling_progress.d"
        printf '%s\n' "$3" > "$1/settling_progress.d/$2.json"
    }

    BAD="$TMP/probe-bad"
    mkshard "$BAD" contacts '{"key":"contacts","done":2398,"total":2443,"needs_source":false,"started_at":"2026-11-08T07:01:16+00:00","updated_at":"2026-11-08T07:01:16+00:00"}'
    mkshard "$BAD" emails '{"key":"emails","done":17080,"total":121262,"needs_source":false,"started_at":"2026-11-08T07:04:58+00:00","updated_at":"2026-11-08T07:04:58+00:00"}'
    mkshard "$BAD" calendar '{"key":"calendar","done":4138,"total":4138,"needs_source":false,"started_at":"2026-11-08T06:50:47+00:00","updated_at":"2026-11-11T04:00:03+00:00"}'
    mkshard "$BAD" notes '{"key":"notes","done":0,"total":0,"needs_source":true,"started_at":"2026-11-08T06:50:47+00:00","updated_at":"2026-11-08T06:50:47+00:00"}'

    OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$BAD/settling_progress.d" bash "$PROBE" >"$TMP/bad.out" 2>&1
    rc=$?
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'VERDICT: FAIL' "$TMP/bad.out" \
       && /usr/bin/grep -q 'emails' "$TMP/bad.out" && /usr/bin/grep -q 'contacts' "$TMP/bad.out" \
       && /usr/bin/grep -q 'notes' "$TMP/bad.out"; then
        ok "probe FAILs on a non-terminal emails, contacts and waiting notes shard, naming each"
    else
        bad "probe did not FAIL on non-terminal shards (rc=$rc): $(tr '\n' ' ' < "$TMP/bad.out")"
    fi

    # Advancing: emails moves during the settle window (a live writer), contacts
    # does not. The probe must PASS emails and FAIL only contacts.
    ADV="$TMP/probe-advancing"
    mkshard "$ADV" contacts '{"key":"contacts","done":2398,"total":2443,"needs_source":false}'
    mkshard "$ADV" emails '{"key":"emails","done":17080,"total":121262,"needs_source":false}'
    ( sleep 2; printf '%s\n' '{"key":"emails","done":17500,"total":121262,"needs_source":false}' > "$ADV/settling_progress.d/emails.json" ) &
    OSTLER_STABILITY_INTERVAL_S=4 OSTLER_SETTLING_DIR="$ADV/settling_progress.d" bash "$PROBE" >"$TMP/adv.out" 2>&1
    rc=$?
    wait
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'emails.json|PASS|advancing: done 17080 -> 17500' "$TMP/adv.out" \
       && /usr/bin/grep -q '1 of 2 settling source' "$TMP/adv.out" && /usr/bin/grep -q 'contacts' "$TMP/adv.out"; then
        ok "probe PASSes an advancing emails shard and FAILs only the stalled contacts shard"
    else
        bad "probe did not separate advancing from stalled (rc=$rc): $(tr '\n' ' ' < "$TMP/adv.out")"
    fi

    GOOD="$TMP/probe-good"
    mkshard "$GOOD" contacts '{"key":"contacts","done":2443,"total":2443,"needs_source":false,"complete":true,"started_at":"2026-11-08T07:01:16+00:00","updated_at":"2026-11-08T07:01:16+00:00"}'
    mkshard "$GOOD" emails '{"key":"emails","done":121262,"total":121262,"needs_source":false,"complete":true,"started_at":"2026-11-08T07:04:58+00:00","updated_at":"2026-11-08T07:04:58+00:00"}'
    mkshard "$GOOD" calendar '{"key":"calendar","done":4138,"total":4138,"needs_source":false,"complete":true,"started_at":"2026-11-08T06:50:47+00:00","updated_at":"2026-11-11T04:00:03+00:00"}'
    mkshard "$GOOD" notes '{"key":"notes","done":0,"total":0,"needs_source":false,"complete":true,"skip_reason":"no Notes data on this Mac","started_at":"2026-11-08T06:50:47+00:00","updated_at":"2026-11-08T06:50:47+00:00"}'
    OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$GOOD/settling_progress.d" bash "$PROBE" >"$TMP/good.out" 2>&1
    rc=$?
    if [[ "$rc" -eq 0 ]] && /usr/bin/grep -q 'VERDICT: PASS' "$TMP/good.out" \
       && /usr/bin/grep -q 'no Notes data' "$TMP/good.out"; then
        ok "probe PASSes when every shard is complete, measured done, or skipped with a shown reason"
    else
        bad "probe did not PASS an all-terminal fixture (rc=$rc): $(tr '\n' ' ' < "$TMP/good.out")"
    fi

    OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$TMP/no-such-dir" bash "$PROBE" >"$TMP/none.out" 2>&1
    rc=$?
    if [[ "$rc" -eq 78 ]]; then
        ok "probe reports CANNOT-RUN (78) when no settling directory exists, not PASS"
    else
        bad "probe did not refuse a missing settling directory (rc=$rc)"
    fi

    bash "$PROBE" --self-test >"$TMP/self.out" 2>&1
    rc=$?
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'VERDICT: FAIL' "$TMP/self.out"; then
        ok "probe self-test drives a known-bad fixture to FAIL"
    else
        bad "probe self-test did not demonstrate a FAIL (rc=$rc)"
    fi
fi

# ── 4. Wired into an existing CI workflow ────────────────────────────────────

if /usr/bin/grep -q 'tests/test_setup_progress_advancing.sh' "$WORKFLOW"; then
    ok "test is wired into tests-unwired-sweep-mz.yml"
else
    bad "test is not invoked by any workflow (unwired)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
