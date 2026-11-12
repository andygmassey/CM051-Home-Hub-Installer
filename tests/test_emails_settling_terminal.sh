#!/usr/bin/env bash
#
# test_emails_settling_terminal.sh
#
# The emails shard of the Setting-up bar had NO terminal writer. On Mini16
# (2026-11-11) it sat at 17080 of 121262 and last changed 2026-11-08, so the
# bar held at 71% for good. email-bundle-tick.sh is the emails producer on the
# box; it must say when the feed is FINISHED (complete) or cannot run (skip).
#
# Contract under test (DECIDED, #3426 helpers):
#   complete  a successful FULL-window tick with nothing pending
#             (dispatched + seeded + failed == 0)
#   skip      mail_absent     pipeline rc 1 / no Mail store
#             mail_unreadable pipeline rc 2 (no Full Disk Access)
#             no_messages     successful full-window run that read 0 threads
#   NOT terminal: a non-zero pipeline rc other than 1/2 (a crash or a slot
#             yield), a daytime 2-day clamped window (it has not seen the
#             backlog), or any tick with pending work.
#
# Synthetic fixtures only. The pipeline is replaced by a stub that prints the
# summary JSON shape pipeline.py prints and exits with a chosen rc. Nothing
# touches the real HOME, Mail, Ollama or the network.
#
# Usage: bash tests/test_emails_settling_terminal.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICK="$REPO_ROOT/vendor/email_source/bin/email-bundle-tick.sh"
LIB="$REPO_ROOT/lib/settling_progress.sh"
INSTALL="$REPO_ROOT/install.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/emails-settle.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# write_summary <file> <scanned> <dispatched> <seeded> <failed>
# Same shape as pipeline.py's json.dumps(summary, indent=2).
write_summary() {
    {
        printf '{\n'
        printf '  "threads_scanned": %s,\n' "$2"
        printf '  "threads_seeded": %s,\n' "$4"
        printf '  "threads_dispatched": %s,\n' "$3"
        printf '  "threads_skipped": 0,\n'
        printf '  "threads_failed": %s\n' "$5"
        printf '}\n'
    } > "$1"
}

# run_case <name> <pipeline_rc> <summary_file_or_-> <mail: present|absent> <clamp: 0|1> [prior_shard_json]
# Sets: CASE_RC (tick exit), CASE_STATE (state dir), CASE_OUT (stdout+stderr)
run_case() {
    local name="$1" prc="$2" sum="$3" mail="$4" clamp="$5" prior="${6:-}"
    local root="$WORK/$name"
    local home="$root/home" state="$root/state" services="$root/services/email-source"
    mkdir -p "$home/.ostler/lib" "$state/settling_progress.d" "$services" "$root/lock-parent"
    cp "$LIB" "$home/.ostler/lib/settling_progress.sh"
    if [ "$mail" = present ]; then mkdir -p "$root/Mail"; fi
    if [ -n "$prior" ]; then printf '%s\n' "$prior" > "$state/settling_progress.d/emails.json"; fi

    # Stub python: prints the summary (if any) and exits with the chosen rc.
    printf '%s\n' '#!/usr/bin/env bash' \
        '[ -n "${FAKE_SUMMARY:-}" ] && cat "$FAKE_SUMMARY"' \
        'exit "${FAKE_RC:-0}"' > "$root/stub-python"
    chmod +x "$root/stub-python"

    local fake_summary=/dev/null
    if [ "$sum" != "-" ]; then fake_summary="$sum"; fi

    env -i PATH=/usr/bin:/bin HOME="$home" \
        OSTLER_PYTHON="$root/stub-python" \
        OSTLER_SOURCE_DIR="$services" \
        OSTLER_MAIL_DIR="$root/Mail" \
        OSTLER_STATE_DIR="$state" \
        OSTLER_INGEST_LOCK="$root/lock-parent/ingest.lock.d" \
        OSTLER_INGEST_SLOT=0 \
        OSTLER_INGEST_SLOT_LIB="$root/none.sh" \
        OSTLER_RESOURCE_GOVERNOR=0 \
        OSTLER_INTERACTIVE_TTL_SECS=0 \
        OSTLER_INGEST_OFFPEAK_ONLY="$clamp" \
        OSTLER_INGEST_QUIET_START=5 OSTLER_INGEST_QUIET_END=5 \
        OSTLER_EMAIL_SINCE_DAYS=30 \
        FAKE_RC="$prc" FAKE_SUMMARY="$fake_summary" \
        bash "$TICK" > "$root/out" 2> "$root/err"
    CASE_RC=$?
    CASE_STATE="$state/settling_progress.d/emails.json"
    CASE_OUT="$(cat "$root/out" "$root/err")"
}

shard_has() {   # shard_has <needle>  -- true if emails.json contains needle
    [ -f "$CASE_STATE" ] && grep -q -- "$1" "$CASE_STATE"
}

