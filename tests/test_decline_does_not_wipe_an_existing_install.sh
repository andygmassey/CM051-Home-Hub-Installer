#!/usr/bin/env bash
# Declining a consent question must not destroy an install that was already
# there, and must not claim it destroyed nothing when it did.
#
# FOUND BY TNM, 2026-09-04, BY EXECUTION. He pinned the wipe target at a
# seeded tree, ran the decline arm, and counted survivors:
#
#     seeded    <tmp>/dot-ostler/config/.env
#               <tmp>/dot-ostler/graph/store.nq
#               <tmp>/dot-ostler/conversations/2026.md
#     after     the directory IS GONE -- 3 seeded files destroyed
#     printed   "Nothing has been installed and nothing was written to your Mac."
#
# On a FRESH install that arm is right: Phase 2 wrote a contacts export, wipe
# it, and the sentence is true. On a RE-INSTALL it takes the graph, the
# vectors, the conversations and the config, and then says nothing was
# written.
#
# CM051 #1431 did not create the arm and did not create its reachability --
# declining the reuse prompt has always walked the questions on a populated
# box. What it changed is WHO CHOOSES: the installer now sets
# SKIP_PHASE2=false on the customer's behalf on the most common re-install
# path. Involuntary entry into a destructive arm is a different risk from
# voluntary entry.
#
# THIS TEST IS AN EXECUTION, NOT A PATTERN, and deliberately so: TNM's finding
# was an execution and a grep would not have found it. It seeds a directory,
# runs the real arm, and counts what survives.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── Extract a decline arm from a tree ────────────────────────────────────
# $2 selects which: the Article 9 arm is the FIRST occurrence, the
# third-party arm the SECOND. Both end at their `exit 0`.
_extract_arm() {
    local file="$1" which="$2"
    awk -v want="$which" '
        /_CONSENT_ARTICLE_9_DECISION="declined"|_CONSENT_THIRD_PARTY_DECISION="declined"/ { n++; if (n == want) f = 1 }
        f { print }
        f && /^[[:space:]]*exit 0$/ { exit }
    ' "$file"
}

# Runs one arm against a SEEDED directory. Echoes "<survivors>|<said_nothing_written>".
_run_arm() {
    local file="$1" which="$2" preexisted="$3"
    local r="${WORK}/r"; rm -rf "$r"; mkdir -p "$r/dot-ostler/config" "$r/dot-ostler/graph" "$r/dot-ostler/conversations"
    printf 'USER_ID=u1\n'      > "$r/dot-ostler/config/.env"
    printf '<a> <b> <c> .\n'   > "$r/dot-ostler/graph/store.nq"
    printf '# a conversation\n' > "$r/dot-ostler/conversations/2026.md"

    local arm; arm="$(_extract_arm "$file" "$which")"
    [ -n "$arm" ] || { printf 'NOARM|'; return; }

    {
        printf '%s\n' 'set -uo pipefail'
        printf '%s\n' 'gui_cancelled() { :; }'
        printf 'OSTLER_DIR=%s\n' "$(printf '%q' "$r/dot-ostler")"
        printf '_OSTLER_FINAL_PREEXISTED=%s\n' "$preexisted"
        printf '%s\n' "$arm"
    } > "${r}/run.sh"
    local out
    out="$(bash "${r}/run.sh" 2>/dev/null)"

    local n; n=$(find "$r/dot-ostler" -type f 2>/dev/null | wc -l | tr -d ' ')
    local said=no
    case "$out" in *"nothing was"*"written to your Mac"*) said=yes ;; esac
    printf '%s|%s' "${n:-0}" "$said"
}

echo "── subject: this tree ──"

for _w in 1 2; do
    _name="Article 9"; [ "$_w" = 2 ] && _name="third-party"
    _r="$(_run_arm "$SUBJECT" "$_w" true)"
    case "$_r" in
        NOARM*)  echo "CANNOT-RUN: the ${_name} decline arm was not found in ${SUBJECT}." >&2; exit 2 ;;
        "3|no")  ok "${_name}: on a PRE-EXISTING install all 3 seeded files survive, and it does not claim nothing was written" ;;
        "3|yes") bad "${_name}: files survived but it STILL says 'nothing was written to your Mac'. The data is safe and the sentence is a lie." ;;
        *\|*)    bad "${_name}: on a pre-existing install only ${_r%%|*} of 3 seeded files survived. This is the data-loss defect." ;;
    esac
done

