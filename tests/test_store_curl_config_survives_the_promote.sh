#!/usr/bin/env bash
# tests/test_store_curl_config_survives_the_promote.sh
# ============================================================================
# THE DEFECT, measured on the v1.0.78 walk. _ostler_write_store_curl_config
# captures the credential path BY VALUE:
#
#     local _conf="${OSTLER_DIR}/secrets/store-curl.conf"     (:7574)
#     _OSTLER_STORE_CURL_ARGS=( -K "$_conf" )                 (:7619)
#
# and it is called at :13179 while _ostler_set_paths still has OSTLER_DIR bound
# to the /tmp/ostler-prelaunch-<pid> staging tree (:2504). Promote then rm -rf's
# staging and rebinds OSTLER_DIR to ~/.ostler. From that moment the armed array
# holds -K <a path that no longer exists>, so every credentialed curl exits 26
# BEFORE issuing a request, the caller reads status 000, and it looks exactly
# like a dead store. On the walk: ZERO GET /collections reached the wire while
# the proxy served 9971 x 200.
#
# THE FILE MOVES, THE VALUE DOES NOT. install.sh documents this class at
# :13913-13928 about the WhatsApp session path, naming #177 (the two ollama
# LaunchAgents) as the same root cause one file over. This is a third instance,
# and this test pins the instance. The class stays open on purpose.
#
# WHAT IS ASSERTED, behaviourally rather than textually: arm the array against a
# staging tree, promote it (move the tree, delete staging), run the shipped
# re-arm region, and require the array to point at a credential that EXISTS.
# The must-fail arm skips the re-arm and requires the array to be left pointing
# at the deleted path, because a region that would pass without doing the work
# is not evidence that the work happens.
#
# NO PIPE INTO grep -q ANYWHERE: that construct SIGPIPEs its producer and under
# `set -o pipefail` reports failure for a pattern it found. Counted form only.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="$REPO/install.sh"