# ── 1. Zero backlog, full window: COMPLETE, rc preserved ─────────────────
S="$WORK/sum1.json"; write_summary "$S" 12 0 0 0
run_case zero-backlog 0 "$S" present 0
if [ "$CASE_RC" = 0 ] && shard_has '"complete": true' && shard_has '"skip_reason": ""'; then
    ok "zero backlog on a full window writes complete:true and keeps rc 0"
else
    bad "zero backlog did not write a terminal complete (rc=$CASE_RC shard: $(cat "$CASE_STATE" 2>/dev/null || echo missing))"
fi

# ── 1b. Complete is monotonic: a 500/900 shard reads 900/900 ─────────────
S="$WORK/sum1b.json"; write_summary "$S" 12 0 0 0
run_case zero-backlog-prior 0 "$S" present 0 \
    '{"key":"emails","done":500,"total":900,"needs_source":false,"started_at":"2026-11-08T07:00:00+00:00","updated_at":"2026-11-08T07:00:00+00:00"}'
if shard_has '"done": 900' && shard_has '"total": 900' && shard_has '"complete": true'; then
    ok "complete raises a 500/900 shard to 900/900 (done monotonic, total kept)"
else
    bad "complete did not raise the prior 500/900 shard to 900/900 (shard: $(cat "$CASE_STATE" 2>/dev/null || echo missing))"
fi

# ── 2. Pending work: NOT terminal ────────────────────────────────────────
S="$WORK/sum2.json"; write_summary "$S" 12 3 0 0
run_case pending 0 "$S" present 0
if ! shard_has '"complete": true'; then ok "pending work (3 dispatched) is not terminal"
else bad "pending work was marked complete"; fi

# ── 2b. Seeded-but-not-dispatched work: NOT terminal ─────────────────────
S="$WORK/sum2b.json"; write_summary "$S" 12 0 5 0
run_case seeded-pending 0 "$S" present 0
if ! shard_has '"complete": true'; then ok "seeded work (5 seeded, 0 dispatched) is not terminal"
else bad "seeded-but-pending work was marked complete"; fi

# ── 3. Failed thread, nothing dispatched: NOT terminal ───────────────────
S="$WORK/sum3.json"; write_summary "$S" 12 0 0 1
run_case failed-thread 0 "$S" present 0
if ! shard_has '"complete": true'; then ok "a failed thread is not terminal (watermark retries it)"
else bad "a failed thread was marked complete"; fi

# ── 4. Daytime clamped 2-day window: NOT terminal ────────────────────────
S="$WORK/sum4.json"; write_summary "$S" 12 0 0 0
run_case clamped 0 "$S" present 1
if ! shard_has '"complete": true'; then ok "a clamped 2-day window with zero pending is not terminal"
else bad "a partial (clamped) window was marked complete"; fi

# ── 5. Mail store absent: SKIP with a plain reason ───────────────────────
run_case mail-absent 0 - absent 0
if shard_has '"complete": true' && shard_has '"skip_reason": "mail_absent"'; then
    ok "no Mail store is a skip with reason mail_absent"
else
    bad "no Mail store did not write skip mail_absent (shard: $(cat "$CASE_STATE" 2>/dev/null || echo missing))"
fi

# ── 6. Mail unreadable (pipeline rc 2 = PermissionError): SKIP ───────────
run_case mail-unreadable 2 - present 0
if shard_has '"skip_reason": "mail_unreadable"'; then
    ok "pipeline rc 2 (no Full Disk Access) is a skip with reason mail_unreadable"
else
    bad "rc 2 did not write skip mail_unreadable (shard: $(cat "$CASE_STATE" 2>/dev/null || echo missing))"
fi

# ── 7. Mail present, zero messages read: SKIP no_messages ────────────────
S="$WORK/sum7.json"; write_summary "$S" 0 0 0 0
run_case empty-mailbox 0 "$S" present 0
if shard_has '"skip_reason": "no_messages"'; then ok "a full-window run that reads 0 threads is a skip no_messages"
else bad "an empty full-window run did not write skip no_messages"; fi

# ── 8. Crash (rc 3): NOT terminal, rc propagated ─────────────────────────
run_case crash 3 - present 0
if [ "$CASE_RC" = 3 ] && ! shard_has '"complete": true' && ! shard_has '"skip_reason"'; then
    ok "a crashed pipeline (rc 3) writes nothing terminal and propagates rc 3"
else
    bad "a crash wrote a terminal state or changed rc (rc=$CASE_RC)"
fi

# ── 9. The writer is deployed by install.sh, not just present in the repo ─
# Without this line the lib is absent from ~/.ostler/lib on a customer box and
# every case above is a no-op there. Joined onto an existing line so no install.sh
# line number moves (see the line-neutral rule for install.sh citations).
if grep -q 'cp "${SCRIPT_DIR}/lib/settling_progress.sh" "${OSTLER_DIR}/lib/"' "$INSTALL"; then
    ok "install.sh deploys lib/settling_progress.sh to \${OSTLER_DIR}/lib"
else
    bad "install.sh does not deploy lib/settling_progress.sh to \${OSTLER_DIR}/lib"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
