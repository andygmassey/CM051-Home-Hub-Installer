#!/usr/bin/env python3
"""Rewrite a requirements.txt so every line is an == pin (S4, v1.0.124).

Usage: pin_python_requirements.py <requirements.txt> <pip-freeze-of-a-venv-built-from-it>

Direct requirements keep their original range as a trailing comment; the rest
of the freeze (the transitive closure) is appended under a marker. Hashes are
the v1.0.125 step, deliberately not here.
Regeneration: build a clean venv with the bundled Python 3.11, `pip install -r`
the file, `pip freeze > fz.txt`, run this. Re-running on an already pinned file
is refused: edit the ranges back first, or edit the pins by hand.
"""
import re, sys

MARK = "# --- transitive closure (pip freeze), pinned ---"
norm = lambda n: re.sub(r"[-_.]+", "-", n).lower()

def main(req, fz):
    freeze = {}
    for ln in open(fz):
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        m = re.fullmatch(r"([A-Za-z0-9_.\-]+)==([^\s;]+)", ln)
        if not m:
            sys.exit("freeze line is not name==ver: %r" % ln)
        freeze[norm(m.group(1))] = (m.group(1), m.group(2))
    src = open(req).read()
    if MARK in src:
        sys.exit("already pinned: " + req)
    out, direct = [], set()
    for ln in src.splitlines():
        s = ln.strip()
        if not s or s.startswith("#"):
            out.append(ln); continue
        m = re.match(r"([A-Za-z0-9_.\-]+)(\[[^\]]*\])?\s*([^#]*?)\s*(#.*)?$", s)
        if not m:
            sys.exit("unparsed requirement line: %r" % ln)
        key = norm(m.group(1))
        if key not in freeze:
            sys.exit("not in freeze: " + m.group(1))
        name, ver = freeze[key]
        direct.add(key)
        extra = m.group(2) or ""
        out.append("%s%s==%s  # was: %s" % (name, extra, ver, m.group(3) or "(any)"))
    out += ["", MARK]
    for key in sorted(freeze):
        if key in direct or key in ("pip", "setuptools", "wheel"):
            continue
        out.append("%s==%s" % freeze[key])
    open(req, "w").write("\n".join(out) + "\n")
    print("%s: %d direct, %d total pinned" % (req, len(direct), len([l for l in out if "==" in l and not l.startswith("#")])))

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(*sys.argv[1:])
