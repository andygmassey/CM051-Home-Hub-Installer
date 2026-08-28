#!/usr/bin/env bash
#
# verify_wired_paths_are_tracked.sh
#
# A GUARD THE PIPELINE CALLS MUST ACTUALLY BE IN THE REPO.
#
# On 2026-08-10 `bin/require_signing_credentials.sh` -- a guard script
# holding no secret at all -- was silently skipped by `git add -A`,
# because `.gitignore` carries `*credentials*` UNANCHORED. The commit
# pushed without it and cut.yml was left calling a file absent from the
# repo. On 2026-08-28 the same class caught a #912 guard named
# `test_private_artefacts_*` against `*_private*`. That is two recorded
# instances plus the one in .gitignore's own comment.
#
# ── WHY THIS GATE AND NOT A NARROWER .gitignore ──────────────────────
# The patterns match on NAME. The hazard is CONTENT. A file ABOUT tokens
# is being treated as a file CONTAINING tokens, and there are three such
# patterns in this repo:
#
#     .gitignore:22  *_private*
#     .gitignore:23  *credentials*
#     .gitignore:32  *token*
#
# Narrowing them is a repo-wide change with its own blast radius. This
# gate is additive, fails closed, and asserts the thing that actually
# matters -- that every path the pipeline believes it runs is TRACKED.
#
# 📌 It checks TRACKING, not IGNORING, and that distinction is the whole
# design. `git add -f` defeats a narrower ignore rule silently; it does
# NOT defeat this, because a force-added file IS tracked and therefore
# passes honestly. The gate cannot be satisfied by hiding the problem.
#
# ⚠️ IMPACT TODAY IS ZERO ROWS, STATED RATHER THAN IMPLIED.
# 361 of 361 wired paths resolve and all 361 are tracked. This recovers
# nothing right now. It is a latent-defect gate whose entire value is
# the fourth occurrence, and the class LEAVES NO TRACE IN THE REPO BY
# CONSTRUCTION -- you cannot count files that were never committed. Do
# not read today's zero as "not happening here".
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 🔴 RESOLVED PER CALL, NOT ONCE AT LOAD, AND THE SELF-TEST IS WHY.
# This was a global assigned at script load. The self-test overrides it
# with `OSTLER_WIRING_TSV=... verify`, which sets the ENV for the call
# but cannot change a variable that was already expanded -- so four of
# eight controls silently read the REAL manifest, passed, and reported
# the gate as working. A self-test whose scenarios never reach the code
# under test is the vacuity this gate exists to prevent, committed
# inside the gate itself.
wiring_tsv() { printf '%s' "${OSTLER_WIRING_TSV:-${REPO_ROOT}/tests/TEST_WIRING.tsv}"; }

# Pinned, NOT derived from the file we are checking. A floor computed
# from the input passes for free when the input is truncated -- that is
# #811, and it took two wrong attempts to learn.
MIN_RESOLVED_ROWS="${OSTLER_WIRING_FLOOR:-300}"

fail() { echo "FAIL: $*" >&2; }

verify() {
    local failed=0 total=0 resolved=0 unresolved=0 untracked=0
    local WIRING_TSV; WIRING_TSV="$(wiring_tsv)"
    local line name cand p

    if [ ! -f "$WIRING_TSV" ]; then
        echo "FAIL: ${WIRING_TSV} not found -- CANNOT-RUN, not a pass." >&2
        return 2
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ""|"#"*) continue ;; esac
        name="${line%%$'\t'*}"
        [ -n "$name" ] || continue
        [ "$name" != "test_name" ] || continue
        total=$((total + 1))

        # Rows are stored bare for tests/ and repo-relative for
        # everything else (the gui/ Swift suites). Try both, in that
        # order, rather than assuming one -- assuming `tests/` reported
        # 38 phantom absences the first time I measured this.
        p=""
        for cand in "${REPO_ROOT}/tests/${name}" "${REPO_ROOT}/${name}"; do
            if [ -f "$cand" ]; then p="$cand"; break; fi
        done

        if [ -z "$p" ]; then
            unresolved=$((unresolved + 1))
            fail "wired path does not exist: ${name}"
            failed=1
            continue
        fi
        resolved=$((resolved + 1))

        if ! git -C "$REPO_ROOT" ls-files --error-unmatch "$p" >/dev/null 2>&1; then
            untracked=$((untracked + 1))
            failed=1
            fail "WIRED BUT NOT TRACKED: ${p}"
            echo "      The pipeline calls this file and it is not in the repo." >&2
            echo "      Most likely an unanchored .gitignore pattern swallowed it" >&2
            echo "      on 'git add'. Check: git check-ignore -v '${p}'" >&2
            echo "      Rename the file rather than 'git add -f' -- forcing tracks" >&2
            echo "      it while leaving every ignore-respecting tool free to skip" >&2
            echo "      it, which is the inert-by-location class." >&2
        fi
    done < "$WIRING_TSV"

    # ── ANTI-VACUITY ─────────────────────────────────────────────────
    # Every assertion above is "this row is fine". A truncated or
    # mis-parsed manifest yields zero rows and therefore zero failures,
    # which is a clean green over nothing at all.
    if [ "$resolved" -lt "$MIN_RESOLVED_ROWS" ]; then
        echo "FAIL: only ${resolved} wired paths resolved, floor is ${MIN_RESOLVED_ROWS}." >&2
        echo "      The manifest is truncated or the resolver is broken, so a" >&2
        echo "      zero-failure result here means nothing. CANNOT-RUN." >&2
        return 2
    fi

    echo "wired paths: ${total} rows, ${resolved} resolved, ${unresolved} missing, ${untracked} untracked"
    [ "$failed" -eq 0 ] || return 1
    echo "verify_wired_paths_are_tracked: PASS"
    return 0
}

