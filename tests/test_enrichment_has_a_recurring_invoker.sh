#!/usr/bin/env bash
#
# test_enrichment_has_a_recurring_invoker.sh -- #747.
#
# WHAT THIS EXISTS TO STOP, MEASURED ON A SHIPPED BOX ON 2026-08-17.
#
# Enrichment had exactly one caller in the entire product: `enrich --all`
# inside bin/ostler-import, reached only when bin/ostler-scan-exports found
# a NEW data-export drop in ~/Downloads. Install-time hydration ran ingest
# and stopped. So on a Mac where nobody ever drops a GDPR export, enrichment
# had never run and never would, and the whole feature was unreachable while
# every one of its own unit tests passed.
#
# That is the ships-dark shape: a writer that works, is tested, is shipped,
# and is never called. The only defence is a gate on the WIRING, because no
# amount of testing the writer can detect that nothing invokes it.
#
# So these controls assert the CHAIN, one link at a time:
#   the installer defines an agent  ->  something CALLS that definition  ->
#   the plist recurs  ->  the wrapper reaches the enrichment CLI  ->
#   it is bounded  ->  the uninstaller knows the label
#
# Each link is proved red on its own axis at the end. A fixture that trips
# several checks at once proves nothing about any one of them.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INSTALL="$REPO/install.sh"
STRINGS="$REPO/install.sh.strings.en-GB.sh"

[ -r "$INSTALL" ] || { echo "CANNOT-RUN: no install.sh at $INSTALL"; exit 2; }
[ -r "$STRINGS" ] || { echo "CANNOT-RUN: no strings at $STRINGS"; exit 2; }

PASS=0; FAIL=0
TMP="$(mktemp -d -t enrichwire_XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
ok() { printf '  \033[0;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no() { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /'; FAIL=$((FAIL+1)); }

echo "test_enrichment_has_a_recurring_invoker (#747)"
echo

# --- the predicates, as functions, so the red proofs can re-run them
#     against a MUTATED COPY of the installer rather than against a
#     hand-written string. A predicate that is only ever run on the real
#     file has never been shown to distinguish anything.

# THE FUNCTION BODY IS NOT `start,/^}/`. That range looked obviously right
# and was wrong: the body embeds a shell wrapper in a heredoc, and that
# wrapper defines its own function, so the first column-zero `}` closes the
# WRAPPER's helper, 115 lines early. Three controls then measured a region
# that did not contain the thing they were asserting about, and reported the
# feature missing when it was present.
#
# The body runs to the first column-zero `}` AFTER the plist heredoc's
# terminator, which is a landmark inside this function and nowhere else.
body() {
    awk '
        /^_install_enrichment_agent\(\) \{/ { inbody = 1 }
        inbody                              { print }
        /^ENRPLIST$/                        { past_plist = 1 }
        inbody && past_plist && /^\}/       { exit }
    ' "$1"
}

# NEVER `grep -q` ON THE RIGHT OF A PIPE UNDER `pipefail`. `-q` exits at the
# first match and closes the pipe, the writer on the left takes SIGPIPE, and
# pipefail turns a SUCCESSFUL match into a non-zero status. That is exactly
# how p_called reported "defined but never invoked" against a tree where the
# call site was present and correct. Count with -c and compare instead: the
# reader consumes its whole input, so there is no signal to race.
has() { [ "$(grep -cE -- "$1" 2>/dev/null || true)" -gt 0 ]; }

p_defines()   { [ "$(grep -cE '^_install_enrichment_agent\(\) \{' "$1")" -gt 0 ]; }
p_called()    { [ "$(grep -vE '^[[:space:]]*#' "$1" | grep -cE '^[[:space:]]+_install_enrichment_agent[[:space:]]*$')" -gt 0 ]; }
p_recurs()    { [ "$(body "$1" | grep -cF '<key>StartInterval</key>')" -gt 0 ]; }
p_reaches()   { [ "$(body "$1" | grep -cE 'services\.enrich\.src\.cli')" -gt 0 ]; }
p_bounded()   { [ "$(body "$1" | grep -cF -- '--budget-seconds')" -gt 0 ]; }
p_uninstall() { [ "$(grep -cE '^[[:space:]]+com\.ostler\.enrich$' "$1")" -gt 0 ]; }

# 1. The installer defines the agent at all.
p_defines "$INSTALL" \
    && ok "install.sh defines _install_enrichment_agent" \
    || no "no enrichment agent installer in install.sh"

# 2. THE LINK THAT WAS MISSING FOR THE WHOLE PRODUCT'S LIFE. A definition
#    nothing calls is the exact defect this gate exists for, and a function
#    body is easy to review into existence while its call site is not.
#    Comment lines are stripped first: naming a function in a comment must
#    not count as invoking it (verify_test_wiring.sh has that very bug).
p_called "$INSTALL" \
    && ok "something actually CALLS it (not just defines it)" \
    || no "the agent installer is defined but never invoked -- dead code, enrichment still dark"

# 3. Recurring, not one-shot. A single pass cannot drain a backlog that is
#    rate-limited to one request per second, and new preferences arrive
#    for as long as the product is used.
p_recurs "$INSTALL" \
    && ok "the agent plist carries StartInterval, so it recurs" \
    || no "no StartInterval: this would fire once and never again"

# 4. The wrapper reaches the enrichment CLI. Without this the agent could
#    be perfectly scheduled and invoke nothing.
p_reaches "$INSTALL" \
    && ok "the wrapper invokes services.enrich.src.cli" \
    || no "the agent does not reach the enrichment CLI"

