#!/usr/bin/env bash
# tests/test_enrich_agent_installs_without_exports.sh
# ============================================================================
# The recurring enrichment agent (com.ostler.enrich) must install whenever the
# customer accepts public look-ups, regardless of how many preferences exist
# and regardless of whether any export folder was supplied at install.
#
# It used to sit inside two gates: `if _PREFS_POINTS -gt 0` (itself inside
# `if ${#_IMPORT_DIRS[@]} -gt 0`). A customer with no exports on day one never
# got the agent, although the consent screen had just said yes.
#
# WHAT THIS RUNS. The REAL consent question (lifted verbatim, gui_read stubbed
# to take the seeded default on Enter), then the REAL install tail: the import
# gate, its elif, the unset, and the agent call, lifted from install.sh by exact
# match. _IMPORT_DIRS is empty and _PREFS_POINTS is 0, which is the case that
# matters. The agent function is lifted from install.sh and run for real, writing
# its wrapper and plist into a scratch HOME, with launchctl stubbed to succeed.
#
# SCENARIOS
#   A  accepted (Enter), 0 points, no exports -> wrapper and plist installed
#   B  declined (n),     0 points, no exports -> nothing installed, says so
#   C  accepted (y),     0 points, no exports -> installed (explicit yes)
#
# MUTANT: a copy of install.sh with the agent call moved back inside the
# points/import gates must turn A and C red. Run with INSTALL_SH=<mutant>.
#
# Exit: 0 pass, 1 an assertion failed, 2 cannot-run.
# ============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${INSTALL_SH:-${REPO}/install.sh}"
[ -r "$SRC" ] || { echo "CANNOT-RUN: cannot read $SRC"; exit 2; }
WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
cannot() { echo "CANNOT-RUN: $*" >&2; exit 2; }

# ---- (1) the real consent question, verbatim ------------------------------
CONSENT="$WORK/consent.sh"
start="$(grep -n -m1 -F -x 'OSTLER_ENRICH_AGENT_ENABLED=1' "$SRC" | cut -d: -f1)"
end="$(grep -n -m1 -F -x 'export OSTLER_CONSENT_ENRICHMENT_DECISION' "$SRC" | cut -d: -f1)"
[ -n "$start" ] && [ -n "$end" ] || cannot "consent block not found in $SRC"
sed -n "${start},${end}p" "$SRC" > "$CONSENT"

# ---- (2) the real install tail: import gate .. agent call .. its closing fi --
TAIL="$WORK/tail.sh"
imp_start="$(grep -n -m1 -F -x 'if [[ ${#_IMPORT_DIRS[@]} -gt 0 && -x "$IMPORT_SCRIPT" ]]; then' "$SRC" | cut -d: -f1)"
[ -n "$imp_start" ] || cannot "import gate not found in $SRC"
# The region ends at the first column-0 fi AFTER the agent call. In the fixed
# install.sh that fi closes the consent gate that calls the agent. In a mutant
# where the call sits inside the import gate, it closes the import gate, and the
# call is then inside a region that does not run when there are no exports.
tail_end="$(awk -v s="$imp_start" 'NR>s && /_install_enrichment_agent$/ {seen=1} seen && /^fi$/ {print NR; exit}' "$SRC")"
[ -n "$tail_end" ] || cannot "no agent call found after the import gate in $SRC"
sed -n "${imp_start},${tail_end}p" "$SRC" > "$TAIL"

# ---- (3) the real agent function, verbatim --------------------------------
FUNC="$WORK/func.sh"
fstart="$(grep -n -m1 -E '^_install_enrichment_agent\(\) \{$' "$SRC" | cut -d: -f1)"
[ -n "$fstart" ] || cannot "_install_enrichment_agent definition not found in $SRC"
fend="$(awk -v s="$fstart" 'NR>s && /MSG_WARN_ENRICH_AGENT_LOAD_FAILED/ {seen=1} seen && /^}$/ {print NR; exit}' "$SRC")"
[ -n "$fend" ] || cannot "end of _install_enrichment_agent not found"
sed -n "${fstart},${fend}p" "$SRC" > "$FUNC"

status=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; status=1; }