# ── SELF-TEST ────────────────────────────────────────────────────────
# Plants a probe whose NAME matches a real pattern in THIS repo's
# .gitignore, so the scenario reproduces the actual class rather than a
# synthetic one. A fabricated repo would not carry CM051's patterns and
# would prove nothing about CM051.
self_test() {
    local probe="${REPO_ROOT}/tests/test_zz_selftest_private_probe.sh"
    local tsv rc pass=0 total=0
    tsv="$(mktemp -t ostler-wiring.XXXXXX)"

    cleanup_st() { rm -f "$probe" "$tsv" 2>/dev/null || true; }
    trap cleanup_st EXIT INT TERM

    check() {  # check <label> <expected-rc> <actual-rc>
        total=$((total + 1))
        if [ "$2" = "$3" ]; then
            echo "  ok    $1 (rc=$3)"; pass=$((pass + 1))
        else
            echo "  FAIL  $1 -- expected rc=$2 got rc=$3" >&2
        fi
    }

    # 1. Baseline: the committed tree passes.
    verify >/dev/null 2>&1; rc=$?
    check "baseline: the tree as committed PASSES" 0 "$rc"

    # 2. The probe's NAME is genuinely ignored by this repo's rules.
    #    Without this the rest of the self-test proves nothing about the
    #    class -- it would just be a missing file.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$probe"
    git -C "$REPO_ROOT" check-ignore -q "$probe"; rc=$?
    check "the probe name IS caught by a real .gitignore pattern" 0 "$rc"

    # 3. And it is therefore untracked.
    git -C "$REPO_ROOT" ls-files --error-unmatch "$probe" >/dev/null 2>&1; rc=$?
    check "the probe is UNTRACKED (rc!=0 means untracked)" 1 "$rc"

    # 4. THE MUTATION. Wire the probe, and the gate must REJECT it.
    cp "$(wiring_tsv)" "$tsv"
    printf 'test_zz_selftest_private_probe.sh\tWIRED\t.github/workflows/selftest.yml\n' >> "$tsv"
    OSTLER_WIRING_TSV="$tsv" verify >/dev/null 2>&1; rc=$?
    check "a WIRED-but-untracked path is REJECTED" 1 "$rc"

    # 5. …and it must NAME it, not merely go red for some other reason.
    #
    # 🔴 THIRD VARIANT OF THE SAME TRAP TODAY, AND THIS ONE WAS IN THE
    # ASSERTION RATHER THAN THE PRODUCER. This was:
    #
    #     if OSTLER_WIRING_TSV="$tsv" verify 2>&1 | grep -q '...'; then
    #
    # `verify` returns 1 here BY DESIGN -- rejecting is the behaviour
    # under test. Under `pipefail` that 1 becomes the pipeline's status
    # even though grep matched perfectly, so the `if` took the else
    # branch and the control reported FAIL on a gate that was working.
    #
    # Capture first, then count. The `|| true` is not laundering a
    # status: control 4 above already asserted verify's exit code, so
    # this arm is only reading its TEXT, and conflating the two is what
    # broke it.
    local out
    out="$(OSTLER_WIRING_TSV="$tsv" verify 2>&1 || true)"
    if [ "$(printf '%s\n' "$out" | grep -c 'WIRED BUT NOT TRACKED')" -gt 0 ]; then
        rc=0; else rc=1; fi
    check "the rejection NAMES the untracked path" 0 "$rc"

    # 6. Remove the probe: gate green again, tree unchanged.
    rm -f "$probe"
    verify >/dev/null 2>&1; rc=$?
    check "after removal the gate is GREEN again" 0 "$rc"

    # 7. A truncated manifest is CANNOT-RUN (rc=2), never a pass.
    : > "$tsv"
    OSTLER_WIRING_TSV="$tsv" verify >/dev/null 2>&1; rc=$?
    check "an EMPTY manifest is CANNOT-RUN (rc=2), not a green" 2 "$rc"

    # 8. An absent manifest is CANNOT-RUN too.
    OSTLER_WIRING_TSV="${REPO_ROOT}/tests/__no_such_manifest__.tsv" verify >/dev/null 2>&1; rc=$?
    check "an ABSENT manifest is CANNOT-RUN (rc=2), not a green" 2 "$rc"

    cleanup_st
    trap - EXIT INT TERM
    echo ""
    echo "self-test: ${total} controls ran, ${pass} passed, $((total - pass)) failed"
    [ "$pass" -eq "$total" ] || return 1
    return 0
}

case "${1:-}" in
    --self-test) self_test ;;
    "")          verify ;;
    *)           echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
