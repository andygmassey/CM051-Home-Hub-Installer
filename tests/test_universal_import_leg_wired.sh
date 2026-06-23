#!/usr/bin/env bash
#
# tests/test_universal_import_leg_wired.sh
#
# Pins the v1.0.3 wiring of the previously-orphan universal_import (P3)
# path into the real install. Before this leg existed, ostler_fda's
# universal_import ran NOWHERE on a customer box: a dropped Facebook
# Messenger export (detector HR015 #219 + parser HR015 #220) only ever
# wrote staging JSON to ~/.ostler/imports/fda/ and never reached the
# conversations store. This test asserts that the shared ostler-import
# fan-out now has a THIRD leg that runs universal_import over each
# detected export dir, and that the leg is strictly additive and
# skip-if-absent so it can never regress P1 (contacts) or P2 (prefs).
#
# Two axes:
#   STATIC  -- byte-walk the ostler-import heredoc in install.sh: the P3
#              leg is present, targets the email-ingest venv (the one venv
#              with ostler_fda installed), invokes ostler_fda.universal_import,
#              and is ordered AFTER P1/P2 inside the per-dir loop.
#   RUNTIME -- extract the heredoc to a temp ostler-import, stub P1/P2/P3 as
#              recording fakes, and prove (a) the P3 leg fires, (b) it is
#              skipped cleanly when its venv is absent, and (c) P1 + P2 still
#              fire in both cases (no regression).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass()    { echo "ok: $*"; }

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FATAL: install.sh not found at $INSTALL_SH" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Carve the ostler-import heredoc (between the quoted IMPORTEOF markers).
# ---------------------------------------------------------------------------
HEREDOC_START="$(grep -n "cat > \"\$IMPORT_SCRIPT\" <<'IMPORTEOF'" "$INSTALL_SH" | head -1 | cut -d: -f1)"
if [[ -z "$HEREDOC_START" ]]; then
    failure "could not locate the ostler-import heredoc opener (<<'IMPORTEOF')"
    echo "FAILED" >&2
    exit 1
fi
HEREDOC_END="$(awk -v start="$HEREDOC_START" 'NR > start && /^IMPORTEOF$/ { print NR; exit }' "$INSTALL_SH")"
if [[ -z "$HEREDOC_END" ]]; then
    failure "could not locate the ostler-import heredoc terminator (IMPORTEOF)"
    echo "FAILED" >&2
    exit 1
fi
# Body is the lines strictly between opener and terminator.
IMPORT_BODY="$(sed -n "$((HEREDOC_START + 1)),$((HEREDOC_END - 1))p" "$INSTALL_SH")"

# ---------------------------------------------------------------------------
# STATIC axis
# ---------------------------------------------------------------------------

# A1: P3 leg invokes ostler_fda.universal_import.
if printf '%s' "$IMPORT_BODY" | grep -qE '\-m ostler_fda\.universal_import'; then
    pass "P3 leg invokes ostler_fda.universal_import"
else
    failure "ostler-import does not invoke ostler_fda.universal_import (P3 leg missing)"
fi

# A2: the leg runs from the email-ingest venv -- the only venv on the box
#     that pip-installs ostler_fda (same venv the calendar/browsing/imessage
#     ingests already use). A bare `python3` would hit ModuleNotFoundError.
if printf '%s' "$IMPORT_BODY" | grep -qE 'UIMPORT_PY="\$\{OSTLER_DIR\}/services/email-ingest/\.venv/bin/python"'; then
    pass "P3 leg targets the email-ingest venv (has ostler_fda)"
else
    failure "P3 leg does not resolve the email-ingest venv python (UIMPORT_PY)"
fi

# A3: the leg is GUARDED on its venv being executable (skip-if-absent).
if printf '%s' "$IMPORT_BODY" | grep -qE '\[\[ -x "\$UIMPORT_PY" \]\]'; then
    pass "P3 leg is guarded on UIMPORT_PY existence (skip-if-absent)"
else
    failure "P3 leg is not guarded on UIMPORT_PY (could fail when venv absent)"
fi

# A4: ordering -- the universal_import invocation appears AFTER both the
#     contact_syncer (P1) and the CM019 ingest (P2) invocations, so P3 is
#     strictly additive on top of the existing fan-out.
P1_LINE="$(printf '%s\n' "$IMPORT_BODY" | grep -nE 'contact_syncer\.import_all' | head -1 | cut -d: -f1)"
P2_LINE="$(printf '%s\n' "$IMPORT_BODY" | grep -nE 'services\.ingest\.src\.cli ingest-dir' | head -1 | cut -d: -f1)"
P3_LINE="$(printf '%s\n' "$IMPORT_BODY" | grep -nE '\-m ostler_fda\.universal_import' | head -1 | cut -d: -f1)"
if [[ -n "$P1_LINE" && -n "$P2_LINE" && -n "$P3_LINE" \
      && "$P3_LINE" -gt "$P1_LINE" && "$P3_LINE" -gt "$P2_LINE" ]]; then
    pass "P3 leg is ordered after P1 (contacts) and P2 (preferences)"
