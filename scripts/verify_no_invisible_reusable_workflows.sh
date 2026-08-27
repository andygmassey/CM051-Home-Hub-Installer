#!/usr/bin/env bash
# verify_no_invisible_reusable_workflows.sh
# ============================================================================
# NO WORKFLOW IN THIS REPO MAY CALL A REUSABLE WORKFLOW FROM ANOTHER REPOSITORY
# UNLESS IT IS EXPLICITLY ALLOWLISTED AS PUBLICLY RESOLVABLE.
#
# THE INCIDENT
# .github/workflows/enforce-ledger-write.yml called
#   andygmassey/HR015-Gaming-PC/.github/workflows/reusable-enforce-ledger-write.yml@main
# HR015-Gaming-PC is PRIVATE and its Actions access level is `none`
# (GET /repos/andygmassey/HR015-Gaming-PC/actions/permissions/access ->
# {"access_level":"none"}), so a PUBLIC repo cannot resolve it. Measured on
# CM051 PR #493 head 16503a83, run 32220337769:
#
#     conclusion  = failure
#     jobs        = 0
#     check-runs matching /ledger-pr/ on the head sha = 0
#     run name    = ".github/workflows/enforce-ledger-write.yml"
#                   (the PATH, not the declared `name: enforce-ledger-write`
#                    -- GitHub never parsed the file into a run definition)
#     gh run view = "This run likely failed because of a workflow file issue."
#
# WHY THIS IS WORSE THAN A FAILING GATE
# A workflow that cannot resolve its `uses:` fails at STARTUP. Startup failure
# produces a run with ZERO jobs, therefore ZERO check-runs. `gh pr checks`
# does not list it and the PR merge box does not show it. The gate is not red;
# it is ABSENT. Absent and passing look identical to every reviewer and to
# every branch-protection rule, which is why this sat unnoticed.
#
# It also takes the whole FILE down, not just the offending job: one
# unresolvable `uses:` makes every sibling job in that file invisible too.
#
# THE RULE
# A cross-repo reusable-workflow call is allowed only when the source repo is
# recorded in the allowlist below AND (when a token is available) measured to
# be public. Anything else fails here, loudly, in a job that DOES produce a
# check-run.
#
# Usage:  scripts/verify_no_invisible_reusable_workflows.sh [--workflows-dir DIR]
# Env:
#   REUSABLE_WF_ALLOWLIST  path to the allowlist (default scripts/reusable_workflow_allowlist.tsv)
#   GITHUB_REPOSITORY      owner/repo of THIS repo; falls back to the git remote
#   GH_TOKEN / GITHUB_TOKEN  optional; enables the live public/private probe
#
# Exit 0 = clean.  1 = a cross-repo call that can go invisible.  3 = CANNOT-RUN
# (nothing scanned, or the live probe was demanded and could not run).
#
# macOS /bin/bash 3.2 + BSD userland. No grep -P, no sed \b.
# British English; " -- " not em-dashes.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WF_DIR="${REPO_DIR}/.github/workflows"
ALLOWLIST="${REUSABLE_WF_ALLOWLIST:-${SCRIPT_DIR}/reusable_workflow_allowlist.tsv}"

while [ $# -gt 0 ]; do
    case "$1" in
        --workflows-dir) WF_DIR="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -t 1 ]; then C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
else C_G=""; C_R=""; C_Y=""; C_0=""; fi

echo "=== reusable-workflow visibility gate ==="
echo "workflows dir: ${WF_DIR}"
echo "allowlist:     ${ALLOWLIST}"

if [ ! -d "${WF_DIR}" ]; then
    echo "  ${C_R}CANNOT-RUN${C_0}  no workflows directory at ${WF_DIR}" >&2
    echo "        zero files examined is not zero problems." >&2
    exit 3
fi

# --- resolve THIS repo -------------------------------------------------------
THIS_REPO="${GITHUB_REPOSITORY:-}"
if [ -z "${THIS_REPO}" ]; then
    ORIGIN="$(git -C "${REPO_DIR}" config --get remote.origin.url 2>/dev/null)"
    case "${ORIGIN}" in
        *github.com[:/]*)
            THIS_REPO="${ORIGIN#*github.com}"
            THIS_REPO="${THIS_REPO#:}"; THIS_REPO="${THIS_REPO#/}"
            THIS_REPO="${THIS_REPO%.git}" ;;
    esac
fi
echo "this repo:     ${THIS_REPO:-<unresolved>}"

