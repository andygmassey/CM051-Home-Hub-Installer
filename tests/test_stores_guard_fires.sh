#!/usr/bin/env bash
#
# test_stores_guard_fires.sh
#
# #550 -- THE MUTATION ARM FOR test_stores_publish_no_host_port.sh.
#
# That guard passing proves nothing on its own. It would pass identically
# if its predicate were broken, if a service block were renamed out from
# under it, or if someone replaced its body with `exit 0`. A gate that has
# never been seen to REJECT anything is a gate that compiles, not a gate
# that fires.
#
# This test re-introduces the exact defect #550 was raised for, ONCE PER
# PROTECTED SERVICE --
#
#     ports:
#       - "127.0.0.1:<port>:<port>"
#
# -- and requires the guard to return non-zero EACH TIME. A guard that
# catches qdrant and is blind to redis would pass a single-arm mutation
# test. Then it restores the tree and requires the guard to return zero
# again, so a failure here can never leave a mutated install.sh behind
# for a later step to read.
#
# It lives as a TEST rather than as inline workflow YAML deliberately:
# logic embedded in a `run:` block cannot be executed locally, so it rots
# unseen and is only ever exercised by the CI it is supposed to validate.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
GUARD="$REPO_ROOT/tests/test_stores_publish_no_host_port.sh"
BACKUP="$(mktemp -t ostler-550-install.XXXXXX)"

# Must match MUST_NOT_PUBLISH in the guard. Kept as a literal rather than
# parsed out of the guard on purpose: if someone deletes a service from
# the guard's list, this list still names it and the run goes RED, which
# is the conversation we want. A mutation arm that reads its subjects
# from the thing it is testing cannot notice that subject disappearing.
SERVICES=(
    "qdrant:6334"
)
# redis:6379 is deliberately NOT here yet -- see the long note in
# tests/test_stores_publish_no_host_port.sh. It has a host-side PROBER
# (the Doctor), so unpublishing it without removing that probe reds the
# Doctor on every install.
#
# 📌 THIS LIST AND THE GUARD'S MUST_NOT_PUBLISH MUST MOVE TOGETHER, and
# that is enforced by construction: a service named here but absent from
# the guard makes ARM 2 fail, because the guard will not reject the
# mutation. That is not a nuisance -- it is the check that stops a
# service being quietly dropped from protection while the mutation arm
# still claims to be proving it. It fired on me while writing this.

cleanup() {
    if [ -f "$BACKUP" ]; then
        cp "$BACKUP" "$INSTALL_SH"
        rm -f "$BACKUP"
    fi
}
trap cleanup EXIT INT TERM

[ -f "$INSTALL_SH" ] || { echo "FAIL: install.sh not found -- CANNOT-RUN" >&2; exit 1; }
[ -f "$GUARD" ]      || { echo "FAIL: the guard under test is missing -- CANNOT-RUN" >&2; exit 1; }

cp "$INSTALL_SH" "$BACKUP"

# apply_mutation <service> <port-to-publish>
#
# Inserts a `ports:` publish of <port-to-publish> into <service>'s compose
# block. The port is a PARAMETER, not the service's own port, because the
# arms below need to mutate with a port that is NOT in any named list --
# see THE ISOLATING ARM.
apply_mutation() {
    python3 - "$INSTALL_SH" "$1" "$2" <<'PY'
import sys

path, svc, port = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().split("\n")

# Locate the service block, then insert a publish immediately before the
# block's `volumes:` key. Generic across services -- no per-service text
# anchor to rot when a comment or an image pin is edited.
start = None
for i, line in enumerate(lines):
    if line == f"  {svc}:":
        if start is not None:
            raise SystemExit(
                f"CANNOT-RUN: '  {svc}:' appears more than once. The mutation "
                "would be ambiguous. FIX THIS ARM rather than deleting it -- "
                "without it the guard has no proof of life for this service."
            )
        start = i
if start is None:
    raise SystemExit(
        f"CANNOT-RUN: no '  {svc}:' service block found. Either the service "
        "was removed (drop it from SERVICES in the mutation arm AND from "
        "MUST_NOT_PUBLISH in the guard) or the compose was restructured."
    )

end = len(lines)
for i in range(start + 1, len(lines)):
    line = lines[i]
    if line.startswith("  ") and not line.startswith("   ") and line.rstrip().endswith(":"):
        end = i
        break

target = None
for i in range(start + 1, end):
    if lines[i] == "    volumes:":
        target = i
        break
if target is None:
    raise SystemExit(
        f"CANNOT-RUN: no '    volumes:' key inside the {svc} block to anchor "
        "the mutation against. FIX THIS ARM rather than deleting it."
    )

lines[target:target] = ["    ports:", f'      - "127.0.0.1:{port}:{port}"']
open(path, "w").write("\n".join(lines))
PY
}

