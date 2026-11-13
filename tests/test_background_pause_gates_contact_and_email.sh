#!/usr/bin/env bash
#
# test_background_pause_gates_contact_and_email.sh
#
# The tester scenario (friends-and-family report, 2026-11-13): the Hub said
# "Background work is paused" while nomic-embed-text ran on about three cores.
# The pause was honoured by the wiki and editor ticks but NOT by two jobs:
#   - com.ostler.contact-resync  (ostler-contact-resync, batch-embeds people)
#   - com.creativemachines.ostler.email-ingest (email-ingest-tick.sh, hourly)
#
# For each job this runs the REAL entry script against a sandboxed HOME with a
# stub syncer / stub emitter that RECORDS every invocation:
#   paused    (governor.env says OSTLER_PAUSED=1)  -> 0 work calls, exit 0,
#                                                     and a "paused" log line
#   unpaused  (governor.env says OSTLER_PAUSED=0)  -> work calls made, exit 0
#
# The unpaused case is the control: it proves the stub is reachable, so the
# paused case's 0 cannot come from a path that never runs.
#
# The contact-resync entry script is a heredoc inside install.sh, so it is
# extracted from there byte-for-byte. The tier lib is extracted from its own
# install.sh heredoc too, so the test runs the shipped copy, not a re-typed one.
#
# MUTATION (run by hand, recorded in the PR body): copy install.sh and the
# email tick into a scratch tree, delete the "Operator Pause" block from each,
# and run this test with PAUSE_GATE_REPO_ROOT pointing at that tree. The paused
# assertions must go RED. The override exists for exactly that purpose.
#
# Synthetic data only: the AddressBook is three empty rows; no real contacts.
# British English throughout.

set -euo pipefail

REPO_ROOT="${PAUSE_GATE_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL_SH="$REPO_ROOT/install.sh"
TICK="$REPO_ROOT/vendor/email_ingest/bin/email-ingest-tick.sh"
REAL_PY="$(command -v python3)"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass()    { echo "ok: $*"; }

for f in "$INSTALL_SH" "$TICK"; do
    if [[ ! -f "$f" ]]; then
        echo "FAIL: missing $f" >&2
        echo "test_background_pause_gates_contact_and_email: FAILED" >&2
        exit 1
    fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# extract_heredoc <file> <opening-line-suffix> <terminator>
# Prints the body of a quoted heredoc. The opening line is matched by its
# suffix, and the body ends at the first line equal to the terminator.
extract_heredoc() {
    awk -v open="$2" -v term="$3" '
        f == 0 && length($0) >= length(open) \
            && substr($0, length($0) - length(open) + 1) == open && index($0, "<<") > 0 { f = 1; next }
        f == 1 && $0 == term { f = 2 }
        f == 1 { print }
    ' "$1"
}

# Refuse to run on an empty extraction: an empty script "passes" every case.
extract_checked() {
    local out
    out="$(extract_heredoc "$1" "$2" "$3")"
    if [[ -z "$out" ]]; then
        echo "FAIL: could not extract heredoc '$2' from $1 (control: empty extraction refused)" >&2
        exit 1
    fi
    printf '%s\n' "$out"
}

# Build a sandbox HOME with the shipped tier lib and the governor file.
# $1 = sandbox dir, $2 = governor.env body ("" for no file)
make_home() {
    local dir="$1" gov="$2"
    mkdir -p "$dir/sandbox/.ostler/bin" "$dir/sandbox/.ostler/lib" \
             "$dir/sandbox/.ostler/config" "$dir/sandbox/.ostler/state" \
             "$dir/sandbox/.ostler/logs" "$dir/sandbox/.ostler/imports" \
             "$dir/sandbox/Library/Application Support/AddressBook" \
             "$dir/sandbox/.ostler/import-pipeline/.venv/bin"
    extract_checked "$INSTALL_SH" "lib/ostler-resource-tier.sh\" <<'OSTLER_RESOURCE_TIER_EOF'" \
        "OSTLER_RESOURCE_TIER_EOF" > "$dir/sandbox/.ostler/lib/ostler-resource-tier.sh"
    if [[ -n "$gov" ]]; then
        printf '%s\n' "$gov" > "$dir/sandbox/.ostler/config/governor.env"
    fi
}

# ---------------------------------------------------------------------------
# JOB 1: contact-resync. Work = contact_syncer.syncer (the batch embed).
# ---------------------------------------------------------------------------
run_contact() {
    local name="$1" gov="$2" d="$WORK/contact-$1"
    mkdir -p "$d"
    make_home "$d" "$gov"
    local home="$d/sandbox" calls="$d/syncer-calls.txt" log="$d/sandbox/.ostler/logs/contact-resync.log"
    : > "$calls"

    extract_checked "$INSTALL_SH" "bin/ostler-contact-resync\" <<'CRSEOF'" "CRSEOF" \
        > "$home/.ostler/bin/ostler-contact-resync"
    chmod +x "$home/.ostler/bin/ostler-contact-resync"

    # Synthetic address book: three rows, so the entry script has real work
    # to do when it is not paused (rows > 0 and no prior signature).
    "$REAL_PY" - "$home/Library/Application Support/AddressBook/AddressBook-v22.abcddb" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, Z_OPT INTEGER)")