# --- gather the files --------------------------------------------------------
FILES=""
for f in "${WF_DIR}"/*.yml "${WF_DIR}"/*.yaml; do
    [ -f "$f" ] || continue
    FILES="${FILES}${f}
"
done
N_FILES="$(printf '%s' "${FILES}" | grep -c . )"
if [ "${N_FILES}" -eq 0 ]; then
    echo "  ${C_R}CANNOT-RUN${C_0}  0 workflow files found under ${WF_DIR}" >&2
    echo "        a scan of nothing always comes back clean -- refusing to report a pass." >&2
    exit 3
fi

# --- count EVERY `uses:` line first (the positive control) -------------------
# If this number is 0 the extraction predicate is broken, not the tree: every
# real workflow tree has step-level `uses: actions/checkout@vN`. A confident
# "no cross-repo calls" on top of a zero total is a wrong predicate, not a
# clean repo.
ALL_USES=0
COMMENTED_OUT=0
REUSABLE_LINES=""
# Full-line YAML comments are BLANKED, not dropped, so line numbers survive.
# This file's own header quotes the broken `uses:` it exists to ban, and a
# scanner that reads its own documentation as a violation is a scanner nobody
# will keep. Comment-hidden hits are counted and printed, never silently eaten.
strip_comments() { sed 's/^[[:space:]]*#.*$//' "$1"; }
while IFS= read -r f; do
    [ -n "$f" ] || continue
    n="$(strip_comments "$f" | grep -c '[[:space:]]uses:[[:space:]]' 2>/dev/null || true)"
    ALL_USES=$(( ALL_USES + ${n:-0} ))
    raw_r="$(grep -c '[[:space:]]uses:[[:space:]]*[^[:space:]]*\.github/workflows/' "$f" 2>/dev/null || true)"
    live_r="$(strip_comments "$f" | grep -c '[[:space:]]uses:[[:space:]]*[^[:space:]]*\.github/workflows/' 2>/dev/null || true)"
    COMMENTED_OUT=$(( COMMENTED_OUT + ${raw_r:-0} - ${live_r:-0} ))
    # A reusable-workflow call is the only `uses:` whose value carries the
    # `.github/workflows/` path segment. Step-level action uses never do.
    hits="$(strip_comments "$f" | grep -n '[[:space:]]uses:[[:space:]]*[^[:space:]]*\.github/workflows/' 2>/dev/null || true)"
    if [ -n "${hits}" ]; then
        while IFS= read -r h; do
            [ -n "$h" ] || continue
            REUSABLE_LINES="${REUSABLE_LINES}${f}|${h}
"
        done <<EOF
${hits}
EOF
    fi
done <<EOF
${FILES}
EOF

N_REUSABLE="$(printf '%s' "${REUSABLE_LINES}" | grep -c . )"

echo
echo "  files scanned:                 ${N_FILES}"
echo "  \`uses:\` lines seen (control):  ${ALL_USES}"
echo "  reusable-workflow calls found: ${N_REUSABLE}"
echo "  ...of which commented out:     ${COMMENTED_OUT} (excluded, not eaten)"

if [ "${ALL_USES}" -eq 0 ]; then
    echo "  ${C_R}CANNOT-RUN${C_0}  ${N_FILES} workflow file(s) and NOT ONE \`uses:\` line" >&2
    echo "        every real workflow tree has step-level action uses. The extraction" >&2
    echo "        predicate is broken, so 'no cross-repo calls' would be a false absence." >&2
    exit 3
fi

# --- load the allowlist ------------------------------------------------------
ALLOWED=""
N_ALLOW=0
if [ -r "${ALLOWLIST}" ]; then
    while IFS=$'\t' read -r a_repo a_reason; do
        case "${a_repo}" in ''|\#*) continue ;; esac
        a_repo="$(printf '%s' "${a_repo}" | tr -d '[:space:]')"
        [ -n "${a_repo}" ] || continue
        ALLOWED="${ALLOWED}${a_repo}
"
        N_ALLOW=$(( N_ALLOW + 1 ))
    done < "${ALLOWLIST}"
fi
echo "  allowlisted source repos:      ${N_ALLOW}"
echo

RC=0
CHECKED=0
CROSS=0
while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    file="${rec%%|*}"
    rest="${rec#*|}"
    lineno="${rest%%:*}"
    text="${rest#*:}"
    CHECKED=$(( CHECKED + 1 ))

    # Pull the reference out of `uses: owner/repo/.github/workflows/x.yml@ref`.
    ref="$(printf '%s' "${text}" | sed -e 's/.*uses:[[:space:]]*//' -e 's/[[:space:]].*$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//')"
    src_repo="$(printf '%s' "${ref}" | sed -e 's|/\.github/workflows/.*$||')"

    if [ "${src_repo}" = "${THIS_REPO}" ] || [ "${ref#./}" != "${ref}" ]; then
        printf '  %sPASS%s  %s:%s local reusable workflow (%s)\n' \
            "$C_G" "$C_0" "$(basename "${file}")" "${lineno}" "${ref}"
        continue
    fi

    CROSS=$(( CROSS + 1 ))
    # Remedy B, not `| grep -q`. Under `set -o pipefail` grep -q exits on the
    # first match and SIGPIPEs printf, so the PIPELINE reports failure exactly
    # WHEN THE PATTERN IS FOUND -- here that would read an allowlisted repo as
    # NOT allowlisted. grep -c must read to EOF, so it cannot short-circuit.
    # `|| true` because grep -c exits 1 on zero matches.
    if [ "$(printf '%s' "${ALLOWED}" | grep -cx -- "${src_repo}" || true)" -gt 0 ]; then
        printf '  %sWARN%s  %s:%s cross-repo call to %s -- ALLOWLISTED in %s\n' \
            "$C_Y" "$C_0" "$(basename "${file}")" "${lineno}" "${src_repo}" "${ALLOWLIST}"
        # When a token is available, do not take the allowlist's word for it.
        tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
        if [ -n "${tok}" ] && command -v gh >/dev/null 2>&1; then
            vis="$(GH_TOKEN="${tok}" gh api "repos/${src_repo}" --jq '.private' 2>/dev/null)"
            case "${vis}" in
                false) printf '        measured: %s is PUBLIC -- resolvable from a public caller\n' "${src_repo}" ;;
                true)
                    printf '  %sFAIL%s  %s:%s allowlisted repo %s is PRIVATE\n' \
                        "$C_R" "$C_0" "$(basename "${file}")" "${lineno}" "${src_repo}" >&2
                    printf '        measured: GET repos/%s .private = true\n' "${src_repo}" >&2
                    printf '        expected: a public source repo, or no cross-repo call at all\n' >&2
                    printf '        a private source makes this run start-fail with 0 jobs and 0 check-runs\n' >&2
                    RC=1 ;;
                *)
                    printf '        %sCANNOT-RUN%s could not read visibility of %s (probe returned %s)\n' \
                        "$C_R" "$C_0" "${src_repo}" "${vis:-<empty>}" >&2
                    [ "${RC}" -eq 0 ] && RC=3 ;;
            esac
        else
            printf '        (no token: visibility of %s NOT measured this run)\n' "${src_repo}"
        fi
        continue
    fi

    printf '  %sFAIL%s  %s:%s calls a reusable workflow from another repo: %s\n' \
        "$C_R" "$C_0" "$(basename "${file}")" "${lineno}" "${src_repo}" >&2
    printf '        measured: %s line %s -> `%s`\n' "${file}" "${lineno}" "${ref}" >&2
    printf '        expected: a job defined in THIS repo, or %s listed in %s\n' \
        "${src_repo}" "${ALLOWLIST}" >&2
    printf '        why: if that reference cannot resolve, the workflow fails at STARTUP.\n' >&2
    printf '             A startup failure produces 0 jobs and therefore 0 check-runs, so the\n' >&2
    printf '             gate is not red -- it is ABSENT, and absent looks exactly like passing.\n' >&2
    printf '             CM051 run 32220337769 is the worked example: conclusion=failure,\n' >&2
    printf '             jobs=0, check-runs named ledger-pr on the head sha=0.\n' >&2
    RC=1
done <<EOF
${REUSABLE_LINES}
EOF

echo
echo "=== Verdict: ${CHECKED} reusable-workflow call(s) examined, ${CROSS} cross-repo, across ${N_FILES} workflow file(s) ==="
if [ "${RC}" -eq 0 ]; then
    echo "  ${C_G}CLEAN${C_0} -- no workflow in this repo can go invisible on an unresolvable \`uses:\`."
elif [ "${RC}" -eq 3 ]; then
    echo "  ${C_R}CANNOT-RUN${C_0} -- a required visibility probe did not answer. Not a pass." >&2
else
    echo "  ${C_R}RED${C_0} -- fix the calls above, or allowlist a PUBLIC source repo." >&2
fi
exit "${RC}"
