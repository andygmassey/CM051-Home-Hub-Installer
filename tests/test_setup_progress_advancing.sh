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

# ── 3. The probe: manifest scope, per-channel writer cadence, CANNOT-RUN ─────

if [[ ! -f "$PROBE" ]]; then
    bad "probe missing: scripts/box_walk_probes/probes/setup_progress_advancing.sh"
else
    mkshard() {  # mkshard <dir> <name> <json>
        mkdir -p "$1/settling_progress.d"
        printf '%s\n' "$3" > "$1/settling_progress.d/$2.json"
        # The installed channel set (#3426), so these fixtures model a box where
        # install.sh placed it. The no-manifest case below removes it.
        cp "$REPO_ROOT/lib/settling_channels.json" "$1/settling_channels.json"
    }
    ago() {  # ago <seconds>: an ISO updated_at that many seconds in the past
        python3 -I -c 'import sys,datetime as d;print((d.datetime.now(d.timezone.utc)-d.timedelta(seconds=int(sys.argv[1]))).isoformat(timespec="seconds"))' "$1"
    }
    mkplist() {  # mkplist <dir> <label> <StartInterval>
        mkdir -p "$1"
        printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Label</key><string>%s</string><key>StartInterval</key><integer>%s</integer></dict></plist>\n' "$2" "$3" > "$1/$2.plist"
    }
    EMAIL_LABEL=com.creativemachines.ostler.email-ingest
    FDA_LABEL=com.ostler.fda-rerun
    MANIFEST="$TMP/settling_channels.json"
    printf '%s\n' '{"schema":1,"channels":["contacts","calendar","messages","emails"]}' > "$MANIFEST"
    export OSTLER_SETTLING_MANIFEST="$MANIFEST"
    export OSTLER_STABILITY_INTERVAL_S=1
    AGENTS="$TMP/agents"            # email 3600 s, fda-rerun 3600 s
    mkplist "$AGENTS" "$EMAIL_LABEL" 3600
    mkplist "$AGENTS" "$FDA_LABEL" 3600
    export OSTLER_LAUNCHAGENTS_DIR="$AGENTS"
    probe() {  # probe <fixture-dir> <out-file> [launchagents-dir]
        OSTLER_LAUNCHAGENTS_DIR="${3:-$AGENTS}" OSTLER_SETTLING_DIR="$1/settling_progress.d" bash "$PROBE" >"$2" 2>&1
    }
    terminal_rest() {  # terminal shards for every channel named in "$2..", in dir $1
        local d="$1"; shift
        local c
        for c in "$@"; do
            case "$c" in
                messages) mkshard "$d" messages.imessage '{"key":"messages","shard":"imessage","done":5,"total":5,"complete":true}'
                          mkshard "$d" messages.whatsapp '{"key":"messages","shard":"whatsapp","done":5,"total":5,"complete":true}' ;;
                *) mkshard "$d" "$c" "{\"key\":\"$c\",\"done\":5,\"total\":5,\"complete\":true}" ;;
            esac
        done
    }

    # (1) non-terminal emails and calendar with an old updated_at FAIL; an open
    #     contacts shard is install-only (no job can complete it), so it FAILs too.
    BAD="$TMP/probe-bad"
    mkshard "$BAD" contacts '{"key":"contacts","done":2398,"total":2443,"needs_source":false,"updated_at":"2026-11-08T07:01:16+00:00"}'
    mkshard "$BAD" emails '{"key":"emails","done":17080,"total":121262,"needs_source":false,"updated_at":"2026-11-08T07:04:58+00:00"}'
    mkshard "$BAD" calendar '{"key":"calendar","done":4138,"total":4138,"needs_source":false,"updated_at":"2026-11-11T04:00:03+00:00"}'
    mkshard "$BAD" notes '{"key":"notes","done":0,"total":0,"needs_source":true}'
    probe "$BAD" "$TMP/bad.out"; rc=$?
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'VERDICT: FAIL' "$TMP/bad.out" \
       && /usr/bin/grep -q 'emails.json|FAIL|not advancing' "$TMP/bad.out" \
       && /usr/bin/grep -q 'calendar.json|FAIL|not advancing' "$TMP/bad.out" \
       && /usr/bin/grep -q 'contacts.json|FAIL|open with no writer that can complete it' "$TMP/bad.out" \
       && /usr/bin/grep -q 'notes.json|INFO|' "$TMP/bad.out" && ! /usr/bin/grep -q 'notes.json|FAIL|' "$TMP/bad.out" \
       && /usr/bin/grep -q '3 of 3 settling source' "$TMP/bad.out"; then
        ok "stale emails and calendar FAIL, open install-only contacts FAILs (3 of 3 judged), notes is INFO"
    else
        bad "stale shards not judged as expected (rc=$rc): $(tr '\n' ' ' < "$TMP/bad.out")"
    fi

    # (2) all terminal: PASS, with no interval needed.
    GOOD="$TMP/probe-good"
    terminal_rest "$GOOD" contacts calendar messages emails
    mkshard "$GOOD" messages.imessage '{"key":"messages","shard":"imessage","done":10,"total":10,"needs_source":false,"skip_reason":"no_messages","complete":true}'
    probe "$GOOD" "$TMP/good.out" "$TMP/no-agents-needed"; rc=$?
    if [[ "$rc" -eq 0 ]] && /usr/bin/grep -q 'VERDICT: PASS' "$TMP/good.out" && /usr/bin/grep -q 'no_messages' "$TMP/good.out"; then
        ok "all-terminal shards PASS with no plist at all (complete=true needs no interval)"
    else
        bad "all-terminal fixture did not PASS (rc=$rc): $(tr '\n' ' ' < "$TMP/good.out")"
    fi

    # (3) a notes 0/0 shard, a done==total never-complete notes shard and emails.history are not judged.
    NOTES="$TMP/probe-notes"
    terminal_rest "$NOTES" contacts calendar messages emails
    mkshard "$NOTES" notes '{"key":"notes","done":37,"total":37,"needs_source":false,"complete":false}'
    mkshard "$NOTES" emails.history '{"key":"emails.history","done":3,"total":90,"needs_source":false}'
    probe "$NOTES" "$TMP/notes.out"; rc=$?
    if [[ "$rc" -eq 0 ]] && /usr/bin/grep -q 'VERDICT: PASS' "$TMP/notes.out" \
       && /usr/bin/grep -q 'notes.json|INFO|' "$TMP/notes.out" && /usr/bin/grep -q 'emails.history.json|INFO|' "$TMP/notes.out"; then
        ok "done==total never-complete notes and emails.history are INFO and do not change the verdict"
    else
        bad "probe judged a shard outside settling_channels.json (rc=$rc): $(tr '\n' ' ' < "$TMP/notes.out")"
    fi
    NZERO="$TMP/probe-notes0"
    terminal_rest "$NZERO" contacts calendar messages emails
    mkshard "$NZERO" notes '{"key":"notes","done":0,"total":0,"needs_source":false}'
    probe "$NZERO" "$TMP/nzero.out"; rc=$?
    if [[ "$rc" -eq 0 ]] && /usr/bin/grep -q 'notes.json|INFO|' "$TMP/nzero.out"; then
        ok "a notes 0/0 shard is INFO and does not fail the probe"
    else
        bad "notes 0/0 shard affected the verdict (rc=$rc): $(tr '\n' ' ' < "$TMP/nzero.out")"
    fi

    # (4) emails updated 10 min ago, no delta in the window: PASS; StartInterval printed.
    FRESH="$TMP/probe-fresh"
    terminal_rest "$FRESH" contacts calendar messages
    mkshard "$FRESH" emails "{\"key\":\"emails\",\"done\":17441,\"total\":121893,\"updated_at\":\"$(ago 600)\"}"
    probe "$FRESH" "$TMP/fresh.out"; rc=$?
    if [[ "$rc" -eq 0 ]] && /usr/bin/grep -q 'emails.json|PASS|fresh: updated' "$TMP/fresh.out" \
       && /usr/bin/grep -q 'writer of emails: StartInterval=3600' "$TMP/fresh.out"; then
        ok "emails updated 10 min ago with no delta in the window PASSes on freshness, StartInterval printed"
    else
        bad "fresh emails shard did not PASS (rc=$rc): $(tr '\n' ' ' < "$TMP/fresh.out")"
    fi

    # (5) updated 3 h ago, complete=false: FAIL not advancing.
    STALE="$TMP/probe-stale"
    terminal_rest "$STALE" contacts calendar messages
    mkshard "$STALE" emails "{\"key\":\"emails\",\"done\":17441,\"total\":121893,\"complete\":false,\"updated_at\":\"$(ago 10800)\"}"
    probe "$STALE" "$TMP/stale.out"; rc=$?
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'emails.json|FAIL|not advancing: updated' "$TMP/stale.out"; then
        ok "emails updated 3 h ago (hourly) FAILs as not advancing"
    else
        bad "stale emails shard did not FAIL (rc=$rc): $(tr '\n' ' ' < "$TMP/stale.out")"
    fi

    # (6) updated_at is the claim, never mtime: 1.5x passes, >2x fails although the file is brand new.
    F15="$TMP/probe-15x"
    terminal_rest "$F15" contacts calendar messages
    mkshard "$F15" emails "{\"key\":\"emails\",\"done\":17441,\"total\":121893,\"complete\":false,\"updated_at\":\"$(ago 5400)\"}"
    probe "$F15" "$TMP/f15.out"; rc15=$?
    OLD="$TMP/probe-old-updated-at"
    terminal_rest "$OLD" contacts calendar messages
    mkshard "$OLD" emails "{\"key\":\"emails\",\"done\":17441,\"total\":121893,\"complete\":false,\"updated_at\":\"$(ago 7500)\"}"
    touch "$OLD/settling_progress.d/emails.json"
    probe "$OLD" "$TMP/old.out"; rcold=$?
    if [[ "$rc15" -eq 0 ]] && /usr/bin/grep -q 'emails.json|PASS|fresh' "$TMP/f15.out" \
       && [[ "$rcold" -eq 1 ]] && /usr/bin/grep -q 'emails.json|FAIL|not advancing: updated' "$TMP/old.out"; then
        ok "freshness reads updated_at: 1.5x tick PASSes; >2x tick with complete=false FAILs although the file mtime is now"
    else
        bad "updated_at freshness wrong (1.5x rc=$rc15, >2x rc=$rcold)"
    fi

    # (7) PER-CHANNEL cadence: calendar's writer (fda-rerun) ticks every 7200 s, emails every 3600 s.
    #     A calendar shard 1.5x its OWN interval old (10800 s) PASSes though it is past 2x the email interval;
    #     the same age on emails FAILs.
    A2="$TMP/agents-2"
    mkplist "$A2" "$EMAIL_LABEL" 3600
    mkplist "$A2" "$FDA_LABEL" 7200
    OWN="$TMP/probe-own-cadence"
    terminal_rest "$OWN" contacts messages
    mkshard "$OWN" emails '{"key":"emails","done":5,"total":5,"complete":true}'
    mkshard "$OWN" calendar "{\"key\":\"calendar\",\"done\":90,\"total\":100,\"complete\":false,\"updated_at\":\"$(ago 10800)\"}"
    probe "$OWN" "$TMP/own.out" "$A2"; rc=$?
    SAME="$TMP/probe-same-age-email"
    terminal_rest "$SAME" contacts messages calendar
    mkshard "$SAME" emails "{\"key\":\"emails\",\"done\":90,\"total\":100,\"complete\":false,\"updated_at\":\"$(ago 10800)\"}"
    probe "$SAME" "$TMP/same.out" "$A2"; rcs=$?
    if [[ "$rc" -eq 0 ]] && /usr/bin/grep -q 'calendar.json|PASS|fresh: updated 1080[0-9]s ago, within 2x the 7200s tick' "$TMP/own.out" \
       && [[ "$rcs" -eq 1 ]] && /usr/bin/grep -q 'emails.json|FAIL|not advancing' "$TMP/same.out"; then
        ok "calendar at 1.5x its OWN 7200 s interval PASSes; the same age on the 3600 s emails writer FAILs"
    else
        bad "per-channel cadence wrong (calendar rc=$rc, emails rc=$rcs): $(tr '\n' ' ' < "$TMP/own.out")"
    fi

    # (8) no plist: CANNOT-RUN (78), the looked-for path printed, not a done-delta fallback.
    NOPL="$TMP/probe-noplist"
    terminal_rest "$NOPL" contacts calendar messages
    mkshard "$NOPL" emails "{\"key\":\"emails\",\"done\":17441,\"total\":121893,\"updated_at\":\"$(ago 60)\"}"
    ( sleep 0.3; printf '%s\n' "{\"key\":\"emails\",\"done\":17999,\"total\":121893,\"updated_at\":\"$(ago 1)\"}" > "$NOPL/settling_progress.d/emails.json" ) &
    probe "$NOPL" "$TMP/nopl.out" "$TMP/empty-agents"; rc=$?
    wait
    if [[ "$rc" -eq 78 ]] && /usr/bin/grep -q 'VERDICT: CANNOT-RUN' "$TMP/nopl.out" \
       && /usr/bin/grep -q "$TMP/empty-agents/$EMAIL_LABEL.plist" "$TMP/nopl.out"; then
        ok "no writer plist: CANNOT-RUN with the path looked for, even when done moved in the window"
    else
        bad "missing plist was not CANNOT-RUN (rc=$rc): $(tr '\n' ' ' < "$TMP/nopl.out")"
    fi

    # (9) an unreadable plist and a channel missing from the map are CANNOT, never FAIL or PASS.
    BADPL="$TMP/agents-bad"; mkdir -p "$BADPL"; printf 'not a plist\n' > "$BADPL/$EMAIL_LABEL.plist"
    probe "$FRESH" "$TMP/badpl.out" "$BADPL"; rc=$?
    if [[ "$rc" -eq 78 ]] && /usr/bin/grep -q "unreadable" "$TMP/badpl.out" && /usr/bin/grep -q "$BADPL/$EMAIL_LABEL.plist" "$TMP/badpl.out"; then
        ok "an unreadable plist is CANNOT-RUN, path printed"
    else
        bad "unreadable plist was not CANNOT-RUN (rc=$rc): $(tr '\n' ' ' < "$TMP/badpl.out")"
    fi
    # install-only: open contacts FAILs, complete contacts PASSes (GOOD above), and a
    # channel absent from the writer map reads CANNOT (not FAIL, not PASS).
    INST="$TMP/probe-install-only"
    terminal_rest "$INST" calendar messages emails
    mkshard "$INST" contacts "{\"key\":\"contacts\",\"done\":2,\"total\":9,\"updated_at\":\"$(ago 60)\"}"
    probe "$INST" "$TMP/inst.out"; rc=$?
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'contacts.json|FAIL|open with no writer that can complete it (written once at install.sh:36416)' "$TMP/inst.out"; then
        ok "an OPEN install-only channel (contacts) is FAIL; its complete shard PASSes in the all-terminal arm"
    else
        bad "open install-only contacts was not FAIL (rc=$rc): $(tr '\n' ' ' < "$TMP/inst.out")"
    fi
    UNMAP="$TMP/probe-unmapped"
    printf '%s\n' '{"schema":1,"channels":["contacts","calendar","messages","emails","photos"]}' > "$TMP/manifest-unmapped.json"
    terminal_rest "$UNMAP" contacts calendar messages emails
    mkshard "$UNMAP" photos "{\"key\":\"photos\",\"done\":2,\"total\":9,\"updated_at\":\"$(ago 60)\"}"
    OSTLER_SETTLING_MANIFEST="$TMP/manifest-unmapped.json" probe "$UNMAP" "$TMP/unmap.out"; rc=$?
    if [[ "$rc" -eq 78 ]] && /usr/bin/grep -q 'photos.json|CANNOT|channel photos has no launchd writer label' "$TMP/unmap.out" \
       && ! /usr/bin/grep -q 'photos.json|\(PASS\|FAIL\)|' "$TMP/unmap.out"; then
        ok "an open channel absent from the writer map reads CANNOT-RUN (not FAIL, not PASS)"
    else
        bad "unmapped channel was not CANNOT-RUN (rc=$rc): $(tr '\n' ' ' < "$TMP/unmap.out")"
    fi

    # (10) a FAIL outranks a CANNOT in the overall verdict.
    OUT="$TMP/probe-fail-and-cannot"
    terminal_rest "$OUT" contacts messages
    mkshard "$OUT" emails "{\"key\":\"emails\",\"done\":1,\"total\":9,\"updated_at\":\"$(ago 90000)\"}"
    mkshard "$OUT" calendar "{\"key\":\"calendar\",\"done\":1,\"total\":9,\"updated_at\":\"$(ago 60)\"}"
    mkplist "$TMP/agents-only-email" "$EMAIL_LABEL" 3600
    probe "$OUT" "$TMP/fc.out" "$TMP/agents-only-email"; rc=$?
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'emails.json|FAIL|' "$TMP/fc.out" && /usr/bin/grep -q 'calendar.json|CANNOT|' "$TMP/fc.out"; then
        ok "a FAIL (stale emails) outranks a CANNOT (calendar plist absent) in the overall verdict"
    else
        bad "FAIL did not outrank CANNOT (rc=$rc): $(tr '\n' ' ' < "$TMP/fc.out")"
    fi

    # (11) done going backwards on a fresh shard is FAIL.
    #      The decrease is written AFTER the probe holds its start sample, signalled
    #      by the probe touching BACK_MARK (OSTLER_PROBE_START_MARKER). Never a fixed
    #      sleep: on a slow runner the probe can take longer than any sleep to reach
    #      sample 1, and a decrease that lands before it reads the same value twice
    #      and waves the regression through. OSTLER_PROBE_START_DELAY_S delays sample 1
    #      on purpose, so this arm is exercised with a slow first sample.
    BACK="$TMP/probe-back"
    BACK_MARK="$TMP/back.start-sampled"
    terminal_rest "$BACK" contacts calendar messages
    mkshard "$BACK" emails "{\"key\":\"emails\",\"done\":9000,\"total\":121893,\"updated_at\":\"$(ago 60)\"}"
    BACK_NEW="{\"key\":\"emails\",\"done\":8000,\"total\":121893,\"updated_at\":\"$(ago 1)\"}"
    (
        w=0
        while [[ ! -e "$BACK_MARK" && "$w" -lt 400 ]]; do sleep 0.05; w=$((w+1)); done
        printf '%s\n' "$BACK_NEW" > "$BACK/settling_progress.d/emails.json"
    ) &
    OSTLER_PROBE_START_DELAY_S=1 OSTLER_PROBE_START_MARKER="$BACK_MARK" \
        OSTLER_STABILITY_INTERVAL_S=3 probe "$BACK" "$TMP/back.out"; rc=$?
    wait
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'done went backwards' "$TMP/back.out"; then
        ok "a fresh shard whose done decreased FAILs"
    else
        bad "decreasing done did not FAIL (rc=$rc): $(tr '\n' ' ' < "$TMP/back.out")"
    fi

    # (12) manifest absent = FAIL, never a fallback.
    OSTLER_SETTLING_MANIFEST="$TMP/absent/settling_channels.json" probe "$GOOD" "$TMP/nomanifest.out"; rc=$?
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'settling_channels.json is absent' "$TMP/nomanifest.out"; then
        ok "absent settling_channels.json FAILs the probe instead of falling back"
    else
        bad "absent manifest did not FAIL (rc=$rc): $(tr '\n' ' ' < "$TMP/nomanifest.out")"
    fi

    # (12b) the DEFAULT lookup (no OSTLER_SETTLING_MANIFEST, as on a real box): the
    #     file must sit beside the shard dir in the state dir. Absent there = FAIL
    #     naming it (main's #3426 walk assertion, kept). Present there = PASS.
    rm -f "$GOOD/settling_channels.json"
    env -u OSTLER_SETTLING_MANIFEST OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$GOOD/settling_progress.d" bash "$PROBE" >"$TMP/nomanifest-default.out" 2>&1; rc=$?
    if [[ "$rc" -eq 1 ]] && /usr/bin/grep -q 'VERDICT: FAIL' "$TMP/nomanifest-default.out" \
       && /usr/bin/grep -q 'settling_channels.json is absent' "$TMP/nomanifest-default.out"; then
        ok "default lookup: all-terminal shards FAIL when settling_channels.json is absent beside them"
    else
        bad "default lookup did not FAIL an absent settling_channels.json (rc=$rc): $(tr '\n' ' ' < "$TMP/nomanifest-default.out")"
    fi
    cp "$REPO_ROOT/lib/settling_channels.json" "$GOOD/settling_channels.json"
    env -u OSTLER_SETTLING_MANIFEST OSTLER_STABILITY_INTERVAL_S=1 OSTLER_SETTLING_DIR="$GOOD/settling_progress.d" bash "$PROBE" >"$TMP/manifest-default.out" 2>&1; rc=$?
    if [[ "$rc" -eq 0 ]] && /usr/bin/grep -q 'VERDICT: PASS' "$TMP/manifest-default.out"; then
        ok "default lookup: the same shards PASS once settling_channels.json sits beside them"
    else
        bad "default lookup did not PASS with the manifest beside the shards (rc=$rc): $(tr '\n' ' ' < "$TMP/manifest-default.out")"
    fi

    # (13) the map names the real writers (guards a rename of the launchd labels).
    if /usr/bin/grep -q 'com.creativemachines.ostler.email-ingest' "$REPO_ROOT/vendor/email_ingest/launchd/com.creativemachines.ostler.email-ingest.plist" \
       && /usr/bin/grep -q '<string>com.ostler.fda-rerun</string>' "$INSTALL"; then
        ok "the labels in the probe's map exist in the shipped plist / install.sh"
    else
        bad "a launchd label in the probe's map is not in the shipped sources"
    fi

    OSTLER_SETTLING_DIR="$TMP/no-such-dir" bash "$PROBE" >"$TMP/none.out" 2>&1
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