# run_case NAME ANSWER [TREE]   (ANSWER "" = Enter, takes the seeded default;
# TREE=absent leaves the CM019 tree out, as a box where step 14 did not run)
run_case() {
    local name="$1" answer="$2" tree="${3:-present}" home="$WORK/$1/home"
    mkdir -p "$home/bin"
    printf '#!/bin/sh\nexit 0\n' > "$home/bin/launchctl"
    chmod +x "$home/bin/launchctl"
    if [ "$tree" = present ] || [ "$tree" = nomatch ]; then
        # step 14 installs the CM019 tree; the agent reads its enricher for the namespace
        mkdir -p "$home/.ostler/services/cm019/services/enrich/src"
        if [ "$tree" = present ]; then
            cp "$REPO/vendor/cm019_preferences/services/enrich/src/enricher.py" \
               "$home/.ostler/services/cm019/services/enrich/src/enricher.py"
        else
            # readable, but holds no namespace: grep exits 1, a real answer
            printf '# an enricher with no ontology namespace in it\n' \
                > "$home/.ostler/services/cm019/services/enrich/src/enricher.py"
        fi
    fi
    PATH="$home/bin:$PATH" HOME="$home" ANSWER="$answer" \
    CONSENT="$CONSENT" TAIL="$TAIL" FUNC="$FUNC" bash -c '
        set -Eeuo pipefail
        OSTLER_DIR="${HOME}/.ostler"; export OSTLER_DIR
        LOGS_DIR="${OSTLER_DIR}/logs"   # set by install.sh before the agent runs
        mkdir -p "$OSTLER_DIR/config"
        USER_ID_ARG=ostler
        _PREFS_POINTS=0          # no preferences in the store
        _IMPORT_DIRS=()          # no export folder at install
        unset EXPORTS_DIR
        IMPORT_SCRIPT=/nonexistent/ostler-import.sh
        MSG_PROMPT_CONSENT_ENRICHMENT_TITLE=t; MSG_PROMPT_CONSENT_ENRICHMENT_HELP=h
        MSG_OK_ENRICH_AGENT_LOADED="agent-loaded"; MSG_WARN_ENRICH_AGENT_LOAD_FAILED="agent-failed"
        ok()   { echo "OK: $*"; }
        warn() { echo "WARN: $*"; }
        info() { echo "INFO: $*"; }
        legal_prevails_note() { :; }
        gui_read() { if [ -n "$ANSWER" ]; then printf "%s" "$ANSWER"; else printf "%s" "$3"; fi; }
        # shellcheck disable=SC1090
        source "$CONSENT"
        # shellcheck disable=SC1090
        source "$FUNC"
        # shellcheck disable=SC1090
        source "$TAIL"
        echo "RESULT_DONE"
    ' > "$WORK/$name/out" 2>&1
    local rc=$?
    sed 's/^/    /' "$WORK/$name/out" >&2
    [ "$rc" = 0 ] || echo "    (harness exit $rc)" >&2
    local plist="$home/Library/LaunchAgents/com.ostler.enrich.plist"
    local wrapper="$home/.ostler/bin/ostler-enrich-tick"
    # "installed" means a complete plist naming the label, and an executable
    # wrapper. A plist truncated by an expansion error does not count.
    if [ -f "$plist" ] && grep -q '<string>com.ostler.enrich</string>' "$plist" \
       && grep -q '</plist>' "$plist" && [ -x "$wrapper" ]; then echo installed; else echo absent; fi
}

got="$(run_case A_accepted_enter "")"
if [ "$got" = installed ]; then pass "A: accepted (Enter), 0 points, no exports -> agent installed"
else fail "A: accepted (Enter), 0 points, no exports -> expected installed, got $got"; fi

got="$(run_case B_declined_n "n")"
if [ "$got" = absent ] && grep -q 'INFO: Recurring enrichment agent not installed' "$WORK/B_declined_n/out"; then
    pass "B: declined (n), 0 points, no exports -> not installed, and the install says so"
else fail "B: declined (n) -> expected absent with the INFO line, got $got"; fi

got="$(run_case C_accepted_y "y")"
if [ "$got" = installed ]; then pass "C: accepted (explicit y), 0 points, no exports -> agent installed"
else fail "C: accepted (explicit y) -> expected installed, got $got"; fi

got="$(run_case D_accepted_no_tree "" absent)"
if grep -q 'INFO: enrichment engine not present at install; namespace left default' "$WORK/D_accepted_no_tree/out"; then
    pass "D: the absent engine is logged once, at install, with the namespace left default"
else fail "D: the absent engine was not logged as 'enrichment engine not present at install'"; fi
if [ "$got" = installed ]; then pass "D: accepted, CM019 tree absent -> still installs (no abort on the namespace read)"
else fail "D: accepted with no CM019 tree -> expected installed, got $got (the install would have aborted)"; fi

got="$(run_case F_present_no_match "" nomatch)"
if [ "$got" = installed ] && ! grep -q 'enrichment engine not present' "$WORK/F_present_no_match/out" \
   && ! grep -q 'could not read the enrichment namespace' "$WORK/F_present_no_match/out"; then
    pass "F: engine present with no namespace (grep 1) -> installed, and no 'engine not present' line"
else fail "F: engine present, no match -> expected installed with no engine-absent line, got $got"; fi

if [ "$status" = 0 ]; then echo "PASS: the agent installs on consent alone (A, C, D), and not on a decline (B)"; fi
exit $status
