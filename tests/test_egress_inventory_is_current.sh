#!/usr/bin/env bash
# PROVED-RED-BY: tests/test_egress_inventory_gate_can_go_red.sh
#
# That fixture builds a real git repository twice: once with the inventory and
# the allowlist written in the same commit (must PASS), and once with a further
# commit touching only the allowlist (must FAIL, and fail naming the destination
# set). Both arms matter -- without the green one, a gate that fails on
# everything would score as discriminating.
#
# It exists because verify_declared_gates_reachable.sh reported PROVED-RED-NONE
# against this file and was right: it had been mutation-tested by hand and no
# proof was committed, which is a description of a proof rather than a proof.
#
# CM051 #1709 -- docs/EGRESS_INVENTORY.md is a PUBLIC privacy document in a
# PUBLIC repo, and nothing checked that it still describes the software.
#
# GUARD THE PROPERTY, NOT THE PROXY. The obvious check is "does the inventory's
# declared version match the newest cut manifest". That is a LABEL, and it would
# go red on every routine version bump while staying green if someone added a
# destination without bumping. The actual question is:
#
#     has the DESTINATION SET changed since the inventory was measured?
#
# which is answerable directly: if any commit has touched
# scripts/box_walk_probes/egress_hosts.tsv since the inventory's own last commit,
# the document describes a superseded set and must be re-measured.
#
# WHY IT MATTERS MORE THAN AN INTERNAL DOC. CM051 is public. This file is the
# artefact a sceptic reads instead of taking our word for it, and
# project_publish_the_verification_not_the_source is explicit that a stale one is
# a cut blocker rather than a docs task. At the time of writing it was measured
# on v1.0.33 against a newest manifest of v1.0.73 -- and still ACCURATE, because
# egress_hosts.tsv had 46 rows then and 46 rows now. Accurate by luck. This gate
# converts the luck into a control.
#
# THE PUBLISHED NEGATIVE CONTROL IS SEPARATELY DECLARED, NOT ASSUMED. Step 3 of
# that plan -- ship the pass run AND a deliberate-leak run showing the harness
# catching it -- is absent from the document. Running that experiment needs a box
# with an install; this machine has none. So arm 4 makes its absence a DATED
# admission rather than silence, exactly as the CM031 dark-suite gate does.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
cd "${REPO}" || exit 2

INVENTORY="docs/EGRESS_INVENTORY.md"
ALLOWLIST="scripts/box_walk_probes/egress_hosts.tsv"

# ── the declaration for the missing published negative control ──────────────
NEGCTRL_REASON="The deliberate-leak run needs a Mac with a real install; the
    machine this was written on has none and its store ports return 000 against a
    control of 200. Tracked on #1709. The probe's INTERNAL positive control
    already exists and is strong; what is missing is the published half."
NEGCTRL_EXPIRES="2026-10-31"

PASS=0; FAIL=0; CANT=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { CANT=$((CANT+1)); printf '  [CANNOT-RUN] %s\n' "$1"; }

echo "== the published egress inventory still describes the software =="
echo

for f in "${INVENTORY}" "${ALLOWLIST}"; do
    [ -r "${f}" ] || { cant "${f} unreadable"; echo; printf '== %d pass / %d fail / %d cannot-run ==\n' "$PASS" "$FAIL" "$CANT"; exit 2; }
done

# A validator passes on an empty subject.
_inv_lines="$(wc -l < "${INVENTORY}" | tr -d ' ')"
_allow_rows="$(grep -vc '^#' "${ALLOWLIST}" || true)"
if [ "${_inv_lines}" -lt 50 ] || [ "${_allow_rows}" -lt 10 ]; then
    cant "inventory ${_inv_lines} lines, allowlist ${_allow_rows} rows -- too small to be the real files"
    echo; printf '== %d pass / %d fail / %d cannot-run ==\n' "$PASS" "$FAIL" "$CANT"; exit 2
fi
ok "subjects present: inventory ${_inv_lines} lines, allowlist ${_allow_rows} destination rows"

# ── ARM 1: the inventory says WHEN it was measured ──────────────────────────
# A privacy document that does not date itself cannot be audited for staleness
# by anyone, us included.
MEASURED="$(grep -m1 -oE 'v1\.0\.[0-9]+, 2026-[0-9]{2}-[0-9]{2}' "${INVENTORY}" || true)"
if [ -n "${MEASURED}" ]; then
    ok "arm 1: the inventory states what it was measured on: ${MEASURED}"
else
    bad "arm 1: the inventory does not state a version and date it was measured on"
fi

# ── ARM 2: THE PROPERTY. Has the destination set moved since? ───────────────
if ! git -C "${REPO}" rev-parse --git-dir >/dev/null 2>&1; then
    cant "arm 2: not a git checkout, so 'changed since' cannot be answered"
