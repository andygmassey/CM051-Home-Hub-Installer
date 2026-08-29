#!/usr/bin/env bash
# enforce_ledger_write.sh -- SHIPPING_LEDGER.yaml write discipline, enforced
# from INSIDE this repo.
# ============================================================================
#
# WHY THIS IS VENDORED AND NOT CALLED CROSS-REPO
#
# .github/workflows/enforce-ledger-write.yml used to be three lines:
#
#     jobs:
#       ledger-pr:
#         uses: andygmassey/HR015-Gaming-PC/.github/workflows/reusable-enforce-ledger-write.yml@main
#
# That never produced a check-run. Not once. Measured 2026-08-19 on PR #493
# head 16503a83, run 32220337769:
#
#     conclusion  = failure
#     jobs        = 0
#     check-runs named `ledger-pr` on the head sha = 0
#     run name    = ".github/workflows/enforce-ledger-write.yml", the PATH,
#                   not the declared `name: enforce-ledger-write` -- GitHub
#                   never parsed the file into a run definition
#     gh run view = "This run likely failed because of a workflow file issue."
#
# Root cause, measured rather than assumed:
#
#     gh api repos/andygmassey/HR015-Gaming-PC --jq .private
#         true
#     gh api repos/andygmassey/HR015-Gaming-PC/actions/permissions/access
#         {"access_level":"none"}
#
# HR015-Gaming-PC is private and shares its Actions with nothing. CM051 is
# public. The `uses:` cannot resolve, so the workflow fails at STARTUP, and a
# startup failure yields a run with zero jobs and therefore zero check-runs.
# It was NOT a red gate. It was an ABSENT gate, which on a PR merge box and to
# every branch-protection rule looks exactly like a passing one.
#
# Ruled out before landing on that cause: the referenced file DOES exist on
# HR015 main (7428 bytes, sha 65002eee), and `mode` IS a declared workflow_call
# input with default `pr`. So it is neither a bad path nor a bad input.
#
# The workflow's own 2026-07-31 draft note named this exact fallback: "If the
# workflow_call resolution fails, fall back to vendoring the enforcement into
# this repo and calling it from an inline workflow." This is that.
#
# Faithful port of the `enforce-pr` job of
# HR015-Gaming-PC/.github/workflows/reusable-enforce-ledger-write.yml@main.
# Kept as a SCRIPT rather than inline YAML so it can be run and failed on a
# laptop: inline workflow YAML cannot be tested, and an untestable gate is how
# the last one got here.
#
# THE RULE
# If a PR touches shipping-adjacent files -- cut-manifests/, release/build-binary.sh,
# a gui/Makefile DAEMON_VERSION|DAEMON_SHA256 line, an install.sh
# OSTLER_ASSISTANT_VERSION|DEFAULT_ASSISTANT_TARBALL_SHA256 line, or anything
# under a vendor/ directory -- the PR body MUST carry one of:
#
#     [ledger-entry: <URL to the HR015 SHIPPING_LEDGER.yaml PR or commit>]
#     [skip-ledger-enforce: <reason>]
#
# Cross-repo we cannot verify the HR015 ledger was written in the same atomic
# operation, so the marker is the reviewer's hook. Source:
# memory/feedback_shipping_ledger_after_every_write.md
#
# Usage:
#   scripts/enforce_ledger_write.sh --base-ref <ref> --head-sha <sha> \
#       [--pr-body-file <file>] [--changed-files-file <file>]
#
# --changed-files-file exists for tests; without it the diff is computed with
# git and both refs must be present in the checkout.
#
# Exit 0 = pass (not triggered, or the marker is present).
#      1 = BLOCK (triggered, no marker).
#      3 = CANNOT-RUN (the diff could not be computed, so nothing was examined).
#
# macOS /bin/bash 3.2 + BSD userland. No grep -P, no sed \b. `grep -F` for any
# literal pattern containing `$`.
# British English; " -- " not em-dashes.
# ============================================================================

set -uo pipefail

BASE_REF=""
HEAD_SHA=""
PR_BODY_FILE=""
CHANGED_FILE=""
LEDGER_MARKER="${LEDGER_MARKER:-[ledger-entry:}"
BYPASS_MARKER="${BYPASS_MARKER:-[skip-ledger-enforce:}"

