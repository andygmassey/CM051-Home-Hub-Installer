#!/usr/bin/env python3
"""Which ostler_fda modules can a customer install ever reach?

WHY (v1018-D658/D659 fallout, 2026-08-15)
=========================================
``vendor/ostler_fda/repair_placeholder_names.py`` is 378 lines, merged, tested
by ``tests/test_name_repair.sh``, gated by ``.github/workflows/name-repair.yml``,
registered in ``vendor/VENDOR_ONLY.tsv``, and PRESENT in the shipped DMG --
verified byte-identical to main inside
``OstlerInstaller.app/Contents/Resources/ostler_fda/`` on v1.0.26.

Nothing calls it. Not install.sh, not a LaunchAgent, not a tick script, not the
doctor. It ships and cannot run, and every signal above reads as a shipped fix.

MERGED is not DELIVERED is not INVOKED. This repo already has a reader for the
third gate on ONE surface -- ``scripts/verify_test_wiring.sh``, which asks what
starts a test. That gate is structurally blind here: its surface is
``tests/*.sh`` and this defect lives in ``vendor/ostler_fda/*.py``. A gate and
the defect it is meant to catch must share a surface or the gate is green
forever. This is the same reader pointed at the shipping Python.

HOW IT COMPUTES REACHABILITY
============================
Two steps, because either alone lies.

1. ENTRY POINTS -- modules the SHIPPING surface names directly: install.sh, the
   tick scripts, the launchd plists, the doctor, contact_syncer, the GUI build.
   Found by pattern, because that is exactly how the runtime resolves them:
   there is no registry to consult.

2. TRANSITIVE CLOSURE over the package's own import graph, walked with ``ast``
   so that FUNCTION-LOCAL imports count. That is not a detail. ``extract_all``
   imports ``apple_music`` inside a function body, and a top-level-only walk
   would report a module that demonstrably runs on every install as an orphan.
   The census carries that case as a named positive control below and REFUSES
   to report (exit 2) if the control fails, because a confident absence from a
   broken predicate is the exact failure this file exists to stop.

Anything outside the closure ships and cannot run.

DORMANT IS A THIRD COUNT, NOT A WARN BUCKET
===========================================
Same shape as ``verify_test_wiring.sh``, and for the same reason: a gate that
is red the day it lands is a gate people route around. But a bucket that
absorbs failures into a pass is how this codebase keeps getting hurt, so the
summary reports THREE separate numbers -- REACHABLE, DORMANT, UNREGISTERED --
and DORMANT is never folded into REACHABLE. Two dark modules show up as two,
the pass line states the dormant count out loud rather than saying "clean",
and the register prints in full on every run.

Acknowledgement is PER-MODULE and needs a REASON. There is deliberately no
blanket "ignore unreachable" switch, no status other than ``DORMANT``, and no
wildcards: one such line would silently absorb every future orphan. A row whose
``blocked_by`` is empty, ``-``, ``TBD`` or ``n/a`` is refused outright, because
a row without a reason is a suppression wearing a reason's clothes. Every one
of those rules fails CLOSED at exit 2.

EXIT CODES
  0  every module is reachable, or is named in the register
  1  a module ships and can never run, and is not in the register
  2  could not run -- no package dir, no modules, no shipping surface, an
     unreadable register, or the positive control failed

Exit 2 is load-bearing. "Nothing is orphaned" and "I could not enumerate
anything" print identically otherwise, and a zero denominator reads as success.

British English throughout; " -- " not em-dashes.
"""
from __future__ import annotations

import ast
import os
import re
import sys

# The package under census. Kept as one constant so a rename is one edit.
PKG_REL = os.path.join("vendor", "ostler_fda")
REGISTER_REL = os.path.join("scripts", "fda_unwired_modules.tsv")