else
    INV_COMMIT="$(git -C "${REPO}" log -1 --format=%H -- "${INVENTORY}" 2>/dev/null || true)"
    if [ -z "${INV_COMMIT}" ]; then
        cant "arm 2: no commit history for ${INVENTORY} (shallow clone?). Needs fetch-depth: 0."
    else
        SINCE="$(git -C "${REPO}" log --format=%h "${INV_COMMIT}..HEAD" -- "${ALLOWLIST}" 2>/dev/null || true)"
        N_SINCE="$(printf '%s\n' "${SINCE}" | grep -c . || true)"
        if [ "${N_SINCE}" -eq 0 ]; then
            ok "arm 2: no commit has touched ${ALLOWLIST##*/} since the inventory was last written (${INV_COMMIT:0:8})"
        else
            bad "arm 2: ${N_SINCE} commit(s) changed the destination set since the inventory was last written. It describes a superseded set and must be re-measured:"
            printf '%s\n' "${SINCE}" | sed 's/^/           /'
        fi
    fi
fi

# ── ARM 3: the inventory's own row claim, if it makes one ──────────────────
# Only checked when the document states a number, so this cannot invent a
# requirement the document never made.
CLAIMED="$(grep -oE '\b[0-9]{2,3} (destination|allowed|egress) rows' "${INVENTORY}" | grep -oE '^[0-9]+' | head -1 || true)"
if [ -z "${CLAIMED}" ]; then
    ok "arm 3: the inventory states no row count, so there is none to contradict"
elif [ "${CLAIMED}" = "${_allow_rows}" ]; then
    ok "arm 3: the inventory's claimed ${CLAIMED} rows matches the allowlist"
else
    bad "arm 3: the inventory claims ${CLAIMED} rows; the allowlist has ${_allow_rows}"
fi

# ── ARM 4: the published negative control, declared or present ──────────────
# project_publish_the_verification_not_the_source calls this "the part nobody
# else does": ship the pass run AND a planted-leak run the harness catches, so a
# reader learns the test CAN fail.
if grep -qiE 'negative control|planted leak|deliberate leak' "${INVENTORY}"; then
    ok "arm 4: the inventory publishes a negative control"
elif [ -z "${NEGCTRL_REASON}" ]; then
    bad "arm 4: no published negative control and nothing declares its absence. A reader sees only a green."
else
    TODAY="$(date -u +%Y-%m-%d)"
    if [ -z "${NEGCTRL_EXPIRES}" ]; then
        bad "arm 4: the negative-control declaration carries no expiry date"
    elif [ "${NEGCTRL_EXPIRES}" \< "${TODAY}" ]; then
        bad "arm 4: the negative-control declaration EXPIRED on ${NEGCTRL_EXPIRES} (today ${TODAY}). Publish it or re-argue the deferral."
    else
        ok "arm 4: no published negative control, declared until ${NEGCTRL_EXPIRES} with a reason"
        echo "         ${NEGCTRL_REASON}"
    fi
fi

# ── ARM 5: MUTATION CONTROL for arm 2 ──────────────────────────────────────
# Arm 2's green means nothing unless a real change would turn it red. Plant a
# commit touching the allowlist in a scratch clone and assert the predicate sees
# it. Without this, "0 commits since" and "the query is broken" print the same.
if ! command -v git >/dev/null 2>&1; then
    cant "arm 5: git unavailable, so arm 2 is unproven"
else
    TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
    (
      cd "${TMP}" || exit 1
      git init -q .
      git config user.email t@example.invalid; git config user.name t
      mkdir -p docs scripts/box_walk_probes
      echo "inventory" > "docs/EGRESS_INVENTORY.md"
      echo "host.example" > "scripts/box_walk_probes/egress_hosts.tsv"
      git add -A && git commit -q -m base
      echo "second.example" >> "scripts/box_walk_probes/egress_hosts.tsv"
      git add -A && git commit -q -m "adds a destination"
    ) >/dev/null 2>&1
    PLANT_INV="$(git -C "${TMP}" log -1 --format=%H -- docs/EGRESS_INVENTORY.md 2>/dev/null || true)"
    PLANT_SINCE="$(git -C "${TMP}" log --format=%h "${PLANT_INV}..HEAD" -- scripts/box_walk_probes/egress_hosts.tsv 2>/dev/null | grep -c . || true)"
    if [ "${PLANT_SINCE}" -ge 1 ]; then
        ok "arm 5: with a destination planted after the inventory, the predicate FIRES (${PLANT_SINCE}) -- arm 2 is measuring something"
    else
        bad "arm 5: a planted destination change did NOT fire the predicate. Arm 2's green is meaningless."
    fi
fi

echo
printf '== %d pass / %d fail / %d cannot-run ==\n' "$PASS" "$FAIL" "$CANT"
[ "$FAIL" -gt 0 ] && exit 1      # FAIL outranks CANNOT-RUN
[ "$CANT" -gt 0 ] && exit 2
exit 0
