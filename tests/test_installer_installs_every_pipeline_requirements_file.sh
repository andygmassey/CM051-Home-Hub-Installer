#!/usr/bin/env bash
# The installer must install EVERY pipeline package's requirements, not the first.
#
# THE DEFECT. install.sh selected exactly one requirements file:
#
#     if   [[ -f "contact_syncer/requirements.txt" ]]; then PIPELINE_REQS=contact_syncer/requirements.txt
#     elif [[ -f "requirements.txt" ]];               then PIPELINE_REQS=requirements.txt
#
# contact_syncer always wins. identity_resolver's and meeting_syncer's were
# never installed, although all three ship in that same directory.
#
# MEASURED on a live box 2026-08-26, in the interpreter actually running
# ical-server, using that process's own PYTHONPATH:
#
#     rapidfuzz          ModuleNotFoundError
#     identity_resolver  ModuleNotFoundError: No module named 'rapidfuzz'
#     qdrant_client      ModuleNotFoundError
#     CONTROL json       OK      <- same interpreter: real absences, not a
#                                   broken invocation
#
# So the dedupe / identity-resolution layer is dark from first boot on every
# install. batch_resolver cannot import either, nothing reconciles Qdrant
# against Oxigraph, and _merge_qdrant() fails OPEN on the missing qdrant_client.
# The only symptom is data quality drifting -- 130 over-merged Person nodes and
# a 173-point store gap on the box measured -- with nothing reporting a fault.
#
# THE SAME OMISSION, TWICE. identity_resolver/requirements.txt exists because of
# it: CI "installed only the contact_syncer, meeting_syncer and whatsapp_bridge
# requirement files, so the import failed at COLLECTION time". Declaring the
# dependency fixed CI. The installer kept making the same choice, because a
# declaration and an installation are different acts.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

[[ -f "$INSTALL_SH" ]] || { echo "FAIL [missing]: no install.sh -- nothing checked. NOT a pass." >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---- 0. CONTROLS: the fix is only meaningful if these hold ----------------
# If identity_resolver's requirements were not shipped, installing them would be
# impossible and this whole test would be asserting a fantasy.
if [[ -f "$REPO_ROOT/vendor/cm041/identity_resolver/requirements.txt" ]]; then
    pass "CONTROL: identity_resolver/requirements.txt IS shipped in the payload"
else
    echo "FAIL [not-shipped]: vendor/cm041/identity_resolver/requirements.txt absent -- the premise of this test does not hold. NOT a pass." >&2
    exit 2
fi

if grep -qi 'rapidfuzz' "$REPO_ROOT/vendor/cm041/identity_resolver/requirements.txt"; then
    pass "CONTROL: that file is what declares rapidfuzz, so installing it fixes the import"
else
    fail "no-rapidfuzz" "identity_resolver/requirements.txt does not mention rapidfuzz; installing it would not fix the measured ModuleNotFoundError"
fi

# ---- 1. the single-selection shape must be gone ---------------------------
if grep -q 'elif \[\[ -f "requirements.txt" \]\]; then' "$INSTALL_SH" \
   && grep -q 'PIPELINE_REQS="contact_syncer/requirements.txt"' "$INSTALL_SH"; then
    fail "single-select" "install.sh still selects ONE requirements file via if/elif, so identity_resolver's and meeting_syncer's are never installed"
else
    pass "the if/elif single-selection of one requirements file is gone"
fi

# ---- 2. drive the real selection logic against a 3-package fixture -------
# Lifted from install.sh rather than reimplemented: a test that reimplements the
# logic proves the test works, not the installer.
A=$(grep -n 'PIPELINE_REQS=""' "$INSTALL_SH" | head -1 | cut -d: -f1)
if [[ -z "$A" ]]; then
    fail "no-loop" "could not find the PIPELINE_REQS accumulator in install.sh; selection logic not verified"
else
    B=$(awk -v a="$A" 'NR>a && /^    done$/{print NR; exit}' "$INSTALL_SH")
    if [[ -z "$B" ]]; then
        fail "unterminated" "the PIPELINE_REQS loop does not close; selection logic not verified"
    else
        sed -n "${A},${B}p" "$INSTALL_SH" > "$WORK/select.sh"
        # THE EXTRACT MUST PARSE, OR EVERY ARM BELOW IS MEANINGLESS.
        # Against the pre-fix install.sh the accumulator does not exist and this
        # range lands on a fragment ending in a bare `fi`. Sourcing that errors,
        # PIPELINE_REQS stays empty, and the empty-payload arm then PASSES --
        # for the wrong reason, on a broken apparatus. A test arm that can go
        # green because its own fixture failed to load is worse than no arm.
        if ! bash -n "$WORK/select.sh" 2>/dev/null; then
            fail "extract-unparseable" "the selection logic lifted from install.sh does not parse, so the selection arms below were NOT verified. This is CANNOT-RUN, not a pass -- and on the pre-fix installer it is expected, because there is no accumulator to lift."
            SELECT_OK=0
        else
            SELECT_OK=1
        fi
        mkdir -p "$WORK/box/contact_syncer" "$WORK/box/identity_resolver" "$WORK/box/meeting_syncer"
        for d in contact_syncer identity_resolver meeting_syncer; do
            printf 'somepkg\n' > "$WORK/box/$d/requirements.txt"
        done
        if [[ "${SELECT_OK:-0}" -eq 1 ]]; then
        GOT="$(cd "$WORK/box" && bash -c "source '$WORK/select.sh'; printf '%s' \"\$PIPELINE_REQS\"")"
        for want in contact_syncer identity_resolver meeting_syncer; do
            case "$GOT" in
                *"$want/requirements.txt"*) pass "selection includes $want" ;;
                *) fail "missing-$want" "selection '$GOT' omits $want/requirements.txt" ;;
            esac
        done

        # 3. A MINIMAL PAYLOAD MUST STILL WORK. Tightening selection is the easy
        #    way to break the one-package case; this is the regression guard.
        mkdir -p "$WORK/solo/contact_syncer"
        printf 'somepkg\n' > "$WORK/solo/contact_syncer/requirements.txt"
        SOLO="$(cd "$WORK/solo" && bash -c "source '$WORK/select.sh'; printf '%s' \"\$PIPELINE_REQS\"")"
        if [[ "$SOLO" == "contact_syncer/requirements.txt" ]]; then
            pass "a single-package payload still selects exactly that one"
        else
            fail "solo-broken" "single-package payload selected '$SOLO'"
        fi

        # 4. AN EMPTY PAYLOAD MUST SELECT NOTHING, not the literal glob.
        #    Without the -f guard, an unmatched */requirements.txt survives as
        #    text and pip would be handed a path that does not exist.
        mkdir -p "$WORK/empty"
        NONE="$(cd "$WORK/empty" && bash -c "source '$WORK/select.sh'; printf '%s' \"\$PIPELINE_REQS\"")"
        if [[ -z "$NONE" ]]; then
            pass "an empty payload selects nothing (the unmatched glob is not passed to pip)"
        else
            fail "glob-leak" "empty payload selected '$NONE' -- an unmatched glob reached the install list"
        fi
        fi
    fi
fi

[[ "$FAILED" -ne 0 ]] && exit 1
echo
echo "ALL PIPELINE REQUIREMENTS TESTS PASSED"