# 5. Bounded. An unbounded pass on a slow third party runs for hours
#    holding its lock, and the next interval finds it still running.
p_bounded "$INSTALL" \
    && ok "each slice is bounded by --budget-seconds" \
    || no "the pass is unbounded; a slow slice would overrun its own interval"

# 6. The uninstaller knows the label. An agent the uninstaller cannot see
#    keeps running after the customer removes the product, which is worse
#    than one that never ran.
p_uninstall "$INSTALL" \
    && ok "com.ostler.enrich is in the uninstall label list" \
    || no "the uninstaller does not know this label; the agent would survive uninstall"

# 7. Operator-facing strings exist for both outcomes.
if grep -q '^MSG_OK_ENRICH_AGENT_LOADED=' "$STRINGS" \
   && grep -q '^MSG_WARN_ENRICH_AGENT_LOAD_FAILED=' "$STRINGS"; then
    ok "both loaded/failed strings exist in the en-GB catalogue"
else
    no "missing MSG_OK_ENRICH_AGENT_LOADED or MSG_WARN_ENRICH_AGENT_LOAD_FAILED"
fi

# ---------------------------------------------------------------------------
# 8. BEHAVIOURAL. Extract the wrapper the installer writes and RUN it.
#
#    Everything above is structural, and structure is what you check when
#    you cannot run the thing. Here we can: the wrapper is a self-contained
#    script inside a single-quoted heredoc, so it can be lifted out verbatim
#    and executed against a directory with no preferences service in it.
#    That is the shape a machine in a partial-install state is actually in,
#    and it must exit 0 and SAY what it found rather than dying.
# ---------------------------------------------------------------------------
awk "/<<'ENRTICKEOF'/{f=1;next} /^ENRTICKEOF\$/{f=0} f" "$INSTALL" > "$TMP/wrapper.sh"
if [ ! -s "$TMP/wrapper.sh" ]; then
    no "could not extract the wrapper heredoc from install.sh" ""
else
    chmod +x "$TMP/wrapper.sh"
    if bash -n "$TMP/wrapper.sh" 2>"$TMP/synerr"; then
        ok "the wrapper the installer writes is syntactically valid bash"
    else
        no "the wrapper does not parse" "$(cat "$TMP/synerr")"
    fi

    mkdir -p "$TMP/fakehome/.ostler"
    rc=0
    OSTLER_DIR="$TMP/fakehome/.ostler" \
    OSTLER_CM019_DIR="$TMP/fakehome/.ostler/services/cm019" \
    OXIGRAPH_URL="http://127.0.0.1:1" \
        bash "$TMP/wrapper.sh" >"$TMP/out" 2>&1 || rc=$?
    logf="$TMP/fakehome/.ostler/logs/enrich.log"
    if [ "$rc" != 0 ]; then
        no "a box with no preferences service made the tick exit ${rc}; it must degrade, not die" "$(cat "$TMP/out")"
    elif [ ! -s "$logf" ]; then
        no "the tick exited 0 and wrote NOTHING; silence is indistinguishable from never running" ""
    elif ! grep -q 'nothing to enrich' "$logf"; then
        no "the tick logged, but did not say what it found" "$(cat "$logf")"
    else
        ok "with no preferences service: exits 0, and SAYS why, in its log"
    fi

    # 8b. The lock must actually exclude. A second pass overlapping the
    #     first would double our outbound rate to a third party we do not
    #     own. Held by hand here, because the real overlap is a race and a
    #     race is not a test.
    mkdir -p "$TMP/fakehome/.ostler/state/enrich.lock"
    rc=0
    OSTLER_DIR="$TMP/fakehome/.ostler" \
    OSTLER_CM019_DIR="$TMP/fakehome/.ostler/services/cm019" \
    OXIGRAPH_URL="http://127.0.0.1:1" \
        bash "$TMP/wrapper.sh" >"$TMP/out2" 2>&1 || rc=$?
    if [ "$rc" != 0 ]; then
        no "a held lock made the tick exit ${rc} instead of standing down" "$(cat "$TMP/out2")"
    elif ! grep -q 'standing down' "$logf"; then
        no "a held lock did not stop the second pass -- overlapping runs would double our outbound rate" "$(tail -3 "$logf")"
    else
        ok "a held lock makes a second pass stand down rather than overlap"
    fi
    rmdir "$TMP/fakehome/.ostler/state/enrich.lock" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 9. PROVE RED, ONE AXIS AT A TIME.
#
#    Each mutation breaks exactly one link and must fail exactly the control
#    that names it, and no fixture is shared between them. Without this the
#    six greens above are compatible with six predicates that cannot say no.
# ---------------------------------------------------------------------------
red() {  # red <name> <predicate-fn> <sed-program>
    local name="$1" pred="$2" prog="$3" copy="$TMP/mut-$$.sh"
    sed "$prog" "$INSTALL" > "$copy"
    if cmp -s "$copy" "$INSTALL"; then
        no "PROVE RED [$name]: the mutation changed nothing, so it tests nothing" ""
    elif "$pred" "$copy"; then
        no "PROVE RED [$name]: predicate still passed against a tree with the link removed" ""
    else
        ok "PROVED RED [$name]: removing that link alone turns its control red"
    fi
    rm -f "$copy"
}

red "call site"   p_called    '/^[[:space:]]*_install_enrichment_agent[[:space:]]*$/d'
red "recurrence"  p_recurs    '/<key>StartInterval<\/key>/d'
red "CLI reach"   p_reaches   's/services\.enrich\.src\.cli/services.NOTHING.cli/'
red "budget"      p_bounded   's/--budget-seconds/--no-such-flag/'
red "uninstall"   p_uninstall '/^[[:space:]]*com\.ostler\.enrich$/d'

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
echo "ALL #747 INVOKER CONTROLS PASSED"
