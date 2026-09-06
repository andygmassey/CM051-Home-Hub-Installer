#!/usr/bin/env bash
# The known-failing fixture for tests/test_egress_inventory_is_current.sh.
#
# WHY THIS FILE EXISTS. verify_declared_gates_reachable.sh reported
# PROVED-RED-NONE against that gate, and it was right: I had mutation-tested it
# by hand and committed no proof. A gate whose only evidence of discrimination
# is a transcript somebody once read is a description of a proof.
#
# The distinction this repo draws, in that script's own words: "a known-failing
# fixture is the only evidence that separates 'found nothing' from 'cannot see'."
#
# It builds a REAL git repository, because the property under test is a
# relationship between two files' HISTORIES -- has anything touched the egress
# allowlist since the inventory was last written -- and no amount of file
# content can stand in for that.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
SUBJECT="${REPO}/tests/test_egress_inventory_is_current.sh"

PASS=0; FAIL=0; CANT=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { CANT=$((CANT+1)); printf '  [CANNOT-RUN] %s\n' "$1"; }

echo "== the egress-inventory gate can actually go red =="
echo

[ -r "${SUBJECT}" ] || { cant "subject missing at ${SUBJECT}"; echo "== 0/0/1 =="; exit 2; }
command -v git >/dev/null 2>&1 || { cant "git unavailable"; echo "== 0/0/1 =="; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ── build a scratch repo the subject can run inside ────────────────────────
# The subject resolves its repo root as the parent of its own directory, so it
# is copied to <scratch>/tests/ and finds <scratch> as the root.
build() {   # $1 = dir
    local d="$1"
    mkdir -p "${d}/tests" "${d}/docs" "${d}/scripts/box_walk_probes"
    cp "${SUBJECT}" "${d}/tests/"

    # An inventory long enough to clear the subject's own size floor, and one
    # that states a measured-on version so arm 1 is satisfied and cannot be the
    # reason for a red below.
    {
        printf '# Egress inventory (fixture)\n\n'
        printf 'Measured on a fixture box running v1.0.33, 2026-08-17.\n\n'
        for i in $(seq 1 80); do printf 'filler line %s so the size floor is cleared\n' "${i}"; done
    } > "${d}/docs/EGRESS_INVENTORY.md"

    # An allowlist with enough rows to clear the subject's floor.
    for i in $(seq 1 20); do printf 'host%s.example.invalid\n' "${i}"; done \
        > "${d}/scripts/box_walk_probes/egress_hosts.tsv"

    ( cd "${d}" \
      && git init -q . \
      && git config user.email t@example.invalid \
      && git config user.name t \
      && git add -A \
      && git commit -qm "fixture: inventory and allowlist written together" ) >/dev/null 2>&1
}

run_subject() {   # $1 = dir  -> prints rc
    ( cd "$1" && /bin/bash tests/test_egress_inventory_is_current.sh >"$1/out.txt" 2>&1; echo $? )
}

# ── THE GREEN CASE ─────────────────────────────────────────────────────────
# Both files written in the same commit, so nothing has touched the allowlist
# since the inventory. This must PASS, or the red below proves nothing: a gate
# that fails on everything is not discriminating, it is broken.
build "${TMP}/green"
GREEN_RC="$(run_subject "${TMP}/green")"
if [ "${GREEN_RC}" = "0" ]; then
    ok "green case: an inventory written alongside its allowlist passes (rc=0)"
else
    bad "green case: a clean fixture FAILED (rc=${GREEN_RC}). The gate fails on everything, so it discriminates nothing."
    sed 's/^/           /' "${TMP}/green/out.txt" | head -12
fi

# ── THE RED CASE ───────────────────────────────────────────────────────────
# One further commit touches ONLY the allowlist. The inventory now describes a
# superseded destination set, which is the whole property.
build "${TMP}/red"
( cd "${TMP}/red" \
  && printf 'a-newly-added-destination.example.invalid\n' >> scripts/box_walk_probes/egress_hosts.tsv \
  && git add -A \
  && git -c user.email=t@example.invalid -c user.name=t commit -qm "adds a destination after the inventory" ) >/dev/null 2>&1

# Prove the mutation LANDED before reading the verdict: a failed setup returns
# the green you were hoping for.
PLANTED="$( cd "${TMP}/red" && git log --oneline -- scripts/box_walk_probes/egress_hosts.tsv | wc -l | tr -d ' ' )"
if [ "${PLANTED}" -lt 2 ]; then
    cant "the red fixture's second commit did not land (${PLANTED} commits touch the allowlist), so the arm below is unproven"
else
    ok "the red fixture landed: ${PLANTED} commits touch the allowlist, the later one after the inventory"
    RED_RC="$(run_subject "${TMP}/red")"
    # Compared NUMERICALLY against a non-zero expectation, on purpose: this is
    # the shape verify_declared_gates_reachable.sh looks for when deciding
    # whether a fixture actually asserts a RED, and a string compare does not
    # match it. The requirement is sound -- "rc is 1" is a numeric claim.
    if [ "${RED_RC}" -eq 1 ]; then
        ok "red case: a destination added after the inventory makes the gate FAIL (rc=1)"
        if grep -q "changed the destination set since the inventory" "${TMP}/red/out.txt"; then
            ok "red case: and it fails for the RIGHT reason, naming the destination set"
        else
            bad "red case: it failed, but not with the destination-set message. It may be red for an unrelated reason."
            sed 's/^/           /' "${TMP}/red/out.txt" | grep -E '\[FAIL\]|\[CANNOT-RUN\]' | head -4
        fi
    else
        bad "red case: a destination added after the inventory did NOT fail the gate (rc=${RED_RC}). The gate cannot say no."
        sed 's/^/           /' "${TMP}/red/out.txt" | head -12
    fi
fi

echo
printf '== %d pass / %d fail / %d cannot-run ==\n' "$PASS" "$FAIL" "$CANT"
[ "$FAIL" -gt 0 ] && exit 1
[ "$CANT" -gt 0 ] && exit 2
exit 0