# Everything that can START a Python module on a customer's Mac. install.sh is
# the big one; the rest are the tick scripts, plists and services that run after
# the install finishes. Directories are walked; missing entries are skipped
# rather than fatal, because the vendor tree changes shape between cuts.
SHIPPING_SURFACE = [
    "install.sh",
    "lib",
    "scripts",
    "assistant-agent",
    "contact_syncer",
    "wiki-recompile",
    "context-refresh",
    "gui",
    "vendor/doctor",
    "vendor/email_source",
    "vendor/email_ingest",
    "vendor/whatsapp_source",
    "vendor/imessage_source",
    "vendor/imessage_bridge",
    "vendor/spoken_source",
    "vendor/hub_power",
    "vendor/cm041",
    "vendor/cm048_pipeline",
    "vendor/cm052_ai_conversations",
    "vendor/cm059_editor",
]

# Files worth reading on that surface. A plist and a .yml start processes just
# as surely as a .sh does. Prose formats are NOT here: a .md or a .json of UI
# copy can NAME a module and can never start one, and a mention is not an
# invocation.
SURFACE_SUFFIXES = (
    ".sh", ".py", ".plist", ".yml", ".yaml", ".swift", ".toml", "Makefile",
)

# The gate's own artefacts are excluded from the surface it searches. The
# register exists to NAME orphans, so leaving it in would make every recorded
# module score reachable by being recorded -- the instrument reporting itself.
# Found the only way this is ever found: the first run of this file marked
# repair_placeholder_names REACHABLE off its own register row.
SELF_EXCLUDE = {
    os.path.join("scripts", "verify_fda_modules_reachable.py"),
    REGISTER_REL,
}

# ``python -m ostler_fda`` is a supported affordance of the package itself
# (__main__.py exists precisely to provide it), so __main__ is an entry point
# by construction rather than an orphan. Named here rather than special-cased
# silently further down.
IMPLICIT_ENTRY_POINTS = {"__main__"}

# THE POSITIVE CONTROL. apple_music is imported ONLY from inside a function body
# in extract_all.py, and extract_all is invoked by install.sh. A naive
# top-level-import walk calls it an orphan. If this module does not come out
# REACHABLE, the predicate is broken and every "orphan" it reports is a false
# accusation, so the census refuses to answer at all.
CONTROL_MODULE = "apple_music"
CONTROL_VIA = "extract_all"


def die_cannot_run(msg: str) -> None:
    print(f"verify_fda_modules_reachable: CANNOT RUN -- {msg}", file=sys.stderr)
    print("                              Nothing was enumerated. This is not a pass.",
          file=sys.stderr)
    sys.exit(2)


