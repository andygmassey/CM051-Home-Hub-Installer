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
PROBE="${PROBE_UNDER_TEST:-$REPO_ROOT/scripts/box_walk_probes/probes/setup_progress_advancing.sh}"
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

    MANIFEST="$TMP/settling_channels.json"
    printf '%s\n' '{"schema":1,"channels":["contacts","calendar","messages","emails"]}' > "$MANIFEST"
    export OSTLER_SETTLING_MANIFEST="$MANIFEST"
    export OSTLER_LAUNCHAGENTS_DIR="$TMP/no-launchagents"

    BAD="$TMP/probe-bad"
    mkshard "$BAD" contacts '{"key":"contacts","done":2398,"total":2443,"needs_source":false,"started_at":"2026-11-08T07:01:16+00:00","updated_at":"2026-11-08T07:01:16+00:00"}'
    mkshard "$BAD" emails '{"key":"emails","done":17080,"total":121262,"needs_source":false,"started_at":"2026-11-08T07:04:58+00:00","updated_at":"2026-11-08T07:04:58+00:00"}'
    mkshard "$BAD" calendar '{"key":"calendar","done":4138,"total":4138,"needs_source":false,"started_at":"2026-11-08T06:50:47+00:00","updated_at":"2026-11-11T04:00:03+00:00"}'
    mkshard "$BAD" notes '{"key":"notes","done":0,"total":0,"needs_source":true,"started_at":"2026-11-08T06:50:47+00:00","updated_at":"2026-11-08T06:50:47+00:00"}'

    OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$BAD/settling_progress.d" bash "$PROBE" >"$TMP/bad.out" 2>&1
    rc=$?
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'VERDICT: FAIL' "$TMP/bad.out" \
       && /usr/bin/grep -q 'emails' "$TMP/bad.out" && /usr/bin/grep -q 'contacts' "$TMP/bad.out" \
       && /usr/bin/grep -q 'notes.json|INFO|' "$TMP/bad.out" \
       && ! /usr/bin/grep -q 'notes.json|FAIL|' "$TMP/bad.out" \
       && /usr/bin/grep -q '3 of 3 settling source' "$TMP/bad.out"; then
        ok "probe FAILs on non-terminal emails, contacts and calendar (3 of 3 judged), and lists the waiting notes shard as INFO, not judged"
    else
        bad "probe did not FAIL on non-terminal shards or judged a non-manifest shard (rc=$rc): $(tr '\n' ' ' < "$TMP/bad.out")"
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
    mkshard "$GOOD" messages.imessage '{"key":"messages","shard":"imessage","done":10,"total":10,"needs_source":false,"skip_reason":"no_messages","complete":true}'
    OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$GOOD/settling_progress.d" bash "$PROBE" >"$TMP/good.out" 2>&1
    rc=$?
    if [[ "$rc" -eq 0 ]] && /usr/bin/grep -q 'VERDICT: PASS' "$TMP/good.out" \
       && /usr/bin/grep -q 'no_messages' "$TMP/good.out"; then
        ok "probe PASSes when every shard is complete, measured done, or skipped with a shown reason"
    else
        bad "probe did not PASS an all-terminal fixture (rc=$rc): $(tr '\n' ' ' < "$TMP/good.out")"
    fi

    # ── 3b. Manifest scoping and hourly-writer freshness (this PR) ───────────
    ago() {  # ago <seconds>: an ISO updated_at that many seconds in the past
        python3 -I -c 'import sys,datetime as d;print((d.datetime.now(d.timezone.utc)-d.timedelta(seconds=int(sys.argv[1]))).isoformat(timespec="seconds"))' "$1"
    }
    AGENTS="$TMP/agents"; mkdir -p "$AGENTS"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Label</key><string>com.creativemachines.ostler.email-ingest</string><key>StartInterval</key><integer>3600</integer></dict></plist>' \
        > "$AGENTS/com.creativemachines.ostler.email-ingest.plist"
    terminal_rest() {  # terminal contacts, calendar, messages shards so only emails decides
        mkshard "$1" contacts '{"key":"contacts","done":5,"total":5,"complete":true}'
        mkshard "$1" calendar '{"key":"calendar","done":5,"total":5,"complete":true}'
        mkshard "$1" messages.imessage '{"key":"messages","shard":"imessage","done":5,"total":5,"complete":true}'
        mkshard "$1" messages.whatsapp '{"key":"messages","shard":"whatsapp","done":5,"total":5,"complete":true}'
    }

    # (a) a notes 0/0 open shard and an emails.history shard are NOT judged.
    NOTES="$TMP/probe-notes"
    terminal_rest "$NOTES"
    mkshard "$NOTES" emails '{"key":"emails","done":4,"total":4,"complete":true}'
    mkshard "$NOTES" notes '{"key":"notes","done":0,"total":0,"needs_source":false}'
    mkshard "$NOTES" emails.history '{"key":"emails.history","done":3,"total":90,"needs_source":false}'
    OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$NOTES/settling_progress.d" bash "$PROBE" >"$TMP/notes.out" 2>&1
    rc=$?
    if [[ "$rc" -eq 0 ]] && /usr/bin/grep -q 'VERDICT: PASS' "$TMP/notes.out" \
       && /usr/bin/grep -q 'notes.json|INFO|' "$TMP/notes.out" && /usr/bin/grep -q 'emails.history.json|INFO|' "$TMP/notes.out"; then
        ok "a notes 0/0 shard and an emails.history shard are listed as INFO and do not fail the probe"
    else
        bad "probe judged a shard outside settling_channels.json (rc=$rc): $(tr '\n' ' ' < "$TMP/notes.out")"
    fi

    # (b) an hourly emails shard updated 10 minutes ago, no done delta in the window: PASS.
    FRESH="$TMP/probe-fresh"
    terminal_rest "$FRESH"
    mkshard "$FRESH" emails "{\"key\":\"emails\",\"done\":17441,\"total\":121893,\"needs_source\":false,\"updated_at\":\"$(ago 600)\"}"
    OSTLER_LAUNCHAGENTS_DIR="$AGENTS" OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$FRESH/settling_progress.d" bash "$PROBE" >"$TMP/fresh.out" 2>&1
    rc=$?
    if [[ "$rc" -eq 0 ]] && /usr/bin/grep -q 'emails.json|PASS|fresh: updated' "$TMP/fresh.out" \
       && /usr/bin/grep -q 'StartInterval=3600' "$TMP/fresh.out"; then
        ok "hourly emails shard updated 10 min ago with no delta in the window PASSes on freshness, StartInterval printed"
    else
        bad "fresh hourly emails shard did not PASS (rc=$rc): $(tr '\n' ' ' < "$TMP/fresh.out")"
    fi

    # (c) the same shard updated 3 h ago: FAIL "not advancing".
    STALE="$TMP/probe-stale"
    terminal_rest "$STALE"
    mkshard "$STALE" emails "{\"key\":\"emails\",\"done\":17441,\"total\":121893,\"needs_source\":false,\"updated_at\":\"$(ago 10800)\"}"
    OSTLER_LAUNCHAGENTS_DIR="$AGENTS" OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$STALE/settling_progress.d" bash "$PROBE" >"$TMP/stale.out" 2>&1
    rc=$?
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'emails.json|FAIL|not advancing: updated' "$TMP/stale.out"; then
        ok "hourly emails shard updated 3 h ago FAILs as not advancing"
    else
        bad "stale hourly emails shard did not FAIL (rc=$rc): $(tr '\n' ' ' < "$TMP/stale.out")"
    fi

    # (d) manifest absent is a FAIL (the #3453 wiring check), never a fallback.
    OSTLER_SETTLING_MANIFEST="$TMP/absent/settling_channels.json" OSTLER_STABILITY_INTERVAL_S=1 \
        OSTLER_SETTLING_DIR="$GOOD/settling_progress.d" bash "$PROBE" >"$TMP/nomanifest.out" 2>&1
    rc=$?
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'VERDICT: FAIL' "$TMP/nomanifest.out" && /usr/bin/grep -q 'settling_channels.json is absent' "$TMP/nomanifest.out"; then
        ok "absent settling_channels.json FAILs the probe instead of falling back"
    else
        bad "absent manifest did not FAIL (rc=$rc): $(tr '\n' ' ' < "$TMP/nomanifest.out")"
    fi

    # (e) done going backwards on an otherwise fresh hourly shard is FAIL.
    BACK="$TMP/probe-back"
    terminal_rest "$BACK"
    mkshard "$BACK" emails "{\"key\":\"emails\",\"done\":9000,\"total\":121893,\"updated_at\":\"$(ago 60)\"}"
    ( sleep 1; printf '%s\n' "{\"key\":\"emails\",\"done\":8000,\"total\":121893,\"updated_at\":\"$(ago 1)\"}" > "$BACK/settling_progress.d/emails.json" ) &
    OSTLER_LAUNCHAGENTS_DIR="$AGENTS" OSTLER_STABILITY_INTERVAL_S=3 OSTLER_SETTLING_DIR="$BACK/settling_progress.d" bash "$PROBE" >"$TMP/back.out" 2>&1
    rc=$?
    wait
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'done went backwards' "$TMP/back.out"; then
        ok "a fresh hourly shard whose done decreased FAILs"
    else
        bad "decreasing done on an hourly shard did not FAIL (rc=$rc): $(tr '\n' ' ' < "$TMP/back.out")"
    fi


    # (f) updated_at is the claim, never file mtime: a 1.5x-tick-old updated_at PASSes
    #     and a >2x updated_at FAILs even though the file itself was just written.
    F15="$TMP/probe-15x"
    terminal_rest "$F15"
    mkshard "$F15" emails "{\"key\":\"emails\",\"done\":17441,\"total\":121893,\"complete\":false,\"updated_at\":\"$(ago 5400)\"}"
    OSTLER_LAUNCHAGENTS_DIR="$AGENTS" OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$F15/settling_progress.d" bash "$PROBE" >"$TMP/f15.out" 2>&1
    rc15=$?
    OLD="$TMP/probe-old-updated-at"
    terminal_rest "$OLD"
    mkshard "$OLD" emails "{\"key\":\"emails\",\"done\":17441,\"total\":121893,\"complete\":false,\"updated_at\":\"$(ago 7500)\"}"
    touch "$OLD/settling_progress.d/emails.json"
    OSTLER_LAUNCHAGENTS_DIR="$AGENTS" OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$OLD/settling_progress.d" bash "$PROBE" >"$TMP/old.out" 2>&1
    rcold=$?
    if [[ "$rc15" -eq 0 ]] && /usr/bin/grep -q 'emails.json|PASS|fresh' "$TMP/f15.out" \
       && [[ "$rcold" -eq 1 ]] && /usr/bin/grep -q 'emails.json|FAIL|not advancing: updated' "$TMP/old.out"; then
        ok "freshness reads updated_at: 1.5x tick PASSes; >2x tick with complete=false FAILs although the file mtime is now"
    else
        bad "updated_at freshness wrong (1.5x rc=$rc15, >2x rc=$rcold): $(tr '\n' ' ' < "$TMP/f15.out") // $(tr '\n' ' ' < "$TMP/old.out")"
    fi

    # (g) a done==total never-complete notes shard (the Evernote writer's shape) is not judged.
    NDT="$TMP/probe-notes-dt"
    terminal_rest "$NDT"
    mkshard "$NDT" emails '{"key":"emails","done":4,"total":4,"complete":true}'
    mkshard "$NDT" notes '{"key":"notes","done":37,"total":37,"needs_source":false,"complete":false}'
    OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$NDT/settling_progress.d" bash "$PROBE" >"$TMP/ndt.out" 2>&1
    rc=$?
    if [[ "$rc" -eq 0 ]] && /usr/bin/grep -q 'notes.json|INFO|' "$TMP/ndt.out" && ! /usr/bin/grep -q 'notes.json|FAIL|' "$TMP/ndt.out"; then
        ok "a done==total, never-complete notes shard is INFO and does not change the verdict"
    else
        bad "done==total notes shard affected the verdict (rc=$rc): $(tr '\n' ' ' < "$TMP/ndt.out")"
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
