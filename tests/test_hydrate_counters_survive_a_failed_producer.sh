#!/usr/bin/env bash
# A count-the-JSON substitution must not abort the install (walk 11)
# =================================================================
#
# THE INPUT THIS TEST REPLAYS
#
# Walk 11, archie@192.168.1.240, v1.0.65 + #1439 staged. The install reached
# step 38 of 38 -- the deepest yet -- and then:
#
#     LOG level=error msg=Install aborted unexpectedly at line 25448 (step hydrate_graph)
#     STEP_END id=hydrate_graph status=error rc=1
#     DONE status=fail code=ERR-99-INSTALL-ABORT-L25448
#
# 25448 is a COMMENT. Under an ERR trap $LINENO reports the END of the
# enclosing compound command, not the failing simple command, so the reported
# line is never the one to read. MEASURED: a failing pipeline inside an
# unguarded command substitution reports the closing `)"`, eight lines below
# the command that failed.
#
# THE STATEMENT THAT ACTUALLY ABORTS
#
#     _HYDRATE_CONTACTS_COUNT="$(
#         printf '%s' "$_HYDRATE_CONTACTS_JSON" \
#         | python3 -c '...' 2>/dev/null
#     )"
#
# No `|| { ... }`. Under `set -Eeuo pipefail` a non-zero producer makes the
# whole substitution non-zero, `set -e` aborts, and `2>/dev/null` has already
# discarded the reason. The PRODUCER one statement above it (25399) IS
# guarded. The expensive call was defended and the arithmetic after it was not.
#
# WHAT THIS TEST IS NOT
#
# It is NOT a claim that this line caused walk 11 on its own. It is the second
# link. The first is a missing module (`contact_syncer.photo_storage`) which
# kills the syncer, so the guarded producer at 25399 correctly yields an empty
# JSON and this counter then aborts on it. That module is PR #1442 and is a
# separate defect with a separate fix. Guarding this line stops the abort; it
# imports nobody. Both are real and neither is sufficient.
#
# WHAT THIS TEST ASSERTS
#
#   A  ORIGINAL FAILING INPUT. The real statement, taken verbatim from
#      install.sh, with its producer forced to fail, must NOT abort.
#   B  POSITIVE CONTROL. The guarded sibling producer at the same site must
#      also survive. If A passes because the harness cannot detect an abort at
#      all, B would pass for the same wrong reason, so B alone is not enough --
#      see C.
#   C  NEGATIVE CONTROL, MUST ABORT. A synthetic unguarded substitution must
#      abort under the same harness. Without it, a harness that never aborts
#      would report the subject green while the defect is untouched.
#   D  THE CLASS. Ten sibling counters measured as aborting on 2026-09-04 are
#      listed by name. Each must survive. A fix applied to one line while its
#      nine twins stay armed is not a fix, it is a coincidence.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
fatal(){ printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || fatal "no install.sh at ${SUBJECT}"
_tmp="${TMPDIR:-/tmp}"; _tmp="${_tmp%/}"
WORK="$(mktemp -d "${_tmp}/hydcnt-XXXXXX")" || fatal "no working directory"
trap 'rm -rf "$WORK"' EXIT

# Extract a `VAR="$(` ... `)"` statement whose closing paren sits at the SAME
# indent as its opening line. Paren counting is wrong here: the embedded python
# contains `)` characters and a counter ends the statement early. Anchoring on
# indent is what made this measurable at all.
_extract() {
    awk -v want="$1" '
        index($0, want" =\"$(") || index($0, want"=\"$(") {
            ind = $0; sub(/[^ ].*$/, "", ind)
            print; getline
            while ($0 !~ "^" ind "\\)\"") { print; if (getline <= 0) exit 3 }
            print; exit 0
        }
    ' "$2"
}

# Run one extracted statement with its producer forced to fail. The statement
# is NEVER rewritten: only the producer is shadowed. Echoes the exit status.
_run_with_failing_producer() {
    local stmt="$1" producer="$2" f="${WORK}/probe.sh"
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf '%s() { return 1; }\n' "$producer"
        printf '%s\n' '_HYDRATE_CONTACTS_JSON=""'
        printf '%s\n' "$stmt"
    } > "$f"
    bash -n "$f" 2>/dev/null || { printf 'PARSEFAIL'; return; }
    bash "$f" >/dev/null 2>&1
    printf '%s' "$?"
}