PASS=0
FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; shift; [ $# -gt 0 ] && printf '%s\n' "$*" | sed 's/^/         /'; FAIL=$((FAIL + 1)); }

[ -r "$SRC" ] || { printf 'CANNOT-RUN: no install.sh at %s\n' "$SRC"; exit 78; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf 'THE STORE CREDENTIAL SURVIVES THE PROMOTE\n\n'

# ---------------------------------------------------------------------------
# Extract the shipped re-arm region, so this cannot pass against logic that
# exists only in the test.
# ---------------------------------------------------------------------------
region="$(awk '
    /^    if declare -f _ostler_write_store_curl_config >\/dev\/null 2>&1; then$/ { f = 1 }
    f { print }
    f && /^    fi$/ { exit }
' "$SRC")"

n_lines="$(printf '%s\n' "$region" | grep -c .)"
if [ "$n_lines" -lt 3 ] || [ "$n_lines" -gt 12 ]; then
    bad "extracted ${n_lines} lines for the re-arm region, implausible; refusing to eval" \
        "the anchors moved, so this suite measures nothing until they are fixed"
    printf '\n== %s pass / %s fail ==\n' "$PASS" "$FAIL"
    exit 78
fi
ok "extracted the re-arm region from the shipped install.sh (${n_lines} lines)"

[ "$(printf '%s\n' "$region" | grep -c '_ostler_write_store_curl_config')" -gt 0 ] \
    && ok "the region calls the credential writer" \
    || bad "the region does not call the writer"

# The guard matters: promote has a call site EARLIER than the writer's own
# definition, and an unguarded call there would print "command not found" and,
# behind || true, do nothing while looking applied.
[ "$(printf '%s\n' "$region" | grep -c 'declare -f _ostler_write_store_curl_config')" -gt 0 ] \
    && ok "and guards on the writer existing, for the promote call that precedes its definition" \
    || bad "the call is unguarded; on the early-promote path it would silently do nothing"

# ---------------------------------------------------------------------------
# Arm against staging, promote, then run the region. The writer is the shipped
# one's shape: capture by value, exactly as :7574 and :7619 do.
# ---------------------------------------------------------------------------
scenario() { # $1 = region to run ("" for the pre-fix behaviour)
    local rgn="$1"
    (
        set +u
        local staging="$WORK/stage.$$" final="$WORK/final.$$"
        rm -rf "$staging" "$final"
        mkdir -p "$staging/secrets" "$final/secrets"
        printf 'header = "X-Test: 1"\n' > "$staging/secrets/store-curl.conf"

        _ostler_write_store_curl_config() {
            local _conf="${OSTLER_DIR}/secrets/store-curl.conf"
            _OSTLER_STORE_CURL_ARGS=( -K "$_conf" )
        }

        # Arm while OSTLER_DIR is still the staging tree, as :13179 does.
        OSTLER_DIR="$staging"
        _ostler_write_store_curl_config

        # Promote: the real one moves the tree, deletes staging, then rebinds.
        cp "$staging/secrets/store-curl.conf" "$final/secrets/store-curl.conf"
        rm -rf "$staging"
        OSTLER_DIR="$final"

        [ -n "$rgn" ] && eval "$rgn"

        # What would curl actually be handed?
        local used="" i=0
        for a in "${_OSTLER_STORE_CURL_ARGS[@]+"${_OSTLER_STORE_CURL_ARGS[@]}"}"; do
            if [ "$i" = "1" ]; then used="$a"; break; fi
            i=1
        done
        printf 'USED=%s READABLE=%s\n' "$used" "$([ -r "$used" ] && echo yes || echo no)"
    )
}

out="$(scenario "$region")"
[ "$(printf '%s\n' "$out" | grep -c 'READABLE=yes')" -gt 0 ] \
    && ok "after promote the armed credential is a file that EXISTS" \
    || bad "the armed credential is not readable after promote" "$out"
[ "$(printf '%s\n' "$out" | grep -c 'USED=.*final')" -gt 0 ] \
    && ok "and it points at the promoted tree, not the staging one" \
    || bad "the armed path is not in the final tree" "$out"

# ---------------------------------------------------------------------------
# MUST-FAIL: without the re-arm, the array is left pointing at the deleted path.
# This is the pre-fix behaviour, and it is what produced rc=26 on the walk.
# ---------------------------------------------------------------------------
out_m="$(scenario "")"
if [ "$(printf '%s\n' "$out_m" | grep -c 'READABLE=no')" -gt 0 ]; then
    ok "MUST-FAIL: without the re-arm the credential path is dead, so the fix is what does the work"
else
    bad "MUST-FAIL: the pre-fix path was still readable; the arm above proves nothing" "$out_m"
fi
[ "$(printf '%s\n' "$out_m" | grep -c 'USED=.*stage')" -gt 0 ] \
    && ok "and the dead path is the staging one, which is the measured defect" \
    || bad "the pre-fix path was not the staging tree" "$out_m"

# ---------------------------------------------------------------------------
# The diagnostic must name the path the curl actually used.
# ---------------------------------------------------------------------------
diag="$(awk '/^ *# THE PATH THE CURL ACTUALLY USED, NOT ONE RECOMPUTED HERE\.$/ { f = 1 } f { print } f && /^ *fi$/ { exit }' "$SRC")"
d_lines="$(printf '%s\n' "$diag" | grep -c .)"
if [ "$d_lines" -lt 6 ] || [ "$d_lines" -gt 30 ]; then
    bad "extracted ${d_lines} lines for the diagnostic region, implausible; refusing to eval" \
        "the anchor moved, so the arms below would measure nothing"
else
    ok "extracted the readiness diagnostic from the shipped install.sh (${d_lines} lines)"

    # DRIVEN, NOT GREPPED. A grep for the array name would pass on a region that
    # merely mentions it in a comment, which is the shape of assertion that has
    # already fired on my own prose twice in this workstream. So the region is
    # run: the array is armed with a path in a staging tree that no longer
    # exists, OSTLER_DIR points at a healthy promoted tree, and the region must
    # report the DEAD path, because that is the one curl was handed.
    diag_run() { # $1 = region
        (
            set +u
            local stale="/nonexistent-staging-$$/secrets/store-curl.conf"
            mkdir -p "$WORK/promoted/secrets"
            printf 'header = "X-Test: 1"\n' > "$WORK/promoted/secrets/store-curl.conf"
            OSTLER_DIR="$WORK/promoted"
            _OSTLER_STORE_CURL_ARGS=( -K "$stale" )
            eval "$1"
            printf 'CONF=%s\n' "$_e6_conf"
        )
    }

    o_d="$(diag_run "$diag")"
    [ "$(printf '%s\n' "$o_d" | grep -c 'CONF=/nonexistent-staging')" -gt 0 ] \
        && ok "the diagnostic names the DEAD path the curl actually opened" \
        || bad "the diagnostic named a different path from the one curl was given" "$o_d"
    [ "$(printf '%s\n' "$o_d" | grep -c 'CONF=.*promoted')" -eq 0 ] \
        && ok "and does NOT name the healthy promoted file, which is what made the WARN mislead" \
        || bad "the diagnostic described the healthy file while curl opened a dead one" "$o_d"

    # MUST-FAIL: strip the loop that reads the array. The region then falls back
    # to the recomputed path and describes the healthy file, which is the
    # pre-fix behaviour that cost three agents a walk.
    if [ "$(printf '%s\n' "$diag" | grep -c 'for _e6_a in')" -eq 0 ]; then
        bad "the line the mutation targets is not in the diagnostic; the must-fail arm cannot mean anything"
    else
        d_mut="$(printf '%s\n' "$diag" | sed 's/^\([[:space:]]*\)if \[ "\${#_OSTLER_STORE_CURL_ARGS\[@\]}" -gt 1 \] 2>\/dev\/null; then$/\1if false; then/')"
        if [ "$(printf '%s\n' "$d_mut" | grep -c 'if false; then')" -eq 0 ]; then
            bad "the mutation did not land; the must-fail arm below would prove nothing"
        else
            ok "the mutation landed (the array read is bypassed)"
            o_dm="$(diag_run "$d_mut")"
            if [ "$(printf '%s\n' "$o_dm" | grep -c 'CONF=.*promoted')" -gt 0 ]; then
                ok "MUST-FAIL: without the array read it names the healthy file, so the arms above are real"
            else
                bad "MUST-FAIL: the mutant did not fall back to the recomputed path" "$o_dm"
            fi
        fi
    fi

    # The fallback is deliberate and must survive: an unset array still prints
    # the best guess rather than an empty string.
    o_unset="$( set +u; ( OSTLER_DIR="$WORK/promoted"; unset _OSTLER_STORE_CURL_ARGS; eval "$diag"; printf 'CONF=%s\n' "$_e6_conf" ) 2>/dev/null )"
    [ "$(printf '%s\n' "$o_unset" | grep -c 'CONF=.*promoted')" -gt 0 ] \
        && ok "an unset array still yields the recomputed path, never a blank" \
        || bad "an unarmed array left the diagnostic with nothing to print" "$o_unset"
fi

# ---------------------------------------------------------------------------
# THE COMMENT'S OWN LINE CITATIONS MUST STILL POINT AT WHAT THEY CLAIM.
#
# The re-arm comment cites fifteen lines of install.sh by number, and every one
# of them moves the moment anyone inserts a line above it. This is not
# hypothetical: while writing THIS change the citations went stale twice, once
# because the fix itself shifted the file by 35 lines and once because
# rewriting the comment shifted it again by 18. A comment that cites :7574 for
# a line now at :7627 is worse than one that cites nothing, because a reader
# checks it once, finds something plausible, and stops.
#
# The walk runner carries the same scar from the same week: its header claimed
# ":201-204 the BROKEN skip" for a skip that was at :249.
#
# So the citations are checked here rather than trusted. Each cited line must
# still contain the token the comment says is there.
# ---------------------------------------------------------------------------
cite() { # $1 = line number, $2 = token that must appear on it
    local got
    got="$(sed -n "${1}p" "$SRC")"
    if [ "$(printf '%s\n' "$got" | grep -cF -- "$2")" -gt 0 ]; then
        return 0
    fi
    printf '%s\n' "$got"
    return 1
}

rearm="$(awk '/^    # RE-ARM THE STORE CREDENTIAL AGAINST THE PATH THAT NOW EXISTS\.$/ { f = 1 }
              f { print }
              f && /^    if declare -f/ { exit }' "$SRC")"
cited="$(printf '%s\n' "$rearm" | grep -oE ':[0-9]{3,5}' | tr -d ':' | sort -un)"
n_cited="$(printf '%s\n' "$cited" | grep -c .)"

if [ "$n_cited" -lt 10 ]; then
    bad "only ${n_cited} line citations found in the re-arm comment; expected the full set"
else
    ok "the re-arm comment cites ${n_cited} lines of install.sh by number"

    bad_cites=""
    for n in $cited; do
        line="$(sed -n "${n}p" "$SRC")"
        case "$line" in
            *_ostler_write_store_curl_config*|*_OSTLER_STORE_CURL_ARGS*|\
            *_ostler_promote_prelaunch_tree*|*_ostler_set_paths*|\
            *'rm -rf "$OSTLER_PRELAUNCH_DIR"'*|*'local _conf='*|\
            *'THIRD OCCURRENCE OF THIS CLASS'*|*'#177 ALL OVER AGAIN'*|\
            *'A gate keyed to a name does not cover a class'*) ;;
            *) bad_cites="$bad_cites $n" ;;
        esac
    done
    if [ -z "$bad_cites" ]; then
        ok "and every one of them still lands on the construct it names"
    else
        bad "these citations no longer point at what the comment claims:${bad_cites}" \
            "$(for n in $bad_cites; do printf ':%s -> %s\n' "$n" "$(sed -n "${n}p" "$SRC" | sed 's/^ *//')"; done)"
    fi

    # CONTROL on that predicate. A line that is certainly NOT one of the cited
    # constructs must be rejected by it, or the loop above would accept
    # anything and pass for ever.
    ctl="$(grep -n '^#!/' "$SRC" | head -1 | cut -d: -f1)"
    ctl_line="$(sed -n "${ctl}p" "$SRC")"
    case "$ctl_line" in
        *_ostler_write_store_curl_config*|*_OSTLER_STORE_CURL_ARGS*|\
        *_ostler_promote_prelaunch_tree*|*_ostler_set_paths*|\
        *'rm -rf "$OSTLER_PRELAUNCH_DIR"'*|*'local _conf='*|\
        *'THIRD OCCURRENCE OF THIS CLASS'*|*'#177 ALL OVER AGAIN'*|\
        *'A gate keyed to a name does not cover a class'*)
            bad "CONTROL: the shebang at :${ctl} was accepted as a cited construct; the check above discriminates nothing" ;;
        *)
            ok "CONTROL: a line that is none of those constructs is rejected, so the check discriminates" ;;
    esac
fi

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
