#!/usr/bin/env bash
#
# settling_progress.sh -- shell writer for the wiki's settling-progress panel.
#
# WHY A SECOND IMPLEMENTATION EXISTS
# ----------------------------------
# HR015 ships ostler_fda/settling_progress.py, and the producers that live in
# ostler_fda (iMessage, WhatsApp, calendar) plus the Doctor's Evernote import
# call it directly.
#
# Two channels cannot. `contacts` is CM041's contact_syncer and `emails` is
# CM021's pwg-email-ingest; both run from PIPELINE_DIR / the email-ingest
# venv, and install.sh copies contact_syncer, meeting_syncer and
# identity_resolver into PIPELINE_DIR but NEVER ostler_fda. So
# `from ostler_fda.settling_progress import ...` raises ImportError at runtime
# on a customer's Mac. (Checked, not assumed -- see Phase 3.x bundling block.)
#
# Rather than vendor a fourth copy of a Python module, those two channels
# report from install.sh, which is where their phases already run and already
# parse the producer's --json output. The contract is the FILESYSTEM, not the
# language: same directory, same filename rule, same six fields.
#
# THE CONTRACT (must match CM044/compiler/hydration.py::_read_progress_shards
# and HR015/ostler_fda/settling_progress.py)
#
#   dir       ${OSTLER_STATE_DIR:-$HOME/.ostler/state}/settling_progress.d/
#   file      <channel>.json, or <channel>.<shard>.json when sharded
#   payload   {"key","done","total","needs_source","started_at","updated_at"}
#
#   * `key` must be one of contacts|calendar|messages|emails|notes. Anything
#     else renders as generic "Another part of your history" copy. `email`
#     (singular) and `meetings` are the near-misses.
#   * ONE producer per file. Two writers on one shard overwrite each other and
#     the panel jumps backwards when the second opens at zero.
#   * `started_at` is preserved across writes -- it anchors the wiki's
#     rate-based ETA. Rewriting it every tick resets the estimate forever.
#   * Writes are atomic (temp file in the same directory, then mv) so the
#     reader never sees half a JSON document.
#
# Failure policy: NEVER fail the install. A settling shard is telemetry for a
# progress panel; a full disk or a read-only state dir must not cost the
# customer their contact import. Every function returns 0.
#
# Usage:
#   . "${SCRIPT_DIR}/lib/settling_progress.sh"
#   settling_report contacts 0 1200          # announce at 0-of-N
#   settling_report contacts 1200 1200       # completion
#   settling_report notes 0 0 true           # waiting on a source
#   settling_report messages 40 90 false sms # sharded

# Guard against double-sourcing (install.sh sources libs from several phases).
if [[ -n "${_OSTLER_SETTLING_PROGRESS_SH:-}" ]]; then
    return 0 2>/dev/null || true
fi
_OSTLER_SETTLING_PROGRESS_SH=1

# The five keys CM044 has curated copy for. Kept as a plain string so this
# file stays sourceable by bash 3.2 (macOS system bash) -- no associative
# arrays, no `readarray`.
_SETTLING_VALID_CHANNELS="contacts calendar messages emails notes"

settling_state_dir() {
    if [[ -n "${OSTLER_STATE_DIR:-}" ]]; then
        printf '%s' "${OSTLER_STATE_DIR}"
    else
        printf '%s' "${HOME}/.ostler/state"
    fi
}

settling_shard_dir() {
    printf '%s/settling_progress.d' "$(settling_state_dir)"
}

