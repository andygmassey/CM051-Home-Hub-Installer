#!/usr/bin/env bash
# The dry run must be ABLE to go green, and the gate that killed it must stay
# unmaskable on a tag push.
#
# WHY THIS EXISTS. On 2026-09-04 `983270cf` taught the installer-version gate to
# refuse a comparison it cannot lose (#171). Correct in itself. But the step is
# `if: always()` and LAST in preflight, and on a workflow_dispatch the version
# comes from the plist, so the gate exits 2 and takes the whole job with it.
#
#     cut.yml workflow_dispatch, all time    71 runs, 16 green, 55 red
#     last green dispatch                    33760954595, 2026-09-03T13:24:13Z
#     dispatches since 983270cf              8, of which green: 0
#
# The dry run is the one mechanism that exists so a broken cut-path check stops
# costing a version number, and it was switched off by a change that made a
# DIFFERENT gate more honest. Nothing announced it. **A red dry run looks
# exactly like a dry run doing its job**, which is why three days passed.
#
# 🗿 BOTH CONDITIONS ARE LOAD-BEARING, AND THE OBVIOUS FIX DROPS ONE.
#
#   always()                            the step runs even after an earlier
#                                       failure. This is the UNMASKABILITY the
#                                       step's own header argues for (#683).
#   startsWith(github.ref, tags/v1.0.)  it is silent where it cannot answer.
#
# Guarding on the ref ALONE fixes the dispatch and quietly makes the gate
# skippable on a tag push by any earlier failure. This file asserts BOTH, so
# neither can be removed as a simplification.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${DRY_RUN_TEST_REPO:-$(cd "${HERE}/.." && pwd)}"
WF="${REPO}/.github/workflows/cut.yml"

PASS=0; FAIL=0; CANT=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; CANT=$((CANT+1)); }

[ -r "${WF}" ] || { cant "no cut.yml at ${WF}"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

STEP='The installer.s own version IS the version being cut'

# The `if:` line belonging to that step, and ONLY that step.
#
# 🪤 THE STOP CONDITIONS ARE THE WHOLE PREDICATE. A first version stopped only
# at the next `- name:`, and this step is the LAST in its job -- so with the
# `if:` deleted the scan ran past the job boundary and returned the NEXT JOB's
# `if: github.event_name == 'push'`. Measured: it reported that string as this
# step's guard. The mutant still failed, for the wrong reason, which is worse
# than failing: on another tree it could PASS on a neighbour's condition.
#
# Within a step `if:` always precedes `run:`, so `run:` is the true end of the
# search. The job-boundary stop is kept as well: two independent stops, and the
# search ends at whichever comes first.
guard_line() {
    awk -v pat="${STEP}" '
        $0 ~ ("name: " pat) { found=1; next }
        found && /^[[:space:]]*if:/ { sub(/^[[:space:]]*if:[[:space:]]*/, ""); print; exit }
        found && /^[[:space:]]*run:/ { exit }
        found && /^[[:space:]]*-[[:space:]]*name:/ { exit }
        found && /^[[:space:]]{0,2}[A-Za-z_-]+:/ { exit }
    ' "${WF}"
}

GUARD="$(guard_line)"

if [ -z "${GUARD}" ]; then
    bad "the installer-version step has no 'if:' at all, so it runs on every dispatch and exits 2"
else
    ok "found the step's guard: ${GUARD}"

    case "${GUARD}" in
        *"always()"*) ok "arm 1: always() is present -- the gate stays unmaskable on a tag push (#683)" ;;
        *) bad "arm 1: always() is GONE. An earlier failure can now skip this gate on a real tag push. That is the property the step's own header argues for." ;;
    esac

    case "${GUARD}" in
        *"startsWith(github.ref"*"refs/tags/v1.0."*)
            ok "arm 2: guarded on a v1.0. tag ref -- silent on a dispatch, where CUT_VERSION comes from the plist and the comparison cannot lose" ;;
        *)
            bad "arm 2: no ref guard. On a workflow_dispatch this step exits 2 (CANNOT-RUN) and fails the job, which is what killed the dry run for three days." ;;
    esac
fi

# ── CONTROL: the pattern is real in this file, not invented here ────────────
# If the ref-guard spelling were wrong, arm 2 could pass on a string GitHub
# never evaluates. Another step already uses the same construct.
OTHER="$(grep -c "startsWith(github.ref, 'refs/tags/v1.0.')" "${WF}")"
if [ "${OTHER}" -ge 2 ]; then
    ok "CONTROL: the same ref-guard spelling appears ${OTHER} times, so it is this file's existing idiom"
else
    cant "CONTROL: the ref-guard spelling appears ${OTHER} time(s). Cannot confirm it is the idiom GitHub evaluates here."
fi

# ── CONTROL: the gate this guards really does refuse a plist-sourced version ─
# Without this, arms 1 and 2 could be guarding a step that never needed it.
T="${REPO}/tests/test_installer_version_matches_the_cut.sh"
if [ -r "${T}" ]; then
    if grep -q 'THIS IS NOT A PASS' "${T}" && grep -qE 'plist\|subject\|self\)' "${T}"; then
        ok "CONTROL: the guarded gate really does exit CANNOT-RUN on a plist-sourced version"
    else
        cant "CONTROL: could not confirm the guarded gate refuses a plist-sourced version"
    fi
else
    cant "CONTROL: ${T} is absent, so the reason for the guard is unverified"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / ${CANT} cannot-run =="
[ "${FAIL}" -gt 0 ] && exit 1
[ "${CANT}" -gt 0 ] && exit 2
exit 0