while [ $# -gt 0 ]; do
    case "$1" in
        --base-ref)            BASE_REF="$2"; shift 2 ;;
        --head-sha)            HEAD_SHA="$2"; shift 2 ;;
        --pr-body-file)        PR_BODY_FILE="$2"; shift 2 ;;
        --changed-files-file)  CHANGED_FILE="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -t 1 ]; then C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
else C_G=""; C_R=""; C_Y=""; C_0=""; fi

echo "=== SHIPPING_LEDGER write-discipline gate (vendored, runs in THIS repo) ==="

# ---------------------------------------------------------------------------
# The changed-file set. A gate that examined nothing must never report clean.
# ---------------------------------------------------------------------------
CHANGED=""
if [ -n "${CHANGED_FILE}" ]; then
    if [ ! -r "${CHANGED_FILE}" ]; then
        echo "  ${C_R}CANNOT-RUN${C_0}  --changed-files-file not readable: ${CHANGED_FILE}" >&2
        exit 3
    fi
    CHANGED="$(cat "${CHANGED_FILE}")"
    SOURCE_DESC="file ${CHANGED_FILE}"
else
    if [ -z "${BASE_REF}" ] || [ -z "${HEAD_SHA}" ]; then
        echo "  ${C_R}CANNOT-RUN${C_0}  --base-ref and --head-sha are both required" >&2
        echo "        without them there is no diff to examine, and an unexamined diff" >&2
        echo "        must never be reported as a clean one." >&2
        exit 3
    fi
    if ! git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null; then
        echo "  ${C_R}CANNOT-RUN${C_0}  base ref not present in this checkout: ${BASE_REF}" >&2
        echo "        fetch-depth must be 0 for the diff to resolve." >&2
        exit 3
    fi
    if ! git rev-parse --verify --quiet "${HEAD_SHA}^{commit}" >/dev/null; then
        echo "  ${C_R}CANNOT-RUN${C_0}  head sha not present in this checkout: ${HEAD_SHA}" >&2
        exit 3
    fi
    # FROM THE MERGE BASE, not from the base branch tip.
    #
    # The HR015 original diffed `origin/<base>..<head>`, which answers "how do
    # these two trees differ" and NOT "what did this PR change". On any branch
    # that is behind, every file MAIN touched shows up as changed. Measured on
    # this very PR (#493) in run 32225829777: the PR changes 6 files, the gate
    # saw 25, and it fired on
    #     vendor/cm041/assistant_api/test_vendor_import.sh
    #     vendor/imessage_source/launchd/com.creativemachines.ostler.imessage-bundle.plist
    # neither of which the PR touches. Main did.
    #
    # The merge base is computed and PRINTED rather than relying on `...`
    # notation, because two-dot and three-dot mean opposite things for ranges
    # and for diffs and nobody should have to remember which is which here.
    MB="$(git merge-base "${BASE_REF}" "${HEAD_SHA}" 2>/dev/null)"
    if [ -z "${MB}" ]; then
        echo "  ${C_R}CANNOT-RUN${C_0}  no merge base between ${BASE_REF} and ${HEAD_SHA}" >&2
        echo "        histories are unrelated or the fetch was shallow. fetch-depth must be 0." >&2
        exit 3
    fi
    CHANGED="$(git diff --name-only --diff-filter=ACMR "${MB}" "${HEAD_SHA}")"
    SOURCE_DESC="git diff --name-only --diff-filter=ACMR ${MB} ${HEAD_SHA} (merge base of ${BASE_REF} and ${HEAD_SHA})"
    DIFF_BASE="${MB}"
fi
DIFF_BASE="${DIFF_BASE:-${BASE_REF}}"

N_CHANGED="$(printf '%s' "${CHANGED}" | grep -c . )"
echo "  changed-file source: ${SOURCE_DESC}"
echo "  files in the diff:   ${N_CHANGED}"

