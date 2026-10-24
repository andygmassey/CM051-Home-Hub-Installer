"""Compile every tracked .py file with the interpreter running this script.

The shipped interpreter is python 3.11 (the DMG bundles 3.11.x). Syntax that
needs 3.12 (PEP 701 nested same-quote f-strings, `type` statements, PEP 695
generics) is a SyntaxError there and kills the whole module at import.
compile() is used rather than py_compile so nothing is written to disk.

Usage: python3.11 -I tests/py311_compile_all.py [--self-test]
Exit 0 only when the interpreter is 3.11 and every file compiled.
"""
import subprocess
import sys

if sys.version_info[:2] != (3, 11):
    print("CANNOT-RUN: need python 3.11, running %s" % sys.version.split()[0], file=sys.stderr)
    sys.exit(2)

if "--self-test" in sys.argv:
    # Control: a PEP 701 construct MUST be rejected by this interpreter.
    try:
        compile("x = 1\nprint(f\"{x + len(f\"{x}\")}\")\n", "ctl", "exec")
    except SyntaxError:
        print("control ok: PEP 701 f-string rejected under 3.11")
        sys.exit(0)
    print("FAIL: control was accepted; this gate cannot see 3.12-only syntax", file=sys.stderr)
    sys.exit(1)

files = subprocess.check_output(["git", "ls-files", "*.py"], text=True).split("\n")
files = [f for f in files if f]
bad = 0
for f in files:
    try:
        with open(f, "rb") as fh:
            compile(fh.read(), f, "exec")
    except SyntaxError as e:
        bad += 1
        print("FAIL %s:%s %s" % (f, e.lineno, e.msg))
    except (OSError, ValueError) as e:
        bad += 1
        print("CANNOT-READ %s %s" % (f, e))
print("python %s: %d files, %d bad" % (sys.version.split()[0], len(files), bad))
sys.exit(1 if bad else 0)