con.executemany("INSERT INTO ZABCDRECORD (Z_OPT) VALUES (?)", [(1,), (1,), (1,)])
con.commit()
con.close()
PY

    # Stub interpreter: records every contact_syncer run, answers the probe
    # by delegating to the real python3.
    cat > "$home/.ostler/import-pipeline/.venv/bin/python" <<STUB
#!/bin/bash
case "\$*" in
    *contact_syncer.syncer*) echo "syncer" >> "$calls"; echo '{"imported": 3}' ;;
    *) exec "$REAL_PY" "\$@" ;;
esac
STUB
    chmod +x "$home/.ostler/import-pipeline/.venv/bin/python"

    local rc=0
    env -u OSTLER_PAUSED -u OSTLER_PAUSE_UNTIL -u OSTLER_RESOURCE_TIER_LIB \
        HOME="$home" OSTLER_RESOURCE_GOVERNOR=1 \
        bash "$home/.ostler/bin/ostler-contact-resync" >"$d/stdout.txt" 2>"$d/stderr.txt" || rc=$?
    CONTACT_RC=$rc
    CONTACT_CALLS=$(wc -l < "$calls" | tr -d ' ')
    CONTACT_LOG="$log"
}

run_contact paused "export OSTLER_PAUSED=1
export OSTLER_PAUSE_UNTIL=
export OSTLER_CPU_CORES=8"
if [[ "$CONTACT_RC" -eq 0 && "$CONTACT_CALLS" -eq 0 ]] \
    && grep -q 'paused by the operator' "$CONTACT_LOG" 2>/dev/null; then
    pass "contact-resync PAUSED: 0 syncer calls, exit 0, paused line logged"
else
    failure "contact-resync PAUSED: expected 0 syncer calls, exit 0, a paused log line; got rc=$CONTACT_RC calls=$CONTACT_CALLS"
fi

run_contact unpaused "export OSTLER_PAUSED=0
export OSTLER_PAUSE_UNTIL=
export OSTLER_CPU_CORES=8"
if [[ "$CONTACT_RC" -eq 0 && "$CONTACT_CALLS" -eq 1 ]]; then
    pass "contact-resync UNPAUSED: syncer ran once, exit 0 (control: the path is reachable)"
else
    failure "contact-resync UNPAUSED: expected 1 syncer call, exit 0; got rc=$CONTACT_RC calls=$CONTACT_CALLS"
fi

# ---------------------------------------------------------------------------
# JOB 2: email-ingest tick. Work = any call to the emitter (the harvest and
# the settling report both go through OSTLER_PYTHON).
# ---------------------------------------------------------------------------
run_email() {
    local name="$1" gov="$2" d="$WORK/email-$1"
    mkdir -p "$d"
    make_home "$d" "$gov"
    local home="$d/sandbox" calls="$d/emitter-calls.txt" stub="$d/fake-python"
    : > "$calls"
    cat > "$stub" <<STUB
#!/bin/bash
echo "emitter" >> "$calls"
exit 0
STUB
    chmod +x "$stub"

    local rc=0
    env -u OSTLER_PAUSED -u OSTLER_PAUSE_UNTIL -u OSTLER_RESOURCE_TIER_LIB \
        HOME="$home" OSTLER_DIR="$home/.ostler" OSTLER_PYTHON="$stub" \
        OSTLER_RESOURCE_GOVERNOR=1 \
        bash "$TICK" >"$d/stdout.txt" 2>"$d/stderr.txt" || rc=$?
    EMAIL_RC=$rc
    EMAIL_CALLS=$(wc -l < "$calls" | tr -d ' ')
    EMAIL_OUT="$d/stdout.txt"
}

run_email paused "export OSTLER_PAUSED=1
export OSTLER_PAUSE_UNTIL=
export OSTLER_CPU_CORES=8"
if [[ "$EMAIL_RC" -eq 0 && "$EMAIL_CALLS" -eq 0 ]] \
    && grep -q 'paused by the operator' "$EMAIL_OUT"; then
    pass "email-ingest PAUSED: 0 emitter calls, exit 0, paused line logged"
else
    failure "email-ingest PAUSED: expected 0 emitter calls, exit 0, a paused log line; got rc=$EMAIL_RC calls=$EMAIL_CALLS"
fi

run_email unpaused "export OSTLER_PAUSED=0
export OSTLER_PAUSE_UNTIL=
export OSTLER_CPU_CORES=8"
if [[ "$EMAIL_RC" -eq 0 && "$EMAIL_CALLS" -ge 1 ]]; then
    pass "email-ingest UNPAUSED: emitter called $EMAIL_CALLS time(s), exit 0 (control: the path is reachable)"
else
    failure "email-ingest UNPAUSED: expected >=1 emitter call, exit 0; got rc=$EMAIL_RC calls=$EMAIL_CALLS"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_background_pause_gates_contact_and_email: FAILED" >&2
    exit 1
fi
echo "test_background_pause_gates_contact_and_email: PASSED"
