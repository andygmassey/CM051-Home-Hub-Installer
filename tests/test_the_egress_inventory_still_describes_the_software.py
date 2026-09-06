#!/usr/bin/env python3
"""#1709. `docs/EGRESS_INVENTORY.md` describes what leaves the Mac. Nothing
checked that it still described the software.

Measured at origin/main on 2026-09-06, before this gate existed:

    inventory's own measurement stamp   v1.0.33, 2026-08-17
    newest cut manifest                 v1.0.73
    files gating the inventory          0
    control: files referencing SHIPPING_LEDGER   16

The control is what makes that zero real rather than a broken predicate: the
same search finds sixteen references to a document that IS genuinely wired.

THE DOCUMENT WAS STILL TRUE, AND THAT IS THE POINT. Its ledger,
`scripts/box_walk_probes/egress_hosts.tsv`, held 46 host rows at the
inventory's measurement commit and 46 now. The published claim survived by
luck rather than by control. The next release that adds an outbound
destination silently makes a privacy document false, in a PUBLIC repo, and
nothing anywhere would go red.

WHAT THIS GATE BINDS, AND WHY NOT THE WHOLE FILE. It binds the inventory to
the SET OF DECLARED HOSTS, not to the file's bytes. A whole-file digest goes
red when somebody fixes a typo in a comment, and a gate that cries at noise
gets its ratchet raised until it means nothing. The host set is exactly the
thing the public claim is ABOUT: change it and the document is stale; reword
a comment and it is not.

THREE STATES. If either file is missing, or the inventory carries no binding
block, this is CANNOT-RUN and exits 2. It is not a pass. A missing binding is
the one failure mode that would otherwise look identical to a clean run.

Run with no arguments to gate the real tree. Run with --self-test to prove the
gate can fail, against fixtures in a temp dir.
"""
import hashlib
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[1]
INVENTORY = pathlib.Path("docs/EGRESS_INVENTORY.md")
LEDGER = pathlib.Path("scripts/box_walk_probes/egress_hosts.tsv")

BINDING_RE = re.compile(
    r"<!--\s*EGRESS-LEDGER-BINDING\s*\n"
    r"\s*hosts:\s*(?P<hosts>\d+)\s*\n"
    r"\s*digest:\s*(?P<digest>[0-9a-f]{64})\s*\n",
    re.MULTILINE,
)