# CONTROL ON THE GUARD'S WIDTH. On a FRESH install the wipe is correct and the
# sentence is true. Without this limb, a change that simply deleted both wipes
# would pass everything above.
for _w in 1 2; do
    _name="Article 9"; [ "$_w" = 2 ] && _name="third-party"
    _r="$(_run_arm "$SUBJECT" "$_w" false)"
    case "$_r" in
        "0|yes") ok "CONTROL ${_name}: on a FRESH install it still wipes this run's residue and the sentence is true" ;;
        "0|no")  bad "CONTROL ${_name}: it wiped, but no longer says nothing was written. On a fresh install that sentence is correct and should stay." ;;
        *)       bad "CONTROL ${_name}: a fresh install left ${_r%%|*} file(s) behind. The wipe has been disabled outright, not made to discriminate." ;;
    esac
done

# ── NEGATIVE CONTROL, pinned to the tree TNM executed against ────────────
# dc6b5cd3 is main at the time of his review -- the tree whose arm he ran with
# a seeded target and watched destroy three files.
# ── the FLAG ITSELF, which every arm above takes as an input ──────────────
#
# 🔴 THE GAP THIS CLOSES, and it is in this file's own construction. Every arm
# above is driven through `_run_arm`, which INJECTS the flag:
#
#     printf '_OSTLER_FINAL_PREEXISTED=%s\n' "$preexisted"
#
# and `_extract_arm` pulls only from the decline decision down to `exit 0`. So
# the arms prove the ARM HONOURS the flag. Nothing here proved the flag is
# COMPUTED, and the computation is the half that decides whether a customer's
# install is wiped.
#
# MEASURED 2026-09-05: deleting the guard line from install.sh entirely, and
# separately pinning it to `true`, both left this file at 5 pass / 0 fail. Two
# mutations that restore the original destructive behaviour, and the gate
# protecting a destructive path could not see either.
#
# So this arm executes the REAL computation out of the REAL install.sh against
# a directory that exists and one that does not.
_flag_block="$(grep -n -A1 '^_OSTLER_FINAL_PREEXISTED=false$' "$SUBJECT" | sed 's/^[0-9]*[-:]//')"
if [ -z "$_flag_block" ]; then
    bad "the flag computation is absent from install.sh entirely -- the decline arms are reading an unset variable"
else
    _probe() {   # $1 = a path; echoes the computed flag
        ( set -u
          OSTLER_FINAL_DIR="$1"
          eval "$_flag_block"
          printf '%s' "${_OSTLER_FINAL_PREEXISTED:-<unset>}" )
    }
    _exists="${WORK}/seeded_dir"; mkdir -p "$_exists"
    _absent="${WORK}/no_such_dir_$$"; rm -rf "$_absent"
    _t="$(_probe "$_exists")"
    _f="$(_probe "$_absent")"
    if [ "$_t" = "true" ] && [ "$_f" = "false" ]; then
        ok "the flag is COMPUTED from the real tree: true when the install dir exists, false when it does not"
    else
        bad "the flag does not discriminate: existing dir gave '${_t}', absent dir gave '${_f}' (want true / false)"
    fi
    # MUST-MISS. If the guard line is gone, the block collapses to a constant
    # and the arm above must not still read true/false by luck.
    _mutant="$(printf '%s\n' "$_flag_block" | grep -v 'OSTLER_FINAL_DIR')"
    _m="$( ( set -u; OSTLER_FINAL_DIR="$_exists"; eval "$_mutant"; printf '%s' "${_OSTLER_FINAL_PREEXISTED:-<unset>}" ) )"
    if [ "$_m" = "true" ]; then
        bad "must-miss: with the directory test removed the flag STILL reads true, so this arm cannot see the guard being deleted"
    else
        ok "must-miss: with the directory test removed the flag stops discriminating (reads '${_m}')"
    fi
fi

_CONTROL_SHA="dc6b5cd3"
echo "── negative control: ${_CONTROL_SHA} (the tree TNM executed) ──"
_ctl="${WORK}/control.sh"
if ! git -C "$REPO" cat-file -e "${_CONTROL_SHA}:install.sh" 2>/dev/null; then
    git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
fi
if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$_ctl" 2>/dev/null; then
    echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
    exit 2
fi

_r="$(_run_arm "$_ctl" 2 true)"
case "$_r" in
    NOARM*)  echo "CANNOT-RUN: the arm was not found in the control blob." >&2; exit 2 ;;
    "0|yes") ok "control ${_CONTROL_SHA}: destroys all 3 seeded files AND says nothing was written -- TNM's measurement reproduced exactly" ;;
    "3|"*)   bad "control ${_CONTROL_SHA}: the files survived there too, so this harness is not measuring what TNM measured" ;;
    *)       bad "control ${_CONTROL_SHA}: unexpected result '${_r}'" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