else
    failure "P3 leg is not ordered after P1/P2 (P1=$P1_LINE P2=$P2_LINE P3=$P3_LINE)"
fi

# A5: vendored universal_import.py is present (the file must SHIP, else the
#     leg ModuleNotFounds at runtime). It carries the persistence helper.
UIMPORT_VENDOR="${REPO_ROOT}/vendor/ostler_fda/universal_import.py"
if [[ -f "$UIMPORT_VENDOR" ]]; then
    pass "vendored ostler_fda/universal_import.py is present"
    if grep -q "_persist_conversations" "$UIMPORT_VENDOR" \
       && grep -q "_pwg_convo_cmd" "$UIMPORT_VENDOR"; then
        pass "vendored universal_import carries the CM048 persistence helper"
    else
        failure "vendored universal_import is missing the persistence helper"
    fi
else
    failure "vendored ostler_fda/universal_import.py is absent (P3 leg would ModuleNotFound)"
fi

# ---------------------------------------------------------------------------
# RUNTIME axis -- extract the heredoc and drive it against stubbed legs.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_HOME="$WORK/home"
OSTLER="$FAKE_HOME/.ostler"
mkdir -p "$OSTLER/bin"

# Materialise the ostler-import script from the heredoc body.
IMPORT_SCRIPT="$OSTLER/bin/ostler-import"
printf '%s\n' "$IMPORT_BODY" > "$IMPORT_SCRIPT"
chmod +x "$IMPORT_SCRIPT"

CALLS="$WORK/calls.log"
: > "$CALLS"

# Stub P1: contact_syncer is invoked as `python3 -m contact_syncer.import_all`
# from $PIPELINE_DIR. We fake the pipeline venv python as a recorder.
mkdir -p "$OSTLER/import-pipeline/contact_syncer" "$OSTLER/import-pipeline/.venv/bin"
cat > "$OSTLER/import-pipeline/.venv/bin/python3" <<EOF
#!/usr/bin/env bash
echo "P1 \$*" >> "$CALLS"
exit 0
EOF
chmod +x "$OSTLER/import-pipeline/.venv/bin/python3"

# Stub P2: CM019 ingest python recorder.
mkdir -p "$OSTLER/services/cm019/.venv/bin"
cat > "$OSTLER/services/cm019/.venv/bin/python" <<EOF
#!/usr/bin/env bash
echo "P2 \$*" >> "$CALLS"
exit 0
EOF
chmod +x "$OSTLER/services/cm019/.venv/bin/python"

# Stub P3: email-ingest venv python recorder.
mkdir -p "$OSTLER/services/email-ingest/.venv/bin"
cat > "$OSTLER/services/email-ingest/.venv/bin/python" <<EOF
#!/usr/bin/env bash
echo "P3 \$*" >> "$CALLS"
exit 0
EOF
chmod +x "$OSTLER/services/email-ingest/.venv/bin/python"

# A drop dir for the importer to iterate.
DROP="$WORK/drop"
mkdir -p "$DROP"

# --- Run 1: all three legs present -----------------------------------------
( HOME="$FAKE_HOME" "$IMPORT_SCRIPT" "$DROP" --user-name "Test User" --user-id test ) \
    >/dev/null 2>&1 || failure "run-1 ostler-import exited non-zero with all legs present"

if grep -q '^P1 ' "$CALLS"; then pass "run-1: P1 (contacts) fired"; else failure "run-1: P1 did not fire"; fi
if grep -q '^P2 ' "$CALLS"; then pass "run-1: P2 (preferences) fired"; else failure "run-1: P2 did not fire"; fi
if grep -q '^P3 .*ostler_fda.universal_import' "$CALLS"; then
    pass "run-1: P3 (universal_import) fired over the drop dir"
else
    failure "run-1: P3 universal_import leg did not fire"
fi

# --- Run 2: P3 venv absent -> leg skipped, P1/P2 still fire -----------------
: > "$CALLS"
rm -rf "$OSTLER/services/email-ingest"
( HOME="$FAKE_HOME" "$IMPORT_SCRIPT" "$DROP" --user-name "Test User" --user-id test ) \
    >/dev/null 2>&1 || failure "run-2 ostler-import exited non-zero with P3 venv absent"

if grep -q '^P3 ' "$CALLS"; then
    failure "run-2: P3 leg fired despite its venv being absent (not skip-if-absent)"
else
    pass "run-2: P3 leg cleanly skipped when its venv is absent"
fi
if grep -q '^P1 ' "$CALLS"; then pass "run-2: P1 still fired (no regression)"; else failure "run-2: P1 regressed"; fi
if grep -q '^P2 ' "$CALLS"; then pass "run-2: P2 still fired (no regression)"; else failure "run-2: P2 regressed"; fi

# ---------------------------------------------------------------------------
if [[ "$FAILED" -ne 0 ]]; then
    echo "FAILED" >&2
    exit 1
fi
echo "PASS: universal_import (P3) leg wired, additive, and skip-if-absent."
