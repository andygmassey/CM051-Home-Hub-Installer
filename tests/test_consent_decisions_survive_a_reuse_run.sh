#!/usr/bin/env bash
# "Use previous answers" must not silently revoke consent.
#
# WHY THIS EXISTS. MEASURED on Andy's Mini, 2026-09-04, on a box with a
# COMPLETE install: `ostler-consent show` returned null for every tickbox, and
# config/.env carried 21 keys of which ZERO were consent. Those two facts are
# one loop:
#
#   "Use previous answers"  ->  SKIP_PHASE2=true
#     ->  the question phase never runs
#     ->  OSTLER_CONSENT_*_DECISION stay EMPTY
#     ->  the Phase 3 recorder is guarded on non-empty, so it writes NOTHING
#     ->  nothing is persisted for the NEXT reuse run to restore
#
# Self-perpetuating: every reuse run starts from the state the previous reuse
# run failed to leave behind. The customer answered once and the answers
# evaporated, and the feeds those tickboxes gate stayed off with no record
# saying why. A wiped Mac restored from Time Machine hits this on its FIRST
# install, because the restored home already carries a config/.env, so the
# installer offers to reuse it.
#
# TWO HALVES, AND BOTH ARE TESTED HERE BY EXECUTION:
#   1. the writer puts every decision into config/.env, so a reuse run has
#      something to restore
#   2. a reuse run that finds a region-independent decision MISSING walks the
#      questions instead of skipping them
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run. A check that could not run has
# not passed.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── Extract the config/.env writer from a tree ────────────────────────────
_extract_env_writer() {
    awk '
        index($0, "cat > \"${CONFIG_DIR}/.env\" <<ENVEOF") { f=1 }
        f { print }
        f && /^ENVEOF$/ { exit }
    ' "$1"
}

# ── Extract the reuse-completeness guard from a tree ──────────────────────
# Located from its own marker outwards so a line-number change cannot rot it.
# Returns 2 when the guard is absent, which is what a pre-fix tree does.
_extract_reuse_guard() {
    local file="$1" m s e
    m="$(/usr/bin/grep -n '_missing_consent=""' "$file" | head -1 | cut -d: -f1)"
    [ -n "$m" ] || return 2
    s="$(awk -v m="$m" 'NR<m && /if \[\[ "\$SKIP_PHASE2" == "true" \]\]; then/{n=NR} END{print n}' "$file")"
    e="$(awk -v m="$m" 'NR>m && /unset _missing_consent/{print NR; exit}' "$file")"
    [ -n "$s" ] && [ -n "$e" ] || return 2
    # +1 to take the closing fi that follows the unset
    awk -v s="$s" -v e="$((e+1))" 'NR>=s && NR<=e' "$file"
}

# ── HALF 1: the writer emits every decision, and a decline survives ───────
echo "── half 1: config/.env carries the decisions ──"

_writer="$(_extract_env_writer "$SUBJECT")"
if [ -z "$_writer" ]; then
    echo "CANNOT-RUN: the config/.env writer was not found in ${SUBJECT}." >&2
    exit 2
fi

_run="${WORK}/w"; mkdir -p "$_run"
{
    printf '%s\n' 'set -u'
    printf 'CONFIG_DIR=%s\n' "$(printf '%q' "$_run")"
    printf '%s\n' 'USER_ID=u1 USER_NAME="Test User" USER_FIRST_NAME=Test'
    printf '%s\n' 'ASSISTANT_NAME=Aide USER_TZ=UTC COUNTRY_CODE=44'
    # The values below are deliberately MIXED. A writer that hardcoded
    # "accepted", or that dropped the declines, would pass a uniform fixture.
    printf '%s\n' 'OSTLER_CONSENT_ARTICLE_9_DECISION="accepted"'
    printf '%s\n' 'OSTLER_CONSENT_VOICE_EU_DECISION="declined"'
    printf '%s\n' 'OSTLER_CONSENT_THIRD_PARTY_DECISION="accepted"'
    printf '%s\n' 'OSTLER_CONSENT_SPOKEN_CAPTURE_DECISION="declined"'
    printf '%s\n' 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"'
    printf '%s\n' 'CHANNEL_WHATSAPP_CONSENT_ACCEPTED="false"'
    printf '%s\n' 'WA_CONSENT="n"'
    printf '%s\n' "$_writer"
} > "${_run}/render.sh"