def read(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def module_names(pkg_dir: str) -> list:
    return sorted(
        f[:-3] for f in os.listdir(pkg_dir)
        if f.endswith(".py") and f != "__init__.py"
    )


def strip_comment_lines(text: str) -> str:
    """Drop whole-line comments. A MENTION IS NOT AN INVOCATION.

    Straight from ``verify_test_wiring.sh``, which learned this the hard way on
    2026-08-15 (#687): a workflow comment listing tests that do NOT run scored
    them WIRED. The identical trap is here, because the fix for THIS backlog is
    writing comments that name the orphaned modules being triaged.

    FULL-LINE COMMENTS ONLY, deliberately. Cutting everything after any '#'
    would truncate a real invocation whose arguments contain one -- a grep
    pattern, a URL fragment, a colour code.
    """
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def surface_text(repo: str) -> str:
    """Every byte of the shipping surface, comments stripped, concatenated.

    Read as ONE blob deliberately: the question is only "is this module named
    anywhere something can start it", and per-file attribution would invite the
    caller to trust a filename that a later refactor moves.
    """
    chunks = []
    for rel in SHIPPING_SURFACE:
        path = os.path.join(repo, rel)
        if rel in SELF_EXCLUDE:
            continue
        if os.path.isfile(path):
            chunks.append(strip_comment_lines(read(path)))
            continue
        if not os.path.isdir(path):
            continue
        for root, dirs, files in os.walk(path):
            dirs[:] = [d for d in dirs
                       if d not in (".git", "__pycache__", "node_modules", ".venv")]
            for f in files:
                full = os.path.join(root, f)
                if os.path.relpath(full, repo) in SELF_EXCLUDE:
                    continue
                if f.endswith(SURFACE_SUFFIXES) or f == "Makefile":
                    chunks.append(strip_comment_lines(read(full)))
    return "\n".join(chunks)


def entry_points(repo: str, mods: list) -> set:
    """Modules the shipping surface names by hand.

    Matches ``ostler_fda.<mod>`` and ``ostler_fda/<mod>`` -- the import form and
    the path form. Both appear in install.sh today.
    """
    text = surface_text(repo)
    if not text.strip():
        die_cannot_run(
            "the shipping surface read as empty. Every module would score "
            "UNREACHABLE for want of looking, which is a false accusation."
        )
    found = {m.group(1) for m in re.finditer(r"ostler_fda[./]([A-Za-z_][A-Za-z0-9_]*)", text)}
    return (found & set(mods)) | (IMPLICIT_ENTRY_POINTS & set(mods))


def import_graph(pkg_dir: str, mods: list) -> dict:
    """module -> the sibling modules it imports, function-local imports included."""
    known = set(mods)
    graph: dict = {}
    for m in mods:
        edges: set = set()
        try:
            tree = ast.parse(read(os.path.join(pkg_dir, m + ".py")))
        except (SyntaxError, ValueError):
            # A module that will not parse cannot be walked. Record no edges
            # and let the caller decide; it is still counted in the denominator.
            graph[m] = edges
            continue
        for node in ast.walk(tree):          # ast.walk sees function-local imports
            if isinstance(node, ast.ImportFrom) and node.module:
                head = node.module.split(".")
                if head[0] == "ostler_fda" and len(head) > 1:
                    edges.add(head[1])
                elif node.module in known:   # `from .apple_music import x`
                    edges.add(node.module)
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    head = alias.name.split(".")
                    if head[0] == "ostler_fda" and len(head) > 1:
                        edges.add(head[1])
                    elif alias.name in known:
                        edges.add(alias.name)
        graph[m] = edges & known
    return graph


def closure(entry: set, graph: dict) -> set:
    reached, stack = set(entry), list(entry)
    while stack:
        for nxt in graph.get(stack.pop(), ()):
            if nxt not in reached:
                reached.add(nxt)
                stack.append(nxt)
    return reached


# The ONLY accepted status. There is deliberately no "IGNORE", no "SKIP" and no
# blanket switch: an acknowledgement is per-module with a reason, or it is not an
# acknowledgement. A one-line "ignore all unreachable" would silently absorb
# every future orphan, which is the failure this file exists to prevent.
ACCEPTED_STATUS = "DORMANT"

# Strings that look like a reason and are not one. A row whose blocked_by is any
# of these is a suppression wearing a reason's clothes.
NON_REASONS = {"", "-", "--", "?", "tbd", "todo", "n/a", "na", "none", "unknown"}

# A wildcard would acknowledge modules nobody has looked at.
GLOB_CHARS = set("*?[]")


def read_register(path: str) -> dict:
    """module -> (status, blocked_by, note). Absent or malformed is exit 2.

    Every rule below fails CLOSED. A register that cannot be trusted must stop
    the gate, never wave it through: "no unregistered orphans" and "I could not
    read the register" have to print differently.
    """
    if not os.path.exists(path):
        die_cannot_run(
            f"the register is missing at {path}. Without it every recorded "
            "module reads as a new orphan, or -- worse -- a future edit could "
            "delete it and the gate would score the deletion as clean."
        )
    rows = {}
    for line in read(path).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = [p.strip() for p in line.split("\t")]
        if len(parts) < 4:
            die_cannot_run(
                "malformed register row -- want 4 tab-separated columns "
                f"(module, status, blocked_by, note): {line[:120]!r}"
            )
        module, status, blocked_by, note = parts[0], parts[1], parts[2], "\t".join(parts[3:])
        if set(module) & GLOB_CHARS:
            die_cannot_run(
                f"register row {module!r} looks like a glob. Acknowledgement is "
                "PER-MODULE by literal name; a wildcard would silently absorb "
                "every future orphan."
            )
        if status != ACCEPTED_STATUS:
            die_cannot_run(
                f"register row {module!r} has status {status!r}. The only "
                f"accepted status is {ACCEPTED_STATUS}. There is no blanket "
                "ignore switch by design."
            )
        if blocked_by.strip().lower() in NON_REASONS:
            die_cannot_run(
                f"register row {module!r} has no real reason in blocked_by "
                f"({blocked_by!r}). Name the concrete thing that blocks wiring "
                "it, or wire it."
            )
        rows[module] = (status, blocked_by, note)
    return rows


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    repo = argv[0] if argv else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    pkg_dir = os.path.join(repo, PKG_REL)
    register_path = os.path.join(repo, REGISTER_REL)

    if not os.path.isdir(pkg_dir):
        die_cannot_run(f"not a directory: {pkg_dir}")
    mods = module_names(pkg_dir)
    if not mods:
        die_cannot_run(
            f"found NO .py modules under {pkg_dir}. An empty scan is not a "
            "clean reachability report."
        )

    register = read_register(register_path)
    entry = entry_points(repo, mods)
    graph = import_graph(pkg_dir, mods)
    reached = closure(entry, graph)

    # The predicate has to prove itself before it is allowed to accuse anything.
    if CONTROL_MODULE in mods and CONTROL_VIA in mods and CONTROL_MODULE not in reached:
        die_cannot_run(
            f"positive control FAILED: {CONTROL_MODULE} is imported from inside "
            f"a function in {CONTROL_VIA}.py, which install.sh runs, so it must "
            "score REACHABLE. It did not, so this walk cannot see function-local "
            "imports and every orphan it names would be a false accusation."
        )

    orphans = sorted(set(mods) - reached)
    dormant = [m for m in orphans if m in register]
    unregistered = [m for m in orphans if m not in register]

    # The counts are reported as THREE separate numbers on purpose. Folding
    # dormant into reachable would let two dark modules read as a clean tree,
    # and a dormant bucket that reads as a pass is precisely how a warn bucket
    # collapses into green. Two dormant modules must be visible as two.
    print(f"modules in {PKG_REL}      {len(mods)}")
    print(f"named by the shipping surface     {len(entry)}")
    print(f"REACHABLE                         {len(reached)}")
    print(f"DORMANT (acknowledged, unwired)   {len(dormant)}"
          + (f"   {sorted(dormant)}" if dormant else ""))
    print(f"UNREGISTERED ORPHANS              {len(unregistered)}"
          + ("   <- fails this gate" if unregistered else ""))
    if CONTROL_MODULE in mods:
        print(f"positive control                  {CONTROL_MODULE} REACHABLE "
              f"via a function-local import in {CONTROL_VIA}")
    print("")
    print(f"DORMANT MODULES ({len(register)} registered), from {REGISTER_REL}.")
    print("Printed in full every run so they cannot become wallpaper. These SHIP")
    print("and nothing calls them:")
    if not register:
        print("    (none)")
    for mod in sorted(register):
        status, blocked_by, note = register[mod]
        print(f"    {mod}  [{status}]")
        print(f"        BLOCKED BY: {blocked_by}")
        print(f"        {note}")
    print("")

    stale = sorted(m for m in register if m not in orphans)
    if stale:
        # Not a failure. A module that got wired is good news; the row is now a
        # lie and should go, and saying so is how the register stays true.
        print("register rows that are no longer orphans -- delete these rows:")
        for m in stale:
            print(f"    {m}")
        print("")

    if unregistered:
        print("FAIL -- these ship and can never run, and are not acknowledged:")
        for m in unregistered:
            print(f"    {PKG_REL}/{m}.py")
        print("")
        print("Either give it a caller, or add a DORMANT row to " + REGISTER_REL)
        print("naming the concrete thing that blocks wiring it. A module with no")
        print("caller reads as a shipped fix while doing nothing.")
        return 1

    # Deliberately NOT the word "clean". len(dormant) modules ship and cannot
    # run; that is acknowledged, not fine, and the summary says so in the same
    # breath as the pass.
    print(f"OK -- no UNREGISTERED orphans. {len(dormant)} module(s) ship DORMANT "
          "and are listed above.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