# --- C first: the harness must be able to SEE an abort ----------------------
printf 'X="$(\n    false | cat\n)"\n' > "${WORK}/neg.sh"
{ printf '%s\n' 'set -Eeuo pipefail'; cat "${WORK}/neg.sh"; } > "${WORK}/neg_run.sh"
bash "${WORK}/neg_run.sh" >/dev/null 2>&1
NEG=$?
if [ "$NEG" -ne 0 ]; then
    ok "C  negative control aborts (rc=${NEG}) -- the harness can detect the defect"
else
    fatal "the negative control did NOT abort. This harness cannot see an abort, so every result below would be a false green."
fi

# --- A: the subject ---------------------------------------------------------
STMT="$(_extract _HYDRATE_CONTACTS_COUNT "$SUBJECT")" || fatal "could not extract _HYDRATE_CONTACTS_COUNT"
[ -n "$STMT" ] || fatal "extracted an empty statement for _HYDRATE_CONTACTS_COUNT"
printf '%s' "$STMT" | grep -q 'python3' || fatal "the extracted statement does not contain python3 -- extraction hit the wrong text"
RC_A="$(_run_with_failing_producer "$STMT" python3)"
if [ "$RC_A" = "PARSEFAIL" ]; then
    fatal "the extracted _HYDRATE_CONTACTS_COUNT statement does not parse in isolation"
elif [ "$RC_A" = "0" ]; then
    ok "A  _HYDRATE_CONTACTS_COUNT survives a failed producer"
else
    bad "A  _HYDRATE_CONTACTS_COUNT ABORTS (rc=${RC_A}) when its producer fails. This is the walk-11 abort."
fi

# --- B: the guarded sibling -------------------------------------------------
STMT_B="$(_extract _HYDRATE_CONTACTS_JSON "$SUBJECT")"
if [ -n "$STMT_B" ]; then
    RC_B="$(_run_with_failing_producer "$STMT_B" cd)"
    if [ "$RC_B" = "0" ]; then
        ok "B  positive control: the GUARDED producer at the same site survives"
    else
        bad "B  the guarded producer aborted (rc=${RC_B}) -- the harness or the guard has changed"
    fi
else
    bad "B  could not extract the guarded sibling _HYDRATE_CONTACTS_JSON"
fi

# --- D: the class -----------------------------------------------------------
# Measured 2026-09-04 by executing each statement with its producer shadowed:
# 23 multi-line candidates, 19 measured, 11 aborting. These are the ten
# siblings of the subject.
CLASS="_HYDRATE_CALENDAR_COUNT _HYDRATE_EMAIL_COUNTS _HYDRATE_WHATSAPP_JSON
_HYDRATE_WHATSAPP_COUNT _HYDRATE_BROWSING_SENT _HYDRATE_BROWSING_SKIPPED
_HYDRATE_IMESSAGE_COUNT _HYDRATE_PEOPLE_SENT _AICONV_COUNT"
D_BAD=""; D_SEEN=0
for v in $CLASS; do
    s="$(_extract "$v" "$SUBJECT")"
    [ -n "$s" ] || continue
    D_SEEN=$((D_SEEN+1))
    p="$(printf '%s' "$s" | sed -n '2p' | sed 's/^[[:space:]]*//; s/[[:space:]].*$//')"
    case "$p" in ''|*'$'*|*'"'*) p=python3 ;; esac
    r="$(_run_with_failing_producer "$s" "$p")"
    [ "$r" = "0" ] || D_BAD="${D_BAD} ${v}(rc=${r})"
done
[ "$D_SEEN" -ge 5 ] || fatal "only ${D_SEEN} class members extracted; the sweep is not reading install.sh"
if [ -z "$D_BAD" ]; then
    ok "D  class: ${D_SEEN} sibling counters all survive a failed producer"
else
    bad "D  class: these counters still ABORT:${D_BAD}"
fi

printf '\n'
printf 'CONCLUSION HISTOGRAM\n'
printf '  PASS : %d\n' "$PASS"
printf '  FAIL : %d\n' "$FAIL"
printf '  TOTAL: %d\n' "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
