#!/usr/bin/env bash
#
# scripts/verify_manifest_ack_expiry.sh
#
# D1 + D2 of the v1.0.60 SCOPE: the vendor manifest's ACKS must be time-bounded
# and humanly owned, and a past expiry REFUSES the cut.
#
# WHY THIS EXISTS. The cut-deferral register expires (707 of 709 rows carry a
# date); the VENDOR MANIFEST did not. Measured 2026-09-02: 3 unverifiable_ack +
# 8 hold_ack + 4 verify_exempt, ZERO of them dated, and every `_owner` field a
# ROLE ("ORM, with the <repo> source-repo owner"). A role is whoever holds it,
# so nobody is ever the person who failed to act, and an ack with no end date is
# indistinguishable from a permanent exemption. That is exactly how cm024's
# Apple Notes sat verify=skip behind an unverifiable_ack for SIX WEEKS while
# install.sh advertised a step that could never land a note. This gate is the
# enforcer that turns "filed and forgotten" into "dated, owned, and refused when
# stale".
#
# THE POLICY (Archie, 2026-09-02, a decision not a measurement):
#   1. every unverifiable_ack / hold_ack / verify_exempt carries `expires`, an
#      ABSOLUTE ISO date (YYYY-MM-DD). No relative durations, no "next cut", no
#      null -- a relative date is a date that never arrives.
#   2. maximum life is 30 days from today: `expires` more than 30 days out is
#      refused, so an ack cannot grant itself a year.
#   3. `owner` is a NAME from a closed set { andy, archie, tnm, a2 }. Closed on
#      purpose: an open field drifts back to a role in two edits.
#   4. a PAST `expires` REFUSES (exit 1). It does not warn and it does not
#      auto-renew -- renewal is a human writing a new date.
#
# DELIBERATE DESIGN CHOICE, and it learns from tests/test_expiry_needs_a_cut_version.sh:
#   expiry is an ABSOLUTE DATE compared to today, NOT a cut-version compared to
#   ${OSTLER_CUT_VERSION}. The cut-version predicate has a documented false-zero:
#   on any non-tag run CUT_VERSION is empty and the "expired" set is empty BY
#   CONSTRUCTION, which reads as "nothing expired" when it means "could not
#   look". A date compared to today has no such run-context hole -- it answers
#   the same on every run -- so this gate cannot be silently disarmed by being
#   run off a tag.
#
# tomllib, never a ^-anchored grep: the manifest uses TWO indentation
# conventions (#529) and TOML is not line-oriented; a grep would miscount.
#
# CANNOT-RUN (exit 2) if the manifest is unreadable OR parses to ZERO ack rows.
# A gate that finds no acks because it read the wrong table must not print
# clean -- 0-of-0 is not a pass. See feedback_a_zero_denominator_reads_as_success.
#
# Overrides (for the self-test only):
#   OSTLER_ACK_MANIFEST  path to the manifest (default vendor/VENDOR_MANIFEST.toml)
#   OSTLER_ACK_TODAY     ISO date to treat as "today" (default: the real today)
#
# Exit 0 all acks compliant / 1 a violation / 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${OSTLER_ACK_MANIFEST:-${REPO_ROOT}/vendor/VENDOR_MANIFEST.toml}"
TODAY="${OSTLER_ACK_TODAY:-}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "CANNOT-RUN: python3 not on PATH (exit 2)" >&2
    exit 2
fi

python3 - "$MANIFEST" "$TODAY" <<'PY'
import sys, datetime
try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - python < 3.11
    print("CANNOT-RUN: tomllib unavailable (need python >= 3.11) (exit 2)", file=sys.stderr)
    sys.exit(2)

manifest_path, today_s = sys.argv[1], sys.argv[2]

try:
    with open(manifest_path, "rb") as fh:
        man = tomllib.load(fh)
except FileNotFoundError:
    print(f"CANNOT-RUN: manifest not found: {manifest_path} (exit 2)", file=sys.stderr)
    sys.exit(2)
except Exception as exc:
    print(f"CANNOT-RUN: manifest unparseable ({exc}) (exit 2)", file=sys.stderr)
    sys.exit(2)

today = datetime.date.fromisoformat(today_s) if today_s else datetime.date.today()
max_life = today + datetime.timedelta(days=30)
OWNERS = {"andy", "archie", "tnm", "a2"}


def acks_of(tree):
    """Which ack kinds this tree carries. A tree is 'acked' if it opts out of,
    holds back from, or declares itself unverifiable to the freshness gate."""
    kinds = []
    if tree.get("unverifiable_ack") is True:
        kinds.append("unverifiable_ack")
    if tree.get("verify_exempt") is True:
        kinds.append("verify_exempt")
    if str(tree.get("hold_ack_shas") or "").strip():
        kinds.append("hold_ack")
    return kinds


trees = man.get("tree", [])
ack_trees = [(t.get("name", "?"), t, acks_of(t)) for t in trees if acks_of(t)]

if not ack_trees:
    # 0-of-0 is CANNOT-RUN, never a clean pass: if the parse found no acks it is
    # far likelier the wrong file/table was read than that a manifest which is
    # supposed to carry acks suddenly carries none.
    print(
        "CANNOT-RUN: parsed 0 ack rows from "
        f"{manifest_path} ({len(trees)} tree(s) total). A gate that finds no "
        "acks must not print clean -- suspect the parse. (exit 2)",
        file=sys.stderr,
    )
    sys.exit(2)

violations = []
for name, tree, kinds in ack_trees:
    tag = f"{name} [{'+'.join(kinds)}]"

    exp = tree.get("expires")
    if exp is None:
        violations.append(f"{tag}: no `expires` field (policy 1: mandatory absolute ISO date)")
    else:
        if isinstance(exp, datetime.date) and not isinstance(exp, datetime.datetime):
            d = exp
        else:
            try:
                d = datetime.date.fromisoformat(str(exp))
            except ValueError:
                d = None
                violations.append(f"{tag}: `expires`={exp!r} is not an absolute ISO date (policy 1)")
        if d is not None:
            if d < today:
                violations.append(f"{tag}: EXPIRED ({d} < today {today}) -- a past ack REFUSES the cut (policy 4)")
            elif d > max_life:
                violations.append(f"{tag}: `expires`={d} is >30 days out (max {max_life}) -- an ack may not grant itself long life (policy 2)")

    owner = tree.get("owner")
    if owner is None:
        violations.append(f"{tag}: no `owner` field (policy 3: one of {sorted(OWNERS)})")
    elif str(owner).strip().lower() not in OWNERS:
        violations.append(f"{tag}: owner={owner!r} is not in the closed set {sorted(OWNERS)} -- a role is not an owner (policy 3)")

if violations:
    print(
        f"MANIFEST ACK GATE: RED -- {len(violations)} violation(s) across "
        f"{len(ack_trees)} ack row(s):",
        file=sys.stderr,
    )
    for v in violations:
        print(f"  RED  {v}", file=sys.stderr)
    print(
        "  Every unverifiable_ack / hold_ack / verify_exempt must carry an "
        "absolute ISO `expires` (<=30d out, not past) and an `owner` from "
        f"{sorted(OWNERS)}.",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f"MANIFEST ACK GATE: OK -- {len(ack_trees)} ack row(s), all dated, owned, "
    "and within the 30-day window."
)
sys.exit(0)
PY
