#!/usr/bin/env python3
"""A needle found ANYWHERE in gui/project.yml does not bind a package to a source.

THE INCIDENT THIS IS ABOUT, from the cut BOM:

    CONTACTS AND PLACES HAVE NEVER IMPORTED SINCE v1.0.60. install.sh copies the
    ROOT contact_syncer into ~/.ostler/import-pipeline; that copy had 19 modules
    against the vendored copy's 24, and the two it lacked are two the installer
    RUNS. ... the install then reports DONE status=ok, which is why it survived
    six cuts.

`scripts/check_install_sh_script_dir_coverage.py` is the gate that maps each
`${SCRIPT_DIR}/<leaf>` probe in install.sh to the postBuildScript that bundles
it. Its predicate is:

    if needle in project_yml_body

a plain substring search over the WHOLE file. The needle for `contact_syncer` is
`vendor/cm041`, and that string also appears on the shared assignment

    VENDOR_ROOT="${SRCROOT}/../vendor/cm041"

which feeds four packages. So the needle keeps matching even if the cp line for
one of them is repointed somewhere else entirely.

MEASURED BY EXECUTION, 2026-09-05, before this file existed. Repointing
contact_syncer's bundling line from `${VENDOR_ROOT}/contact_syncer` to
`${SRCROOT}/../contact_syncer` -- the exact shape of the incident above -- left
every gate green:

    check_install_sh_script_dir_coverage.py     rc=0   "41 probes all covered"
    test_artefact_walk_stages_the_dmg_payload   rc=0
    test_bundle_phase_declares_every_copy       rc=0

WHAT THIS FILE ASSERTS INSTEAD. For every `cp ... "${DEST}/<leaf>"` in
gui/project.yml, resolve the SOURCE by substituting the variables assigned in the
SAME script block, and require the declared needle for that leaf to match THAT
RESOLVED SOURCE -- not the file at large.

THREE STATES. 0 pass, 1 a package bundled from an undeclared source, 2 the
parser resolved too little to have measured anything.

British English throughout.
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PROJECT_YML = os.path.join(REPO, "gui", "project.yml")
COVERAGE_GATE = os.path.join(REPO, "scripts", "check_install_sh_script_dir_coverage.py")

# The parser must resolve at least this many (leaf -> source) bindings. A parser
# that silently stops matching would otherwise report "no mismatches" over an
# empty set, which is the same shape as the defect it is here to catch.
RESOLVED_FLOOR = 10

PASS = 0
FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print("  [PASS] %s" % m)


def bad(m):
    global FAIL
    FAIL += 1
    print("  [FAIL] %s" % m)


def cannot(m):
    print("CANNOT-RUN: %s" % m, file=sys.stderr)
    raise SystemExit(2)


if not os.path.isfile(PROJECT_YML):
    cannot("no gui/project.yml at %s" % PROJECT_YML)
if not os.path.isfile(COVERAGE_GATE):
    cannot("no coverage gate at %s -- this file reads its map" % COVERAGE_GATE)

# ONE MAP, NOT TWO. The needle table lives in the coverage gate; importing it
# means a package added there is covered here on the same commit, and a
# divergent second copy cannot drift into disagreeing with the first.
sys.path.insert(0, os.path.dirname(COVERAGE_GATE))
try:
    from check_install_sh_script_dir_coverage import COVERAGE_NEEDLES
except Exception as exc:  # noqa: BLE001
    cannot("could not import COVERAGE_NEEDLES from the coverage gate: %s: %s"
           % (type(exc).__name__, exc))

if not COVERAGE_NEEDLES:
    cannot("COVERAGE_NEEDLES imported empty; every assertion below would be vacuous")

body = io.open(PROJECT_YML, encoding="utf-8").read()

# Split into postBuildScript blocks. Variables are assigned per block, so a
# resolution that reached across blocks would bind a leaf to another step's
# source -- which is the very confusion this file exists to stop.
BLOCK_RE = re.compile(r"^\s*-\s+name:\s*(.+)$", re.M)
starts = [(m.start(), m.group(1).strip()) for m in BLOCK_RE.finditer(body)]
if not starts:
    cannot("found no '- name:' blocks in gui/project.yml; the parser is not "
           "reading the file it thinks it is")
blocks = []
for i, (pos, name) in enumerate(starts):
    end = starts[i + 1][0] if i + 1 < len(starts) else len(body)
    blocks.append((name, body[pos:end]))

ASSIGN_RE = re.compile(r'^\s*(?:local\s+)?([A-Z_][A-Z0-9_]*)="([^"]*)"', re.M)
CP_RE = re.compile(r'cp\s+(?:-R\s+)?"([^"]+)"\s+"\$\{DEST\}/([^"]*)"')


def resolve(value, env):
    """Substitute ${VAR} / $VAR from the block's own assignments, twice.

    Twice because VENDOR_ROOT="${SRCROOT}/../vendor/cm041" is itself written in
    terms of another variable. Anything still unresolved is left as written and
    reported, never guessed at.
    """
    for _ in range(2):
        for k, v in env.items():
            value = value.replace("${%s}" % k, v).replace("$%s" % k, v)
    return value


bindings = []      # (leaf, resolved_source, block_name)
unresolved = []    # (leaf, raw_source, block_name)

for name, block in blocks:
    env = dict(ASSIGN_RE.findall(block))
    for raw_src, raw_leaf in CP_RE.findall(block):
        leaf = raw_leaf.rstrip("/").strip()
        if not leaf:
            continue
        src = resolve(raw_src, env).rstrip("/")
        if src.endswith("/."):
            src = src[:-2]
        # ${SRCROOT} IS gui/, SO ${SRCROOT}/../X IS REPO-RELATIVE X. It is an
        # Xcode build variable, never assigned in the script block, so without
        # this every source stays "unresolved" and the floor below refuses the
        # whole run -- which it did, correctly, on the first draft of this file.
        src = src.replace("${SRCROOT}/../", "").replace("$SRCROOT/../", "")
        src = src.replace("${SRCROOT}/..", "").replace("${SRCROOT}", "")
        src = src.lstrip("/")
        if "$" in src:
            unresolved.append((leaf, raw_src, name))
        else:
            bindings.append((leaf, src, name))

print("  parsed %d block(s); %d resolved binding(s), %d unresolved"
      % (len(blocks), len(bindings), len(unresolved)))

if len(bindings) < RESOLVED_FLOOR:
    cannot("resolved only %d (leaf -> source) binding(s), floor is %d. The "
           "parser is not reading enough of gui/project.yml for a clean result "
           "below to mean anything." % (len(bindings), RESOLVED_FLOOR))

# THE NEEDLE TABLE IS NOT HOMOGENEOUS, AND ASSUMING IT WAS COST ME THREE FALSE
# FAILURES ON THE FIRST RUN. Measured: 31 needles name a SOURCE path, 3 name the
# cp TARGET (`${DEST}/...`, added so "a project.yml regression un-covers them"),
# and 1 is a bare variable NAME. Only the source-shaped ones can be compared
# against a resolved source; the rest are named below rather than skipped
# quietly, because a gate that silently drops what it cannot judge reports a
# coverage it does not have.
def _source_shaped(n):
    return not n.startswith("${DEST}") and "/" in n and not n.startswith("$")


out_of_scope = []
checked = 0
for leaf, src, block_name in bindings:
    needles = COVERAGE_NEEDLES.get(leaf)
    if not needles:
        continue
    src_needles = [n for n in needles if _source_shaped(n)]
    if not src_needles:
        out_of_scope.append((leaf, needles))
        continue
    needles = src_needles
    checked += 1
    if any(n in src for n in needles):
        continue
    bad("%s is bundled from '%s' in block '%s', which matches none of its "
        "declared source(s) %s. The coverage gate cannot see this: its needle "
        "is searched against the WHOLE file, and '%s' still appears elsewhere "
        "in gui/project.yml."
        % (leaf, src, block_name, needles, needles[0]))

if checked == 0:
    cannot("resolved %d binding(s) but none of them names a package in "
           "COVERAGE_NEEDLES, so nothing was compared against a declared source"
           % len(bindings))

if FAIL == 0:
    ok("all %d bundled package(s) with a declared source come from it" % checked)

# CONTROL. The needles are only meaningful if at least one of them is a vendor
# path -- a table of needles that all matched anything would make the check
# above unfailable.
vendor_needles = sum(1 for v in COVERAGE_NEEDLES.values()
                     for n in v if n.startswith("vendor/"))
if vendor_needles == 0:
    cannot("no needle in COVERAGE_NEEDLES names a vendor/ path, so the "
           "comparison above could not have failed for the reason this file exists")
ok("CONTROL: %d needle(s) name a vendor/ path, so a repointed bundling line "
   "has something to disagree with" % vendor_needles)

if out_of_scope:
    print("  OUT OF SCOPE for this gate (needle names a cp target or a bare "
          "variable, not a source path):")
    for leaf, needles in out_of_scope:
        print("    %-40s %s" % (leaf, needles))

if unresolved:
    print("  NOT VERIFIED (source still holds an unresolved variable):")
    for leaf, raw, block_name in unresolved:
        print("    %-40s from '%s' in '%s'" % (leaf, raw, block_name[:40]))
    print("  These are reported, not passed. A cp whose source this parser "
          "cannot resolve is a package this gate does not cover.")

print("\n== %d pass / %d fail / %d checked against a declared source =="
      % (PASS, FAIL, checked))
sys.exit(1 if FAIL else 0)
