#!/usr/bin/env python3
"""limactl's install-phase egress is attributed, and the ledger can attribute it.

docs/EGRESS_INVENTORY.md carried "limactl's destinations change between
samples" as an unattributed item. Cause, from code: lima's user-v2 network runs
inside a limactl process, so limactl owns the sockets of the VM's containers.
Those containers pull ghcr.io images and, when the customer agreed, the
wiki-compiler looks up en.wikipedia.org, overpass-api.de, musicbrainz.org and
nominatim.openstreetmap.org. Two of those names were not in the ledger, so the
name-join could never match them, whatever their rotating addresses were.

Four arms:
  1. every registry host in an install.sh compose `image:` line is declared
  2. the VM-carried names (Wikipedia, Overpass, release-assets) are declared
  3. the doc no longer lists limactl as unattributed, and names the carrier
  4. the install does not start a VM that fetches more than the doc says
     (no --kubernetes, no containerd runtime), so the "NOT fetched" claim holds

Run with no arguments to gate the real tree, --self-test to prove it can fail.
Exit 0 pass, 1 fail, 2 CANNOT-RUN (a missing input is never a pass).
"""
import pathlib
import re
import shutil
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[1]
LEDGER = pathlib.Path("scripts/box_walk_probes/egress_hosts.tsv")
DOC = pathlib.Path("docs/EGRESS_INVENTORY.md")
INSTALL = pathlib.Path("install.sh")

VM_CARRIED = ("en.wikipedia.org", "overpass-api.de", "musicbrainz.org",
              "nominatim.openstreetmap.org", "release-assets.githubusercontent.com")
IMAGE_RE = re.compile(r"^\s*image:\s*([A-Za-z0-9.-]+)/", re.M)
COLIMA_START_RE = re.compile(r"colima start\b[^\n]*")


class CannotRun(Exception):
    pass


def read(root, rel):
    p = root / rel
    if not p.is_file():
        raise CannotRun(f"{rel} is absent")
    return p.read_text(encoding="utf-8")


def declared(root):
    hosts = set()
    for line in read(root, LEDGER).splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            hosts.add(line.split("\t", 1)[0].strip())
    if not hosts:
        raise CannotRun("the ledger parsed to zero rows")
    return hosts


def check(root):
    """Returns a list of failure strings (empty is a pass)."""
    out = []
    hosts = declared(root)
    install = read(root, INSTALL)
    regs = set(IMAGE_RE.findall(install))
    # Control: the predicate must find the registry we know is there.
    if "ghcr.io" not in regs:
        raise CannotRun("image-registry predicate found no ghcr.io: broken predicate")
    for r in sorted(regs - hosts):
        out.append(f"compose image registry {r} is not declared in the ledger")
    for h in VM_CARRIED:
        if h not in hosts:
            out.append(f"VM-carried host {h} is not declared in the ledger")
    doc = read(root, DOC)
    if "Still unattributed" in doc and "limactl" in doc.split("Still unattributed", 1)[1][:400]:
        out.append("the inventory still lists limactl as unattributed")
    if "usernet" not in doc:
        out.append("the inventory does not name limactl's usernet as the carrier")
    starts = COLIMA_START_RE.findall(install)
    if not starts:
        raise CannotRun("no `colima start` found in install.sh")
    for s in starts:
        if re.search(r"--kubernetes|--runtime[ =]containerd", s):
            out.append(f"colima start enables more fetches than the doc states: {s.strip()}")
    return out


def self_test():
    """Each mutant must go red; the clean copy must be green."""
    bad = 0
    with tempfile.TemporaryDirectory() as d:
        base = pathlib.Path(d)
        for rel in (LEDGER, DOC, INSTALL):
            (base / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPO / rel, base / rel)
        if check(base):
            print("  [FAIL] self-test: clean copy is not green")
            bad += 1
        muts = [
            ("drop en.wikipedia.org row", LEDGER,
             lambda t: "\n".join(l for l in t.split("\n") if not l.startswith("en.wikipedia.org\t"))),
            ("drop ghcr.io row", LEDGER,
             lambda t: "\n".join(l for l in t.split("\n") if not l.startswith("ghcr.io\t"))),
            ("reinstate the open item", DOC,
             lambda t: t + "\n### Still unattributed\n\n1. `limactl` again\n"),
            ("doc loses the carrier", DOC, lambda t: t.replace("usernet", "")),
            ("colima gains --kubernetes", INSTALL,
             lambda t: t.replace("colima start --cpu 2", "colima start --kubernetes --cpu 2", 1)),
        ]
        for name, rel, fn in muts:
            p = base / rel
            orig = p.read_text(encoding="utf-8")
            p.write_text(fn(orig), encoding="utf-8")
            try:
                if not check(base):
                    print(f"  [FAIL] self-test: mutant '{name}' stayed green")
                    bad += 1
                else:
                    print(f"  [PASS] self-test: mutant '{name}' goes red")
            finally:
                p.write_text(orig, encoding="utf-8")
    return bad


def main(argv):
    print("== limactl egress is attributed ==")
    root = REPO
    for a in argv:
        if a.startswith("--root="):
            root = pathlib.Path(a.split("=", 1)[1])
    try:
        if "--self-test" in argv:
            return 1 if self_test() else 0
        fails = check(root)
    except CannotRun as e:
        print(f"  [CANNOT-RUN] {e}")
        return 2
    print(f"  [{'FAIL' if fails else 'PASS'}] ledger, doc and install agree on what the VM carries")
    for f in fails:
        print(f"         {f}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