if [ "${N_CHANGED}" -eq 0 ]; then
    echo "  ${C_R}CANNOT-RUN${C_0}  0 changed files" >&2
    echo "        a PR with an empty diff is not a PR this gate can clear. Zero examined" >&2
    echo "        is not zero problems -- re-run once the diff resolves." >&2
    exit 3
fi

# ---------------------------------------------------------------------------
# Trigger detection.
# ---------------------------------------------------------------------------
FIRED=0
REASONS=""
note() { FIRED=1; REASONS="${REASONS}    * $1
"; }

hits_cut_manifests="$(printf '%s\n' "${CHANGED}" | grep -c '\(^\|/\)cut-manifests/' || true)"
[ "${hits_cut_manifests:-0}" -gt 0 ] && note "cut-manifests/ touched (${hits_cut_manifests} file(s))"

hits_buildbin="$(printf '%s\n' "${CHANGED}" | grep -c '\(^\|/\)release/build-binary\.sh$' || true)"
[ "${hits_buildbin:-0}" -gt 0 ] && note "release/build-binary.sh touched"

hits_vendor="$(printf '%s\n' "${CHANGED}" | grep -c '\(^\|/\)vendor/' || true)"
[ "${hits_vendor:-0}" -gt 0 ] && note "vendored file touched (${hits_vendor} file(s))"

# For the two version-pin files, a touch is not enough: the PIN LINES must have
# changed. Needs a real diff, so it is skipped in --changed-files-file mode and
# that skip is PRINTED rather than silently dropped.
PIN_SCAN="measured"
if [ -n "${CHANGED_FILE}" ]; then
    PIN_SCAN="NOT measured (--changed-files-file mode has no diff to read)"
else
    for p in $(printf '%s\n' "${CHANGED}" | grep '\(^\|/\)gui/Makefile$' || true); do
        if git diff --unified=0 "${DIFF_BASE}" "${HEAD_SHA}" -- "$p" \
             | grep '^+' | grep -v '^+++' \
             | grep -w 'DAEMON_VERSION\|DAEMON_SHA256' >/dev/null 2>&1; then
            note "${p}: a DAEMON_VERSION|DAEMON_SHA256 line changed"
        fi
    done
    for p in $(printf '%s\n' "${CHANGED}" | grep '\(^\|/\)install\.sh$' || true); do
        if git diff --unified=0 "${DIFF_BASE}" "${HEAD_SHA}" -- "$p" \
             | grep '^+' | grep -v '^+++' \
             | grep -w 'OSTLER_ASSISTANT_VERSION\|DEFAULT_ASSISTANT_TARBALL_SHA256' >/dev/null 2>&1; then
            note "${p}: an OSTLER_ASSISTANT_VERSION|DEFAULT_ASSISTANT_TARBALL_SHA256 line changed"
        fi
    done
fi
echo "  version-pin line scan: ${PIN_SCAN}"

if [ "${FIRED}" -eq 0 ]; then
    echo
    echo "  ${C_G}PASS${C_0}  no shipping-adjacent path in the ${N_CHANGED} changed file(s) -- ledger marker not required"
    exit 0
fi

echo
echo "  shipping-adjacent changes detected:"
printf '%s' "${REASONS}"

# ---------------------------------------------------------------------------
# Marker check. grep -F throughout: both markers contain `[`, and BSD grep
# treats an unescaped `[` as a bracket expression.
# ---------------------------------------------------------------------------
BODY=""
if [ -n "${PR_BODY_FILE}" ] && [ -r "${PR_BODY_FILE}" ]; then
    BODY="$(cat "${PR_BODY_FILE}")"
fi
BODY_BYTES="$(printf '%s' "${BODY}" | wc -c | tr -d '[:space:]')"
echo "  PR body: ${BODY_BYTES} byte(s) read from ${PR_BODY_FILE:-<none supplied>}"

# A MARKER WHOSE PAYLOAD IS THE TEMPLATE IS NOT A MARKER.
#
# Caught by the gate's own first live run, 32225829777 on PR #493. That PR body
# explains the rule in prose and therefore contains the literal string
#     [skip-ledger-enforce: <reason>]
# The original logic did a bare substring match, accepted it, and reported the
# enforcement BYPASSED. Every PR that documents the rule, copies the template
# out of the README, or leaves the checklist unfilled would have waved itself
# through. That is a false GREEN in the gate's single decision.
#
# So the payload must be real: non-empty, and not a `<...>` placeholder.
# Encodes feedback_a_placeholder_that_expands_is_not_a_placeholder.
marker_payload() { # $1 = marker regex body -> echoes the payload, trimmed
    printf '%s' "${BODY}" | grep -o "\\[$1:[^]]*\\]" | head -1 \
      | sed -e "s/^\\[$1:[[:space:]]*//" -e 's/\][[:space:]]*$//' \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
is_placeholder() { # $1 = payload -> 0 when it is a template stub
    case "$1" in
        ''|'<'*'>') return 0 ;;
    esac
    [ "${#1}" -lt 8 ] && return 0
    return 1
}

BYPASS_RAW="$(printf '%s' "${BODY}" | grep -o '\[skip-ledger-enforce:[^]]*\]' | head -1)"
LEDGER_RAW="$(printf '%s' "${BODY}" | grep -o '\[ledger-entry:[^]]*\]' | head -1)"

if [ -n "${BYPASS_RAW}" ]; then
    reason="$(marker_payload 'skip-ledger-enforce')"
    if is_placeholder "${reason}"; then
        echo "  ${C_R}FAIL${C_0}  the bypass marker is present but its reason is the TEMPLATE, not a reason" >&2
        echo "        measured: PR body contains ${BYPASS_RAW}" >&2
        echo "        measured: payload after the colon = '${reason}' (${#reason} chars)" >&2
        echo "        expected: a real reason, at least 8 characters, not a <...> placeholder" >&2
        echo "        a body that merely quotes the template -- documenting the rule, copying" >&2
        echo "        the README, or leaving the checklist unfilled -- must not wave itself through." >&2
        exit 1
    fi
    echo "  ${C_Y}WARN${C_0}  enforcement bypassed by PR body marker: ${BYPASS_RAW}"
    echo "        reviewer: verify that reason before merging."
    exit 0
fi
if [ -n "${LEDGER_RAW}" ]; then
    link="$(marker_payload 'ledger-entry')"
    if is_placeholder "${link}"; then
        echo "  ${C_R}FAIL${C_0}  the ledger marker is present but its payload is the TEMPLATE, not a link" >&2
        echo "        measured: PR body contains ${LEDGER_RAW}" >&2
        echo "        measured: payload after the colon = '${link}' (${#link} chars)" >&2
        echo "        expected: a URL to the HR015 SHIPPING_LEDGER.yaml PR or commit" >&2
        exit 1
    fi
    case "${link}" in
        http://*|https://*) : ;;
        *)
            echo "  ${C_R}FAIL${C_0}  the ledger marker payload is not a URL" >&2
            echo "        measured: PR body contains ${LEDGER_RAW}" >&2
            echo "        measured: payload after the colon = '${link}'" >&2
            echo "        expected: an http(s) URL to the HR015 SHIPPING_LEDGER.yaml PR or commit," >&2
            echo "                  because a reviewer has to be able to open it" >&2
            exit 1 ;;
    esac
    echo "  ${C_G}PASS${C_0}  PR body references a SHIPPING_LEDGER.yaml entry: ${LEDGER_RAW}"
    echo "        reviewer: verify the linked entry lands before merging."
    exit 0
fi

echo "  ${C_R}FAIL${C_0}  this PR changes shipping behaviour and its body records no ledger entry" >&2
echo "        measured: ${N_CHANGED} changed file(s) from ${SOURCE_DESC}" >&2
echo "        measured: PR body = ${BODY_BYTES} byte(s), containing neither" >&2
echo "                  '${LEDGER_MARKER}' nor '${BYPASS_MARKER}'" >&2
echo "        expected: one of those two markers in the PR description" >&2
echo "" >&2
echo "        Add ONE of these to the PR description:" >&2
echo "          [ledger-entry: <URL to the HR015 SHIPPING_LEDGER.yaml PR or commit>]" >&2
echo "          [skip-ledger-enforce: <reason>]" >&2
echo "" >&2
echo "        Source: memory/feedback_shipping_ledger_after_every_write.md" >&2
exit 1