# ── ARM 1: the tree as committed. The guard must PASS. ───────────────
if ! bash "$GUARD" >/dev/null 2>&1; then
    echo "FAIL: the guard is RED on the committed tree." >&2
    echo "      Either a store publishes a port (the defect is live) or the" >&2
    echo "      guard is broken. Run it directly for the detail." >&2
    exit 1
fi
echo "ok: arm 1 -- guard PASSES on the committed tree"

# ── ARM 2..N: one mutation per protected service. ────────────────────
arm=1
for entry in "${SERVICES[@]}"; do
    svc="${entry%%:*}"
    port="${entry##*:}"
    arm=$((arm + 1))

    cp "$BACKUP" "$INSTALL_SH"

    apply_mutation "$svc" "$port"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: could not apply the ${svc} mutation (rc=${rc})" >&2
        echo "      -- CANNOT-RUN, not a pass" >&2
        exit 1
    fi

    if bash "$GUARD" >/dev/null 2>&1; then
        echo "FAIL: THE GUARD PASSED WITH THE ${svc} DEFECT PRESENT." >&2
        echo "      It cannot detect a published ${port}, so every green" >&2
        echo "      verdict it has ever given for ${svc} is meaningless." >&2
        echo "      This is a broken gate, not a safe tree." >&2
        exit 1
    fi
    echo "ok: arm ${arm} -- guard REJECTS the reintroduced ${svc} ${port} publish"
done

# ── THE ISOLATING ARM: prove the GENERIC assertion is the one firing ──
#
# TNM's #1209 review, and it is the finding that matters most about this
# file.
#
# The arms above insert the service's OWN protected port, and the guard has
# TWO independent ways to reject that input: the generic pattern assertion,
# and an unpiped belt-and-braces grep for that port BY NAME. The second
# fires regardless of the first. So those arms prove THE FILE rejects the
# port; they do NOT prove THE GENERIC ASSERTION does. With the generic
# assertion completely broken they would still pass -- and effectively did:
# the `printf | grep -q` inversion in that assertion was caught by the
# pipefail ratchet, never by this harness.
#
# 📌 A control that can be satisfied by a mechanism OTHER than the one under
# test is not a control for that mechanism. That is the same error this
# whole #550 family is made of, and it was sitting in the proof-of-life.
#
# This arm publishes a port that appears in NO named list, so the by-name
# grep cannot fire and ONLY the generic assertion can. That assertion is the
# one whose entire stated purpose is to catch the SEVENTH instance: a port
# nobody has enumerated yet.
DECOY_PORT=65533

# The isolation is a PREMISE, so check it rather than trusting it. If the
# decoy ever appears in the guard, this arm silently stops isolating and
# quietly becomes a duplicate of the arms above.
if grep -q "$DECOY_PORT" "$GUARD"; then
    echo "FAIL: decoy port ${DECOY_PORT} now appears in the guard, so this arm" >&2
    echo "      no longer isolates the generic assertion -- a by-name check" >&2
    echo "      could satisfy it. Pick a different decoy." >&2
    echo "      CANNOT-RUN, not a pass." >&2
    exit 1
fi

arm=$((arm + 1))
cp "$BACKUP" "$INSTALL_SH"
apply_mutation "${SERVICES[0]%%:*}" "$DECOY_PORT"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: could not apply the decoy mutation (rc=${rc}) -- CANNOT-RUN" >&2
    exit 1
fi

if bash "$GUARD" >/dev/null 2>&1; then
    echo "FAIL: THE GUARD PASSED ON AN UNNAMED PUBLISHED PORT (${DECOY_PORT})." >&2
    echo "      No by-name check covers it, so this proves the GENERIC" >&2
    echo "      assertion is not working. That assertion is the only thing" >&2
    echo "      standing between us and the seventh instance -- a port that" >&2
    echo "      nobody has enumerated. The guard is decorative without it." >&2
    exit 1
fi
echo "ok: arm ${arm} -- guard REJECTS an UNNAMED published port (generic assertion is live)"

# ── FINAL ARM: restore, and prove the restore worked. ────────────────
cp "$BACKUP" "$INSTALL_SH"
if ! bash "$GUARD" >/dev/null 2>&1; then
    echo "FAIL: the guard is still RED after restore -- the tree was left" >&2
    echo "      mutated. Any later step reading install.sh would be reading" >&2
    echo "      the wrong artefact." >&2
    exit 1
fi
echo "ok: arm $((arm + 1)) -- tree restored, guard green again"

echo ""
echo "store guard mutation proof: PASS ($((arm + 1)) arms, ${#SERVICES[@]} services)"