PASS = FAIL = CANNOT = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  [PASS] {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {msg}")


class CouldNotMeasure(Exception):
    pass


def declared_hosts(root):
    """The set of declared hosts, comments and blank lines excluded.

    Sorted and deduplicated, so row ORDER and a duplicate row are not
    treated as a change of claim. What is claimed in public is the set.
    """
    p = root / LEDGER
    if not p.is_file():
        raise CouldNotMeasure(f"the ledger is absent: {LEDGER}")
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as e:
        raise CouldNotMeasure(f"the ledger could not be read: {e}") from e
    hosts = set()
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        hosts.add(line.split("\t", 1)[0].strip())
    hosts.discard("")
    if not hosts:
        # An empty set would digest to a stable value and could silently match
        # a binding written against an empty ledger. Refuse instead.
        raise CouldNotMeasure(
            f"{LEDGER} parsed to ZERO host rows. That is a broken predicate or a "
            f"truncated file, not an inventory of nothing.")
    return sorted(hosts)


def digest_of(hosts):
    h = hashlib.sha256()
    for host in hosts:
        h.update(host.encode("utf-8"))
        h.update(b"\n")
    return h.hexdigest()


# A public privacy document must say WHAT IT WAS MEASURED ON. Without it a
# reader cannot tell whether they are looking at a current statement or an
# archaeological one, and neither can we.
#
# ADDED AFTER A MEASUREMENT, NOT A HUNCH. The binding check above passes with
# this line deleted outright: on origin/main 7cf3a086, removing
# "Measured on a 16 GB M4 Mini running v1.0.33, 2026-08-17." left the gate at
# rc=0, because a digest over the host set says nothing about provenance. So the
# document could lose the only sentence that dates it and nothing would notice.
#
# This is the one arm of TNM's #1711 that is genuinely additive. Its arm 2,
# git-history staleness, is NOT: a ledger change with no doc update is already
# caught by the digest, a change WITH a doc update passes both, and a mere
# reformat of the ledger would have made the history check cry at noise. Credit
# refused where it was not earned.
PROVENANCE_RE = re.compile(
    r"Measured on\b[^\n]*?\bv\d+\.\d+\.\d+\s*,\s*(?P<date>\d{4}-\d{2}-\d{2})")


def provenance_in(root):
    p = root / INVENTORY
    if not p.is_file():
        raise CouldNotMeasure(f"the inventory is absent: {INVENTORY}")
    m = PROVENANCE_RE.search(p.read_text(encoding="utf-8"))
    if not m:
        return None
    return m.group("date")


def check_provenance(root):
    """Returns (verdict, message). Independent of the binding check."""
    try:
        date = provenance_in(root)
    except CouldNotMeasure as e:
        return "CANNOT-RUN", f"{e} -- provenance was NOT checked."
    if date is None:
        return "FAIL", (
            f"{INVENTORY} does not state what it was measured on. A public "
            f"privacy document with no version and no date cannot be audited "
            f"for staleness by a reader, or by us.")
    return "PASS", f"the inventory states what it was measured on: {date}"


def binding_in(root):
    p = root / INVENTORY
    if not p.is_file():
        raise CouldNotMeasure(f"the inventory is absent: {INVENTORY}")
    m = BINDING_RE.search(p.read_text(encoding="utf-8"))
    if not m:
        raise CouldNotMeasure(
            f"{INVENTORY} carries no EGRESS-LEDGER-BINDING block. Without one "
            f"there is nothing to compare, and 'no mismatch found' would be a "
            f"statement about the gate, not about the document.")
    return int(m.group("hosts")), m.group("digest")


def check(root):
    """Returns (verdict, message). verdict in PASS / FAIL / CANNOT-RUN."""
    try:
        hosts = declared_hosts(root)
        want_n, want_d = binding_in(root)
    except CouldNotMeasure as e:
        return "CANNOT-RUN", f"{e} -- NOTHING was compared."
    got_d = digest_of(hosts)
    if got_d == want_d and len(hosts) == want_n:
        return "PASS", (f"the inventory is bound to the ledger it describes: "
                        f"{len(hosts)} declared host(s), digest matches")
    if len(hosts) != want_n:
        return "FAIL", (f"the ledger declares {len(hosts)} host(s), the inventory "
                        f"is bound to {want_n}. A public privacy document now "
                        f"describes software that no longer exists.")
    return "FAIL", (f"host COUNT is unchanged at {len(hosts)} but the SET is not: "
                    f"bound to {want_d[:12]}, ledger is {got_d[:12]}. A destination "
                    f"was swapped for another and the count hid it.")


# --------------------------------------------------------------------------
# self-test. Every arm runs against a fixture tree, never the real one.
# --------------------------------------------------------------------------

def _fixture(tmp, hosts, bound_hosts=None, bound_digest=None, binding=True,
             ledger=True, inventory=True, extra_comment="",
             provenance="Measured on a fixture box running v1.0.33, 2026-08-17."):
    root = pathlib.Path(tmp)
    (root / LEDGER.parent).mkdir(parents=True, exist_ok=True)
    (root / INVENTORY.parent).mkdir(parents=True, exist_ok=True)
    if ledger:
        body = ["# DECLARED EGRESS INVENTORY. host\tpurpose", "#" + extra_comment, ""]
        body += [f"{h}\tsynthetic purpose\tsynthetic payload" for h in hosts]
        (root / LEDGER).write_text("\n".join(body) + "\n", encoding="utf-8")
    if inventory:
        n = bound_hosts if bound_hosts is not None else len(sorted(set(hosts)))
        d = bound_digest if bound_digest is not None else digest_of(sorted(set(hosts)))
        block = ""
        if binding:
            block = f"<!-- EGRESS-LEDGER-BINDING\nhosts: {n}\ndigest: {d}\n-->\n"
        prov = (provenance + "\n\n") if provenance else ""
        (root / INVENTORY).write_text(
            "# Egress inventory\n\n" + prov + block, encoding="utf-8")
    return root


def self_test():
    # Reserved-for-documentation names only. RFC 2606 / RFC 6761.
    BASE = ["a.example.com", "b.example.net", "c.example.org"]
    with tempfile.TemporaryDirectory() as tmp:
        root = _fixture(pathlib.Path(tmp) / "clean", BASE)
        v, m = check(root)
        (ok if v == "PASS" else bad)(f"a bound inventory PASSES ({v}: {m})")

        root = _fixture(pathlib.Path(tmp) / "added", BASE + ["d.example.com"],
                        bound_hosts=len(BASE), bound_digest=digest_of(sorted(BASE)))
        v, m = check(root)
        (ok if v == "FAIL" else bad)(
            f"CONTROL THAT MUST FAIL: adding a destination goes {v}, wanted FAIL")

        root = _fixture(pathlib.Path(tmp) / "removed", BASE[:-1],
                        bound_hosts=len(BASE), bound_digest=digest_of(sorted(BASE)))
        v, m = check(root)
        (ok if v == "FAIL" else bad)(
            f"CONTROL THAT MUST FAIL: removing a destination goes {v}, wanted FAIL")

        # The count-blind case: swap one host for another. A row-count gate
        # would pass this, which is why the digest exists.
        swapped = BASE[:-1] + ["z.example.org"]
        root = _fixture(pathlib.Path(tmp) / "swapped", swapped,
                        bound_hosts=len(BASE), bound_digest=digest_of(sorted(BASE)))
        v, m = check(root)
        (ok if v == "FAIL" else bad)(
            f"CONTROL THAT MUST FAIL: swapping a destination at an unchanged "
            f"COUNT goes {v}, wanted FAIL -- this is the arm a count-only gate loses")

        root = _fixture(pathlib.Path(tmp) / "comment", BASE,
                        extra_comment=" reworded, no claim changed")
        v, m = check(root)
        (ok if v == "PASS" else bad)(
            f"CONTROL THAT MUST PASS: rewording a comment goes {v}, wanted PASS -- "
            f"a gate that cries at noise gets switched off")

        root = _fixture(pathlib.Path(tmp) / "reordered", list(reversed(BASE)))
        v, m = check(root)
        (ok if v == "PASS" else bad)(
            f"CONTROL THAT MUST PASS: reordering rows goes {v}, wanted PASS")

        # ---- provenance: a public document must say when it was measured ----
        # These exercise check_provenance, which is independent of the binding.
        root = _fixture(pathlib.Path(tmp) / "prov-ok", BASE)
        v, m = check_provenance(root)
        (ok if v == "PASS" else bad)(
            f"CONTROL THAT MUST PASS: an inventory stating its version and date "
            f"goes {v}, wanted PASS")

        root = _fixture(pathlib.Path(tmp) / "prov-gone", BASE, provenance="")
        v, m = check_provenance(root)
        (ok if v == "FAIL" else bad)(
            f"CONTROL THAT MUST FAIL: deleting the 'Measured on ... vX, DATE' "
            f"line goes {v}, wanted FAIL -- the binding check passes on this, "
            f"measured on origin/main 7cf3a086, which is why this arm exists")

        # A date with no version, and a version with no date, are both half a
        # provenance and neither answers "which build was this measured on".
        root = _fixture(pathlib.Path(tmp) / "prov-dateonly", BASE,
                        provenance="Measured on a fixture box, 2026-08-17.")
        v, m = check_provenance(root)
        (ok if v == "FAIL" else bad)(
            f"CONTROL THAT MUST FAIL: a date with no version goes {v}, wanted FAIL")

        root = _fixture(pathlib.Path(tmp) / "prov-veronly", BASE,
                        provenance="Measured on a fixture box running v1.0.33.")
        v, m = check_provenance(root)
        (ok if v == "FAIL" else bad)(
            f"CONTROL THAT MUST FAIL: a version with no date goes {v}, wanted FAIL")

        # And the CANNOT-RUN arm, which must not read as either verdict.
        root = _fixture(pathlib.Path(tmp) / "prov-noinv", BASE, inventory=False)
        v, m = check_provenance(root)
        (ok if v == "CANNOT-RUN" else bad)(
            f"an absent inventory goes {v}, wanted CANNOT-RUN not FAIL -- "
            f"'could not look' is not 'looked and found it missing'")

        root = _fixture(pathlib.Path(tmp) / "nobinding", BASE, binding=False)
        v, m = check(root)
        (ok if v == "CANNOT-RUN" else bad)(
            f"an inventory with NO binding block is {v}, wanted CANNOT-RUN not PASS")

        root = _fixture(pathlib.Path(tmp) / "noledger", BASE, ledger=False)
        v, m = check(root)
        (ok if v == "CANNOT-RUN" else bad)(
            f"an absent ledger is {v}, wanted CANNOT-RUN not PASS")

        root = _fixture(pathlib.Path(tmp) / "noinv", BASE, inventory=False)
        v, m = check(root)
        (ok if v == "CANNOT-RUN" else bad)(
            f"an absent inventory is {v}, wanted CANNOT-RUN not PASS")

        root = _fixture(pathlib.Path(tmp) / "emptyledger", [])
        v, m = check(root)
        (ok if v == "CANNOT-RUN" else bad)(
            f"a ledger that parses to zero hosts is {v}, wanted CANNOT-RUN -- "
            f"an empty set has a stable digest and could match a stale binding")


def main():
    if "--self-test" in sys.argv:
        print("== self-test: the gate can fail, and fails for the right reasons ==")
        self_test()
        print(f"\n== {PASS} pass / {FAIL} fail / {PASS + FAIL} total ==")
        return 1 if FAIL else 0

    print("== the egress inventory still describes the software (#1709) ==")

    # Two INDEPENDENT questions, reported separately. "Does the document match
    # the software" and "does the document say when it was written" fail for
    # different reasons and are fixed by different edits, so collapsing them
    # into one verdict would tell the reader the wrong thing to go and do.
    # Both run even when the first fails, or a binding mismatch would hide a
    # missing provenance line until someone fixed the binding.
    verdicts = [check(REPO), check_provenance(REPO)]

    for verdict, msg in verdicts:
        if verdict == "PASS":
            print(f"  [PASS] {msg}")
        elif verdict == "CANNOT-RUN":
            print(f"  [CANNOT-RUN] {msg}")
        else:
            print(f"  [FAIL] {msg}")

    kinds = [v for v, _ in verdicts]
    if "FAIL" in kinds:
        print(f"  Fix: re-measure, then update the EGRESS-LEDGER-BINDING block "
              f"and the 'Measured on ... vX.Y.Z, DATE' line in {INVENTORY}. "
              f"Changing either is asserting that the prose above it was "
              f"reviewed against the new destination.")
        return 1
    if "CANNOT-RUN" in kinds:
        print("  CANNOT-RUN is not a pass. Refusing a verdict.")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
