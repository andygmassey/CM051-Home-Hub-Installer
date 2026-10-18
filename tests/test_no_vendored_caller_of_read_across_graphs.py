#!/usr/bin/env python3
"""No vendored file outside compartment.py may CALL or IMPORT read_across_graphs.

WHY. The v1.0.107 re-pin of vendor/cm041/identity_resolver (CM051 #2594) brought
upstream CM041 #175's ``read_across_graphs`` into the vendored compartment.py,
beside the vendor's own ``graph_scoped_select``. ``read_across_graphs`` spans
every named graph EXCEPT a deny-list of other users' compartments: a deny-list
FAILS OPEN, because a graph nobody listed is read. That is why #175 was HELD on
2026-09-19 (VENDOR_MANIFEST.toml hold_ack_reason, board row 2213), and why
vendor/cm041/assistant_api inlines the allow-list scope instead of importing it.

Re-pinning made the function PRESENT in the shipped tree. This gate keeps it
UNCALLED: the definition may ship, no vendored reader may use it. Removing this
gate, or adding a caller, needs the deny-list question answered first.

HOW. Python AST, not grep: the identifier appears in many COMMENTS that say
"not imported", and a text match cannot tell a comment from a call. Every
vendored *.py is parsed; a file that cannot be parsed is CANNOT-RUN (exit 2),
never a pass. A Call whose callee is named read_across_graphs (bare or as an
attribute) or an import of it, in any file other than compartment.py, is RED.

CONTROLS, every run:
  * compartment.py must DEFINE read_across_graphs, else the scan is looking at
    the wrong tree (CANNOT-RUN).
  * --self-test plants a call in a scratch copy (must go RED), and the same
    text as a comment (must stay GREEN).

EXIT: 0 clean, 1 a caller found, 2 could not look.
"""
import ast
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
NAME = "read_across_graphs"
HOME_REL = os.path.join("vendor", "cm041", "identity_resolver", "compartment.py")


def offenders(root):
    """-> (examined, offenders[list of 'path:line kind'], unreadable[list], defined)"""
    examined, found, bad, defined = 0, [], [], False
    vroot = os.path.join(root, "vendor")
    for dp, dn, fn in os.walk(vroot):
        dn[:] = [d for d in dn if d not in ("__pycache__", "node_modules", ".git")]
        for f in fn:
            if not f.endswith(".py"):
                continue
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, root)
            try:
                with open(p, encoding="utf-8") as fh:
                    tree = ast.parse(fh.read(), filename=rel)
            except (SyntaxError, UnicodeDecodeError, OSError) as e:
                bad.append("%s (%s)" % (rel, type(e).__name__))
                continue
            examined += 1
            home = rel == HOME_REL
            for node in ast.walk(tree):
                if home and isinstance(node, ast.FunctionDef) and node.name == NAME:
                    defined = True
                if home:
                    continue
                if isinstance(node, ast.Call):
                    fnode = node.func
                    nm = getattr(fnode, "id", None) or getattr(fnode, "attr", None)
                    if nm == NAME:
                        found.append("%s:%d call" % (rel, node.lineno))
                elif isinstance(node, ast.ImportFrom):
                    if any(a.name == NAME for a in node.names):
                        found.append("%s:%d import" % (rel, node.lineno))
                elif isinstance(node, ast.Attribute) and node.attr == NAME:
                    found.append("%s:%d reference" % (rel, node.lineno))
    return examined, sorted(set(found)), bad, defined


def verdict(root, quiet=False):
    examined, found, bad, defined = offenders(root)
    say = (lambda *a: None) if quiet else print
    say("examined %d vendored .py file(s); %d unparseable" % (examined, len(bad)))
    if bad:
        for b in bad:
            say("  CANNOT-RUN  %s" % b)
        return 2
    if not defined:
        say("CANNOT-RUN: %s does not define %s -- wrong tree, nothing proven" % (HOME_REL, NAME))
        return 2
    if found:
        for f in found:
            say("  RED  %s" % f)
        say("RED: %d use(s) of %s outside compartment.py (a deny-list scope; fails open)" % (len(found), NAME))
        return 1
    say("OK: %s is defined in compartment.py and used by no other vendored file" % NAME)
    return 0


def self_test():
    tmp = tempfile.mkdtemp()
    try:
        shutil.copytree(os.path.join(ROOT, "vendor"), os.path.join(tmp, "vendor"),
                        ignore=shutil.ignore_patterns("__pycache__", "node_modules"))
        target = os.path.join(tmp, "vendor", "cm041", "identity_resolver", "resolver.py")
        orig = open(target, encoding="utf-8").read()
        results = []
        open(target, "w", encoding="utf-8").write(
            orig + "\n# read_across_graphs(body) in a comment is not a call\n")
        results.append(("comment only", verdict(tmp, quiet=True), 0))
        open(target, "w", encoding="utf-8").write(
            orig + "\n\ndef _planted(body):\n    return read_across_graphs(body)\n")
        results.append(("planted bare call", verdict(tmp, quiet=True), 1))
        open(target, "w", encoding="utf-8").write(
            orig + "\nfrom identity_resolver.compartment import read_across_graphs as _r\n")
        results.append(("planted import", verdict(tmp, quiet=True), 1))
        ok = True
        for label, got, want in results:
            mark = "PASS" if got == want else "FAIL"
            ok &= got == want
            print("  self-test %s: %s -> exit %d (want %d)" % (mark, label, got, want))
        return 0 if ok else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    sys.exit(verdict(ROOT))
