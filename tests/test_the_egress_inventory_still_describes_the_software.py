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
             ledger=True, inventory=True, extra_comment=""):
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
        (root / INVENTORY).write_text("# Egress inventory\n\n" + block, encoding="utf-8")
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
    verdict, msg = check(REPO)
    if verdict == "PASS":
        print(f"  [PASS] {msg}")
        return 0
    if verdict == "CANNOT-RUN":
        print(f"  [CANNOT-RUN] {msg}")
        print("  CANNOT-RUN is not a pass. Refusing a verdict.")
        return 2
    print(f"  [FAIL] {msg}")
    print(f"  Fix: re-measure, then update the EGRESS-LEDGER-BINDING block in "
          f"{INVENTORY}. Changing the binding is asserting that the prose above "
          f"it was reviewed against the new destination.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