# settling_source_total <channel> [shard]
#
# The REAL denominator: how much of this source exists on the Mac, not how much
# one pass happened to touch.
#
# WHY THIS EXISTS (2026-08-08)
# ---------------------------------------------------------------------------
# The install used to report `done == total` at the end of each hydrate phase,
# with a comment calling that "the honest statement -- this channel is settled".
# It is not. The install ingests a SLICE and the hourly LaunchAgents carry on
# for days; reporting the slice as the whole pins the bar at 100% by
# construction. Measured on a real box on 2026-08-08:
#
#     channel     reported        actually on disk
#     ----------  --------------  ----------------
#     messages    167 of 167      28,405 rows in chat.db
#     emails      641 of 641      16,565 .emlx files
#
# 0.6% of the work, rendered as finished. The panel exists precisely to tell a
# customer "this takes days" -- so a panel that cannot show anything except
# 100% is worse than no panel, because it is a promise the product breaks on
# first contact.
#
# Prints an integer on stdout. Prints 0 when the source cannot be measured --
# callers MUST treat 0 as "unknown", never as "empty", and fall back to the
# count they have rather than publishing a denominator they invented.
#
# Every branch is best-effort and silent: this is telemetry, and a locked
# database or a missing file must never cost the customer their import.
settling_source_total() {
    local channel="${1:-}" shard="${2:-}" n=0

    case "$channel" in
        messages)
            case "$shard" in
                whatsapp)
                    # macOS WhatsApp is ChatStorage.sqlite in the SHARED group
                    # container. msgstore.db is the Android name and does not
                    # exist here -- an earlier version of this function looked
                    # for it, measured 0, and silently fell back to
                    # done-as-total, which is the bug it was written to fix.
                    local wa
                    wa="${HOME}/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
                    [[ -f "$wa" ]] && n="$(sqlite3 "file:${wa}?immutable=1" \
                        'SELECT COUNT(*) FROM ZWAMESSAGE' 2>/dev/null || echo 0)"
                    ;;
                *)
                    # immutable=1: read a live, WAL-mode chat.db without taking
                    # a lock or perturbing Messages.app.
                    [[ -f "${HOME}/Library/Messages/chat.db" ]] && \
                        n="$(sqlite3 "file:${HOME}/Library/Messages/chat.db?immutable=1" \
                            'SELECT COUNT(*) FROM message' 2>/dev/null || echo 0)"
                    ;;
            esac
            ;;
        emails)
            # No depth cap. Measured on a real store: .emlx files sit as deep
            # as 11 levels below ~/Library/Mail, so the -maxdepth 8 this used
            # to carry found 6,584 of 16,844 -- a wrong denominator is the same
            # class of defect as no denominator. An unbounded find over 16k
            # files measured 0s, so the cap bought nothing.
            [[ -d "${HOME}/Library/Mail" ]] && \
                n="$(find "${HOME}/Library/Mail" -name '*.emlx' 2>/dev/null | wc -l | tr -d ' ')"
            ;;
        contacts)
            # Contacts do NOT live in the top-level AddressBook-v22.abcddb --
            # that one is empty on a real Mac. They are sharded per account
            # under Sources/<uuid>/. Sum across every store.
            local ab total=0 one
            while IFS= read -r ab; do
                [[ -n "$ab" ]] || continue
                one="$(sqlite3 "file:${ab}?immutable=1" \
                    'SELECT COUNT(*) FROM ZABCDRECORD WHERE ZFIRSTNAME IS NOT NULL OR ZLASTNAME IS NOT NULL OR ZORGANIZATION IS NOT NULL' \
                    2>/dev/null || echo 0)"
                case "$one" in ''|*[!0-9]*) one=0 ;; esac
                total=$(( total + one ))
            done < <(find "${HOME}/Library/Application Support/AddressBook" \
                        -name 'AddressBook-v22.abcddb' 2>/dev/null)
            n="$total"
            ;;
        *)
            # calendar and notes have no cheap shell-side count. Their
            # producers live in ostler_fda and measure their own totals.
            n=0
            ;;
    esac

    case "$n" in
        ''|*[!0-9]*) n=0 ;;
    esac
    printf '%s' "$n"
    return 0
}

