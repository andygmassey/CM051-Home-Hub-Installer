#!/usr/bin/env bash
# Every "it failed to look" guard in cut.yml must be REACHABLE.
# ============================================================================
#
# Four steps in cut.yml locate the artefact the same way and then guard it:
#
#     DMG="$(ls dist/*.dmg 2>/dev/null | head -1)"
#     if [ -z "$DMG" ]; then
#         echo "::error...It has NOT verified delivery -- it failed to look."
#
# Under `set -Eeuo pipefail` that guard CANNOT RUN. A glob matching nothing
# makes `ls` exit non-zero, `pipefail` carries the status through `head`, and a
# command-substitution assignment takes the status of the substitution -- so
# `set -e` kills the step on the assignment line.
#
# MEASURED ON THE v1.0.72 CUT: three steps died in ~130ms having printed
# NOTHING. The message written to separate "I looked and it is missing" from
# "I could not look" was unreachable by construction, which is the precise
# failure those steps exist to prevent.
#
# THIS TEST DRIVES THE REAL LINES OUT OF cut.yml rather than a paraphrase of
# them, because a paraphrase is where this defect hides: the construct reads
# correctly and fails on shell semantics, so a hand-written copy in a test
# would very likely be written correctly and prove nothing.
#
# THREE ARMS PER SITE, and the third is why the first two are trustworthy:
#   absent    dist/ does not exist        -> the guard must PRINT and exit non-zero
#   empty     dist/ exists, no dmg        -> the guard must PRINT and exit non-zero
#   present   a dmg is there  (CONTROL)   -> the guard must NOT print, and the
#                                            extracted line must yield the path
# Without the control an `exit 1` on line 1 would pass both failure arms.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="${ROOT}/.github/workflows/cut.yml"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf '  [CANNOT-RUN] %s\n' "$1"; printf '== %d pass / %d fail / 1 cannot-run ==\n' "$PASS" "$FAIL"; exit 2; }

[ -r "$WF" ] || cant "cannot read ${WF}"

# Every line that locates the DMG. A count of zero here is CANNOT-RUN, never a
# pass: it means the idiom was renamed and this test is measuring nothing.
# bash 3.2 is what macOS ships and what the bash32 gate enforces, so no
# `mapfile` and no `readarray` -- a read loop, which works on both.
LINES=""
while IFS= read -r _l; do
    [ -n "$_l" ] || continue
    LINES="${LINES}${_l}
"
done <<EOF
$(grep -n 'DMG="\$(ls dist/\*\.dmg' "$WF" || true)
EOF
COUNT="$(printf '%s' "$LINES" | grep -c . || true)"
printf '  sites found: %d\n' "$COUNT"
[ "$COUNT" -gt 0 ] || cant "no 'DMG=\$(ls dist/*.dmg' line in cut.yml -- the idiom moved and this test is blind"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# NOT `printf ... | while`. A pipe runs the loop in a SUBSHELL, so PASS/FAIL
# increment a copy and the parent still sees 0 -- which means `[ "$FAIL" -eq 0 ]`
# below could never fire and this file would report rc=0 with failing arms. That
# is the same shape as the defect under test. Redirect instead; no subshell.
while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    lineno="${entry%%:*}"
    # The real assignment, verbatim from the workflow, leading spaces stripped.
    assign="$(sed -n "${lineno}p" "$WF" | sed 's/^[[:space:]]*//')"

    for arm in absent empty present; do
        rm -rf "${WORK}/dist"
        case "$arm" in
            empty)   mkdir -p "${WORK}/dist" ;;
            present) mkdir -p "${WORK}/dist"; : > "${WORK}/dist/OstlerInstaller-0.0.0.dmg" ;;
        esac

        # Same shell options the workflow step sets.
        out="$(cd "$WORK" && /usr/bin/env bash -c "
            set -Eeuo pipefail
            ${assign}
            if [ -z \"\$DMG\" ]; then
                echo REACHED_THE_GUARD
                exit 1
            fi
            echo \"FOUND:\$DMG\"
        " 2>&1 || true)"

        case "$arm" in
            absent|empty)
                if printf '%s' "$out" | grep -q REACHED_THE_GUARD; then
                    ok "cut.yml:${lineno} ${arm}: the guard is reached"
                else
                    bad "cut.yml:${lineno} ${arm}: the guard was NOT reached -- the step dies on the assignment and prints nothing. Output: [${out}]"
                fi
                ;;
            present)
                if printf '%s' "$out" | grep -q '^FOUND:dist/'; then
                    ok "cut.yml:${lineno} present (CONTROL): the dmg is located"
                else
                    bad "cut.yml:${lineno} present (CONTROL): did not locate the dmg. Output: [${out}]"
                fi
                ;;
        esac
    done
done <<EOF
${LINES}
EOF

printf '== %d pass / %d fail / 0 cannot-run ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
