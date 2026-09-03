#!/usr/bin/env bash
#
# tests/test_qdrant_readiness_tests_the_authenticated_surface.sh
#
# #566 -- THE READINESS LOOP'S CREDENTIALED ARM WAS DEAD CODE, AND THAT IS WHY
# ERR-06 KILLED EVERY FRESH INSTALL.
#
# THE DEFECT, as it stood on origin/main 48ac63af:
#
#     if curl -sf -m 2 .../readyz &>/dev/null \
#        || curl <credentialed> -sf -m 2 .../collections &>/dev/null; then
#         _qdrant_ready=true
#
# `A || B` evaluates B ONLY when A fails. `/readyz` answers 200 with NO
# credential -- recorded in install.sh's own comment and re-measured
# independently by @A2 on 2026-08-29 against the pinned image (qdrant v1.12.1,
# QDRANT__SERVICE__API_KEY set): readyz bare 200 / collections bare 401 /
# collections api-key 200 / collections WRONG key 401, that last one being his
# sole-tenancy control. So arm 1 always won and ARM 2 NEVER EXECUTED.
#
# WHY THAT WAS FATAL, which is the whole point:
#
#     store never arrives -> not ready -> block skipped -> install CONTINUES
#     store arrives, 401s -> "ready" via the BARE arm -> fail_with_code -> exit 1
#
# A dead store was survivable; an almost-ready one was fatal. Backwards at any
# window size INCLUDING ZERO -- which is why @ARCHIE's readiness-race
# measurements (delta 0.00s warm AND cold) could refute a race and still leave
# the failure unexplained. The asymmetry was never about a window.
#
# ⚠️ WHAT THIS TEST DOES NOT ASSERT. It does not claim the 401 is explained.
# It is not a #566 closure. The abort goes away; the reason a credentialed
# /collections returns 401 at t+4s on a real box is a SEPARATE, OPEN question
# and it has its own row. A test that implied otherwise would be the same
# over-claim this whole class of defect is made of.
#
# SHAPE, and why each arm is built the way it is:
#   arm 1  the readiness criterion CARRIES the credential
#   arm 2  no bare-arm short-circuit survives -- THE RED ARM against main
#   arm 3  the self-termination is gone, but the greppable CODE is not
#   arm 4  the diagnostic carries all five facts, by NAME
#   arm 5  ⛔ and it can never carry a credential VALUE
#   arm 6  MUTATION: the pinned pre-fix loop must FAIL arm 2
#
# Arm 6 is PINNED, NOT DERIVED. A baseline computed from the file under test
# moves when the file moves and then proves nothing (learned the hard way on
# CM051 #886 and #904).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# INSTALL_SCRIPT is env-overridable ONLY so this gate can be exercised against a
# fixture install.sh (e.g. one with a line inserted in the readiness loop, to
# prove the region extraction is robust to line drift -- #631). Unset in CI, it
# resolves to the real repo install.sh, unchanged.
INSTALL_SCRIPT="${OSTLER_TEST_INSTALL_SCRIPT:-${REPO_ROOT}/install.sh}"