# settling_report_measured <channel> <done> [needs_source] [shard]
#
# settling_report with the denominator measured from the source instead of
# supplied by the caller. Use this from any phase that processes a SLICE and
# leaves the rest to the hourly agents -- which is every hydrate phase.
#
# Falls back to done-as-total only when the source cannot be measured, and says
# so in the install log, because a silent fallback here reintroduces exactly
# the defect this function exists to remove.
settling_report_measured() {
    local channel="${1:-}" done_n="${2:-0}" needs_source="${3:-false}" shard="${4:-}"
    local total_n
    total_n="$(settling_source_total "$channel" "$shard")"

    if [[ "${total_n:-0}" -le 0 ]]; then
        printf 'settling: %s source volume unmeasurable; falling back to done-as-total (bar will read 100%%)\n' \
            "$channel" >&2
        total_n="$done_n"
    elif [[ "$total_n" -lt "$done_n" ]]; then
        # Ingest can legitimately exceed a naive source count (dedup expansion,
        # multi-source merges). A total below done would render over 100%.
        total_n="$done_n"
    fi

    settling_report "$channel" "$done_n" "$total_n" "$needs_source" "$shard"
    return 0
}

# settling_report <channel> <done> <total> [needs_source] [shard]
#
# Always returns 0. Rejects an unknown channel loudly in the install log but
# still returns 0 -- a typo must be visible to us without being fatal to the
# customer.
settling_report() {
    local channel="${1:-}" done_n="${2:-0}" total_n="${3:-0}"
    local needs_source="${4:-false}" shard="${5:-}"

    case " ${_SETTLING_VALID_CHANNELS} " in
        *" ${channel} "*) : ;;
        *)
            printf 'settling: refusing unknown channel %s (valid: %s)\n' \
                "${channel:-<empty>}" "$_SETTLING_VALID_CHANNELS" >&2
            return 0
            ;;
    esac

    local dir; dir="$(settling_shard_dir)"
    local file="${channel}.json"
    [[ -n "$shard" ]] && file="${channel}.${shard}.json"

    mkdir -p "$dir" 2>/dev/null || {
        printf 'settling: cannot create %s; skipping %s\n' "$dir" "$channel" >&2
        return 0
    }

    # JSON assembly in python3 rather than printf: it escapes correctly, does
    # the atomic replace, and preserves started_at in one pass. python3 is
    # already a hard dependency of every hydrate phase in this installer.
    OSTLER_SETTLING_TARGET="${dir}/${file}" \
    OSTLER_SETTLING_KEY="$channel" \
    OSTLER_SETTLING_DONE="$done_n" \
    OSTLER_SETTLING_TOTAL="$total_n" \
    OSTLER_SETTLING_NEEDS="$needs_source" \
    python3 - <<'PYEOF' 2>/dev/null || true
import json, os, tempfile
from datetime import datetime, timezone

target = os.environ["OSTLER_SETTLING_TARGET"]
key = os.environ["OSTLER_SETTLING_KEY"]


def _int(name):
    try:
        return max(0, int(os.environ.get(name, "0") or 0))
    except (TypeError, ValueError):
        return 0


now = datetime.now(timezone.utc).isoformat(timespec="seconds")

# Preserve started_at: it anchors CM044's rate-based ETA. Rewriting it on
# every tick makes the estimate reset forever and the bar stops falling.
started = None
try:
    with open(target, "r", encoding="utf-8") as fh:
        prev = json.load(fh)
    if isinstance(prev, dict):
        cand = prev.get("started_at")
        if isinstance(cand, str) and cand.strip():
            started = cand
except Exception:
    started = None

payload = {
    "key": key,
    "done": _int("OSTLER_SETTLING_DONE"),
    "total": _int("OSTLER_SETTLING_TOTAL"),
    "needs_source": os.environ.get("OSTLER_SETTLING_NEEDS", "false").strip().lower()
    in ("1", "true", "yes"),
    "started_at": started or now,
    "updated_at": now,
}

# Atomic: temp file in the SAME directory (os.replace is only atomic within
# one filesystem), then replace. The reader must never see partial JSON.
d = os.path.dirname(target)
tmp = None
try:
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settling.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, sort_keys=True)
        fh.write("\n")
        fh.flush()
        try:
            os.fsync(fh.fileno())
        except OSError:
            pass
    os.replace(tmp, target)
    tmp = None
finally:
    if tmp is not None:
        try:
            os.unlink(tmp)
        except OSError:
            pass
PYEOF
    return 0
}