if ! bash "${_run}/render.sh" >"${_run}/out.txt" 2>"${_run}/err.txt"; then
    echo "CANNOT-RUN: the extracted writer did not execute." >&2
    sed 's/^/    /' "${_run}/err.txt" >&2
    exit 2
fi
[ -s "${_run}/err.txt" ] && bad "the writer printed to stderr, which means something in it executed: $(head -1 "${_run}/err.txt")"

if [ ! -f "${_run}/.env" ]; then
    echo "CANNOT-RUN: the writer produced no .env." >&2
    exit 2
fi

_want="OSTLER_CONSENT_ARTICLE_9_DECISION OSTLER_CONSENT_VOICE_EU_DECISION
       OSTLER_CONSENT_THIRD_PARTY_DECISION OSTLER_CONSENT_SPOKEN_CAPTURE_DECISION
       OSTLER_CONSENT_ENRICHMENT_DECISION CHANNEL_WHATSAPP_CONSENT_ACCEPTED WA_CONSENT"
_absent=""
for _k in $_want; do
    /usr/bin/grep -q "^${_k}=" "${_run}/.env" || _absent="${_absent} ${_k}"
done
if [ -z "$_absent" ]; then
    ok "every consent decision is written to config/.env, so a reuse run has something to restore"
else
    bad "config/.env omits:${_absent} -- a reuse run cannot restore what was never written"
fi

# THE ROUND TRIP, which is the property, not the presence of the keys.
# Read the file back exactly as the reuse path does.
_rt="$( set -a; . "${_run}/.env" >/dev/null 2>&1; set +a
        printf '%s|%s|%s|%s' \
          "${OSTLER_CONSENT_THIRD_PARTY_DECISION:-UNSET}" \
          "${OSTLER_CONSENT_SPOKEN_CAPTURE_DECISION:-UNSET}" \
          "${OSTLER_CONSENT_VOICE_EU_DECISION:-UNSET}" \
          "${WA_CONSENT:-UNSET}" )"
case "$_rt" in
    "accepted|declined|declined|n")
        ok "round trip: an accept restores as accepted and a DECLINE restores as declined, not defaulted" ;;
    *)
        bad "round trip returned '${_rt}', expected 'accepted|declined|declined|n'. A decline that does not survive is a consent the product invents." ;;
esac

# ── HALF 2: a reuse run missing a decision walks the questions ────────────
echo "── half 2: reuse refuses to skip when there is nothing to reuse ──"

_guard="$(_extract_reuse_guard "$SUBJECT")"; _grc=$?
if [ "$_grc" -ne 0 ] || [ -z "$_guard" ]; then
    echo "CANNOT-RUN: the reuse-completeness guard was not found in ${SUBJECT}." >&2
    exit 2
fi

# Runs the guard with a given environment; echoes the resulting SKIP_PHASE2.
_guard_result() {
    local g="${WORK}/g"; rm -rf "$g"; mkdir -p "$g"
    {
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' 'warn() { :; }'
        printf '%s\n' 'SKIP_PHASE2=true'
        while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
        printf '%s\n' "$_guard"
        printf '%s\n' 'printf "%s" "$SKIP_PHASE2"'
    } > "${g}/run.sh"
    bash "${g}/run.sh" 2>/dev/null
}

_r="$(_guard_result 'OSTLER_CONSENT_THIRD_PARTY_DECISION="accepted"' 'OSTLER_CONSENT_SPOKEN_CAPTURE_DECISION="declined"')"
[ "$_r" = "true" ] \
    && ok "a COMPLETE previous answer set still reuses, so nobody is re-asked for nothing" \
    || bad "a complete answer set was forced back through the questions (SKIP_PHASE2=${_r}). The guard is too wide."