pass=0; fail=0
ok()   { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
cannot_run() {
    printf '  CANNOT-RUN  %s\n' "$*" >&2
    printf 'This is neither a pass nor a failure. The check could not be made.\n' >&2
    exit 2
}

[ -f "$INSTALL_SCRIPT" ] || cannot_run "install.sh not found at ${INSTALL_SCRIPT}"

# ── LOCATE THE LOOP BY ANCHOR, NEVER BY LINE NUMBER ─────────────────────────
# `_qdrant_ready=false` is the loop's own initialiser and is unique. A line
# number would rot on the next edit above it, and an `^`-anchored pattern would
# score zero on an indented copy -- both mistakes already made in this repo.
n_anchor="$(grep -cE '^_qdrant_ready=false$' "$INSTALL_SCRIPT")"
if [ "$n_anchor" -eq 0 ]; then
    cannot_run "no '_qdrant_ready=false' anchor in install.sh; the loop was renamed or removed. No verdict available."
elif [ "$n_anchor" -gt 1 ]; then
    cannot_run "'_qdrant_ready=false' appears ${n_anchor} times; the region is ambiguous. Refusing to guess which loop is the subject."
fi
start_line="$(grep -nE '^_qdrant_ready=false$' "$INSTALL_SCRIPT" | cut -d: -f1)"
# Extract the loop by its STRUCTURAL end -- the first `^done$` after the
# initialiser -- not by an arbitrary line window. The old `NR<=s+70` cap was
# a proxy for "the loop is short"; the loop is 79 lines, so the cap already
# truncated it (blind to the status check and `done`) and left ARM 1's
# credential anchor one inserted line from falling out of the window, a false
# RED on any PR that touched the region (#631). `done` is the terminator the
# code already searched for; anchor on it directly.
LOOP="$(awk -v s="$start_line" 'NR>=s{print; if (/^done$/) exit}' "$INSTALL_SCRIPT")"
if [ "$(printf '%s\n' "$LOOP" | tail -1)" != "done" ]; then
    cannot_run "no 'done' closes the readiness loop after line ${start_line}; its terminator was renamed or removed. Refusing to judge a region with no end."
fi

if [ "$(printf '%s\n' "$LOOP" | grep -cF '/collections')" -eq 0 ]; then
    cannot_run "the extracted readiness region does not mention /collections; wrong region."
fi
ok "CANNOT-RUN checks: the readiness loop anchor is unique and the region is the right one"

# ── ARM 1: THE READINESS CRITERION CARRIES THE CREDENTIAL ───────────────────
# Strip comments first. This file DESCRIBES the old `||` form in prose several
# times; a raw grep would score my own explanation as the defect. Count
# INVOCATIONS, never mentions.
LOOP_CODE="$(printf '%s\n' "$LOOP" | grep -vE '^[[:space:]]*#')"
n_cred="$(printf '%s\n' "$LOOP_CODE" | grep -cF '_OSTLER_STORE_CURL_ARGS')"
if [ "$n_cred" -ge 1 ]; then
    ok "ARM 1 the readiness probe CARRIES the credential (${n_cred} credentialed call(s) in the loop body)"
else
    bad "ARM 1 the readiness loop makes NO credentialed call. Readiness would again be
      decided by a surface that cannot observe an auth failure, which is the
      exact defect this test exists to prevent."
fi

# ── ARM 2: NO BARE-ARM SHORT-CIRCUIT. THIS IS THE RED ARM. ──────────────────
# The defect is not "the word readyz appears". It is a bare (uncredentialed)
# readyz call that can SATISFY the loop on its own -- i.e. one joined by `||`
# to the credentialed call. That is the shape to forbid, so that is what is
# matched: a readyz curl line ending in a `||` continuation.
n_shortcircuit="$(printf '%s\n' "$LOOP_CODE" \
    | grep -cE 'curl[^|]*readyz[^|]*(\|\||\\[[:space:]]*$)')"
if [ "$n_shortcircuit" -eq 0 ]; then
    ok "ARM 2 no bare readyz arm can satisfy readiness on its own (0 short-circuit forms)"
else
    bad "ARM 2 A BARE readyz ARM CAN STILL END THE LOOP (${n_shortcircuit} found).
      /readyz answers 200 with no credential, so this arm always wins and the
      credentialed arm beside it never executes. Readiness would be satisfied
      by a probe weaker than what the next statement depends on -- and a store
      that 401s would be declared ready, then killed by the code below."
fi

# ── ARM 3: THE SELF-TERMINATION IS GONE, THE GREPPABLE CODE IS NOT ──────────
n_fatal="$(grep -cE '^[[:space:]]*fail_with_code "ERR-06-STORE-AUTH-LEAK"' "$INSTALL_SCRIPT")"
n_token="$(grep -cF 'ERR-06-STORE-AUTH-LEAK' "$INSTALL_SCRIPT")"
if [ "$n_fatal" -eq 0 ] && [ "$n_token" -ge 1 ]; then
    ok "ARM 3 no self-termination on ERR-06 (0 fail_with_code) and the code survives for support greps (${n_token} mentions)"
elif [ "$n_fatal" -ne 0 ]; then
    bad "ARM 3 install.sh still EXITS on ERR-06 (${n_fatal} fail_with_code call(s)).
      A store that cannot serve its authenticated surface must land in the same
      warn-and-continue branch as a store that never arrived: they are the same
      fact about usability."
else
    bad "ARM 3 the ERR-06-STORE-AUTH-LEAK token has been deleted entirely.
      Customers have already sent us install logs containing it and it appears
      in live traces. Keep the code as a greppable identifier; only the exit
      was supposed to go."
fi

# ── ARM 4: THE DIAGNOSTIC CARRIES ALL FIVE FACTS ────────────────────────────
# Named, not counted: a count would pass on five copies of one fact.
DIAG="$(grep -F 'ERR-06-STORE-AUTH-LEAK diagnostic' "$INSTALL_SCRIPT" || printf '')"
if [ -z "$DIAG" ]; then
    bad "ARM 4 there is no ERR-06 diagnostic line at all. Making the abort
      non-fatal without instrumenting it converts a loud wrong failure into a
      quiet wrong success -- strictly worse than the defect."
else
    missing=""
    for _f in 'status=' 'headers_sent=' 'waited=' 'conf=' 'conf_written=' 'qdrant_started_at='; do
        if [ "$(printf '%s\n' "$DIAG" | grep -cF -- "$_f")" -eq 0 ]; then
            missing="${missing} ${_f}"
        fi
    done
    if [ -z "$missing" ]; then
        ok "ARM 4 the diagnostic names all six facts (status, headers_sent, waited, conf, conf_written, qdrant_started_at)"
    else
        bad "ARM 4 the diagnostic omits:${missing}
      Each of these killed or could have killed one of the three mechanisms
      proposed and retracted on 2026-08-29. A warn that says only 'it failed'
      leaves the next reader exactly where we were."
    fi
fi

# ── ARM 5: ⛔ THE DIAGNOSTIC CAN NEVER CARRY A CREDENTIAL VALUE ─────────────
# CM051 is a PUBLIC repo and this string lands in logs customers e-mail us.
# Two independent guards: the emitted line must not interpolate any secret
# variable, and the extractor must be a NAME-only capture.
leaked=0
for _v in '_tok' '_key' 'OXIGRAPH_TOKEN' 'QDRANT_API_KEY' 'oxigraph_token'; do
    if [ "$(printf '%s\n' "$DIAG" | grep -cF -- "$_v")" -gt 0 ]; then
        bad "ARM 5 ⛔ THE DIAGNOSTIC INTERPOLATES '${_v}'. That is a credential value
      on a public-repo code path, into a customer-shipped log. Header NAMES only."
        leaked=$((leaked+1))
    fi
done
# ⚠️ MATCHED AS TWO BACKSLASH-FREE SUBSTRINGS ON ONE LINE, DELIBERATELY.
# My first attempt embedded the whole sed expression in a `grep -F` pattern
# and the backslashes did not survive the shell quoting, so the arm scored 0
# against a file that plainly contains the extractor -- a predicate failure
# reading as a defect. Neither substring below contains a backslash, so there
# is nothing left to mis-quote.
n_name_only="$(grep -F "sed -n 's/^header = \"" "$INSTALL_SCRIPT" | grep -cF '[A-Za-z0-9-]')"
if [ "$leaked" -eq 0 ] && [ "$n_name_only" -ge 1 ]; then
    ok "ARM 5 no credential variable reaches the diagnostic, and the header extractor is a name-only capture class"
elif [ "$leaked" -eq 0 ]; then
    bad "ARM 5 no secret variable is interpolated (good) but the name-only header
      extractor is missing or was reworded. A capture group wider than
      [A-Za-z0-9-] before the ':' could pull a value into the log."
fi

# ── ARM 6: MUTATION -- THE PINNED PRE-FIX LOOP MUST FAIL ARM 2 ──────────────
# Without this, arm 2 could be a predicate that never fires and its green would
# mean nothing. PINNED verbatim from origin/main 48ac63af.
read -r -d '' PRE_FIX_LOOP <<'PINNED' || true
    if curl -sf -m 2 "${_qdrant_url}/readyz" &>/dev/null \
       || curl "${_OSTLER_STORE_CURL_ARGS[@]+"${_OSTLER_STORE_CURL_ARGS[@]}"}" -sf -m 2 "${_qdrant_url}/collections" &>/dev/null; then
        _qdrant_ready=true
        break
    fi
PINNED
n_mut="$(printf '%s\n' "$PRE_FIX_LOOP" \
    | grep -cE 'curl[^|]*readyz[^|]*(\|\||\\[[:space:]]*$)')"
if [ "$n_mut" -ge 1 ]; then
    ok "ARM 6 MUTATION -> the pinned pre-fix loop trips arm 2 (${n_mut} short-circuit form(s)); arm 2 discriminates"
else
    bad "ARM 6 MUTATION -> the PINNED PRE-FIX loop does NOT trip arm 2, so arm 2's
      green proves nothing: either the fixture has drifted from what actually
      shipped, or the predicate cannot match the defect it names."
fi

# ── ARM 7: ROBUSTNESS -- A LINE INSERTED IN THE LOOP MUST NOT CHANGE THE VERDICT ──
# The region used to be extracted by a fixed `s+70` window (#631). The loop is
# 79 lines, so the window already truncated it and ARM 1's credential anchor sat
# one inserted line from falling out -- a comment added anywhere in the region
# turned this gate RED on a PR that never touched readiness. The fix anchors the
# region on the loop's own `done`. This proves it: re-run the gate against a copy
# of install.sh with ONE comment inserted inside the loop; the verdict must not
# move. Skipped when INSTALL_SCRIPT is already overridden, so the child does not
# recurse into this arm.
if [ -z "${OSTLER_TEST_INSTALL_SCRIPT:-}" ]; then
    _rb_start="$(grep -nE '^_qdrant_ready=false$' "$INSTALL_SCRIPT" | cut -d: -f1)"
    _rb_tmp="$(mktemp "${TMPDIR:-/tmp}/readiness-shift-XXXXXX")"
    awk -v s="$_rb_start" 'NR==s+1{print "    # #631 robustness probe: a line inserted inside the readiness loop"} {print}' \
        "$INSTALL_SCRIPT" > "$_rb_tmp"
    if OSTLER_TEST_INSTALL_SCRIPT="$_rb_tmp" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
        ok "ARM 7 ROBUSTNESS -> a line inserted in the loop does not change the verdict (region tracks its own 'done', not a window)"
    else
        bad "ARM 7 ROBUSTNESS -> inserting one line in the readiness loop changed the
      verdict. The region extraction is drifting with line numbers again -- the
      exact #631 tripwire. Anchor the region on the loop's 'done', not a window."
    fi
    rm -f "$_rb_tmp"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