_r="$(_guard_result 'OSTLER_CONSENT_THIRD_PARTY_DECISION=""' 'OSTLER_CONSENT_SPOKEN_CAPTURE_DECISION="declined"')"
[ "$_r" = "false" ] \
    && ok "a MISSING third-party decision forces the questions instead of skipping them" \
    || bad "a missing third-party decision still skipped the questions (SKIP_PHASE2=${_r}). This is the measured defect."

_r="$(_guard_result 'OSTLER_CONSENT_THIRD_PARTY_DECISION="accepted"' 'OSTLER_CONSENT_SPOKEN_CAPTURE_DECISION=""')"
[ "$_r" = "false" ] \
    && ok "a MISSING spoken-capture decision forces the questions too" \
    || bad "a missing spoken-capture decision still skipped the questions (SKIP_PHASE2=${_r})"

# CONTROL ON THE WIDTH OF THE GUARD. The EU-only decisions are absent on every
# non-EU install, which is CORRECT. If their absence forced a re-walk, every
# install outside the EU would re-ask its questions forever, and this test
# would have shipped that.
_r="$(_guard_result 'OSTLER_CONSENT_THIRD_PARTY_DECISION="accepted"' 'OSTLER_CONSENT_SPOKEN_CAPTURE_DECISION="accepted"' 'OSTLER_CONSENT_ARTICLE_9_DECISION=""' 'OSTLER_CONSENT_VOICE_EU_DECISION=""')"
[ "$_r" = "true" ] \
    && ok "CONTROL: absent EU-only decisions do NOT force a re-walk on a non-EU box" \
    || bad "CONTROL FAILED: an absent EU-only decision forced a re-walk (SKIP_PHASE2=${_r}). Every non-EU install would re-ask forever."

# ── NEGATIVE CONTROL, pinned to a tree that CARRIES the defect ────────────
# Pinned to a fixed sha, never a moving branch: a control reading origin/main
# inverts the moment this fix merges and then passes forever. 7b2130ac is the
# v1.0.65 cut -- the tree Andy's box was measured against.
_CONTROL_SHA="7b2130ac"
echo "── negative control: ${_CONTROL_SHA} (the tree with the empty registry) ──"
_ctl="${WORK}/control.sh"
if ! git -C "$REPO" cat-file -e "${_CONTROL_SHA}:install.sh" 2>/dev/null; then
    git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
fi
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$_ctl" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    echo "  A shallow clone cannot see it. Scanning nothing must not read as a" >&2
    echo "  passing control." >&2
    exit 2
fi

_cw="$(_extract_env_writer "$_ctl")"
if [ -z "$_cw" ]; then
    echo "CANNOT-RUN: the writer was not found in the control blob." >&2
    exit 2
fi
_cn="$(printf '%s' "$_cw" | /usr/bin/grep -cE '^(OSTLER_CONSENT_|WA_CONSENT=|CHANNEL_WHATSAPP_CONSENT_ACCEPTED=)')"
[ "$_cn" -eq 0 ] \
    && ok "control ${_CONTROL_SHA}: its writer emits 0 consent keys, which is why the registry was null" \
    || bad "control ${_CONTROL_SHA}: its writer emits ${_cn} consent key(s). It did not, so the extraction is measuring the wrong tree."

# And the same extraction against the SUBJECT must be non-zero, or the count
# above proves nothing about the fix -- only that the predicate found nothing.
_sn="$(printf '%s' "$_writer" | /usr/bin/grep -cE '^(OSTLER_CONSENT_|WA_CONSENT=|CHANNEL_WHATSAPP_CONSENT_ACCEPTED=)')"
[ "$_sn" -gt 0 ] \
    && ok "CONTROL ON THE PREDICATE: the same count over this tree returns ${_sn}, so the control's 0 is a measurement" \
    || bad "the predicate returns 0 on BOTH trees, so it is measuring nothing"

_extract_reuse_guard "$_ctl" >/dev/null 2>&1
[ $? -eq 2 ] \
    && ok "control ${_CONTROL_SHA}: has no reuse-completeness guard at all, as expected" \
    || bad "control ${_CONTROL_SHA}: a reuse-completeness guard was found in the pre-fix tree"

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
