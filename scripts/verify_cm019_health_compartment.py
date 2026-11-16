#!/usr/bin/env python3
"""Refuse a vendor/cm019 re-pin while upstream writes Apple Health as compartment 5.

WHY (Archie ruling, 133). The 133 outbound rule lets only L1, L2 and untagged
through; L0, L3 and unparseable are withheld. Upstream CM019
services/ingest/src/parsers/apple.py writes health records with
compartment_level=5, which that rule cannot place. The vendored copy carries a
CM051 divergence (health at 0), so today's shipped bytes are right. The danger
is a re-pin or a sync that brings the upstream 5 in. Until CM019 fixes it, that
must not happen.

WHAT IT MATCHES. The CODE CONSTRUCT, via ast: a call keyword
`compartment_level=<int literal 5>` inside a function that is a health path.
Comments and docstrings never count (a comment saying "compartment_level=5"
is not a write). "Health path" = the enclosing function's name, or an identifier
or string literal in its body (docstrings excluded), matches HEALTH_RE.
Negative control that is real in the code: _parse_icloud_notes also writes 5
(notes, not health) and is NOT refused; that is a different decision for a
different ruling.

MODES
  --scan-file F [--label L]        scan one file (the vendored apple.py)
  --rev REF --source-repo R        scan upstream apple.py at REF
  --manifest M [--base-ref REF]    gate mode, what verify_vendor_fresh.sh calls:
        1. ALWAYS scan the vendored apple.py (shipped bytes).
        2. If pinned_sha differs from the pin on BASE (a re-pin), scan upstream
           apple.py at the NEW pin. Cannot read it, or cannot tell whether the
           pin moved: CANNOT-RUN.

EXIT  0 clean   1 REFUSED (sites named file:line)   2 CANNOT-RUN (not a pass)
"""
import argparse
import ast
import os
import re
import subprocess
import sys

TREE = "cm019_preferences"
APPLE_REL = "services/ingest/src/parsers/apple.py"
HEALTH_RE = re.compile(
    r"health|workout|sleep|HK[A-Za-z]*(Identifier|Type)", re.IGNORECASE
)


class CannotRun(Exception):
    pass


def _fn_tokens(fn):
    """Names, attributes and string literals in fn's body, docstrings excluded."""
    toks = [fn.name]
    skip = set()
    for n in ast.walk(fn):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Module)):
            b = n.body
            if b and isinstance(b[0], ast.Expr) and isinstance(getattr(b[0], "value", None), ast.Constant):
                skip.add(id(b[0].value))
    for n in ast.walk(fn):
        if isinstance(n, ast.Name):
            toks.append(n.id)
        elif isinstance(n, ast.Attribute):
            toks.append(n.attr)
        elif isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in skip:
            toks.append(n.value)
    return toks


def find_sites(source, label):
    """Return [(line, func, health_bool)] for every compartment_level=5."""
    try:
        tree = ast.parse(source)
    except SyntaxError as e:
        raise CannotRun("%s does not parse (%s); a file the gate cannot read is not a pass" % (label, e))
    out = []

    def visit(node, fns):
        for c in ast.iter_child_nodes(node):
            nf = fns + [c] if isinstance(c, (ast.FunctionDef, ast.AsyncFunctionDef)) else fns
            if (isinstance(c, ast.keyword) and c.arg == "compartment_level"
                    and isinstance(c.value, ast.Constant) and c.value.value == 5
                    and not isinstance(c.value.value, bool)):
                health = any(HEALTH_RE.search(t) for f in fns for t in _fn_tokens(f))
                out.append((c.value.lineno, fns[-1].name if fns else "<module>", health))
            visit(c, nf)

    visit(tree, [])
    return out


def scan(source, label):
    """Return refusal lines for health sites; also returns total 5-sites examined."""
    sites = find_sites(source, label)
    refused = ["REFUSED: %s:%d compartment_level=5 in health path %s()" % (label, ln, fn)
               for ln, fn, h in sites if h]
    return refused, len(sites)


def git_show(repo, rev, path):
    r = subprocess.run(["git", "-C", repo, "show", "%s:%s" % (rev, path)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise CannotRun("cannot read %s at %s in %s: %s" % (path, rev, repo, r.stderr.strip()))
    return r.stdout


def manifest_field(text, tree, field):
    """Flat table-array reader, same shape the shell lib reads."""
    inblock = False
    named = False
    for line in text.splitlines():
        s = line.strip()
        if s == "[[tree]]":
            inblock = True
            named = False
            continue
        if not inblock:
            continue
        m = re.match(r'name\s*=\s*"([^"]*)"', s)
        if m:
            named = m.group(1) == tree
            continue
        if named:
            m = re.match(r'%s\s*=\s*"([^"]*)"' % re.escape(field), s)
            if m:
                return m.group(1)
    return None


def expand_repo(raw):
    if raw.startswith("$"):
        key = raw.lstrip("${").rstrip("}")
        return os.environ.get(key, "")
    return raw


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scan-file")
    ap.add_argument("--label")
    ap.add_argument("--rev")
    ap.add_argument("--source-repo")
    ap.add_argument("--manifest")
    ap.add_argument("--base-ref", default=os.environ.get("VENDOR_BASE_REF", "origin/main"))
    ap.add_argument("--repo-root", default=os.getcwd())
    a = ap.parse_args()
    try:
        refused = []
        if a.scan_file:
            src = open(a.scan_file, encoding="utf-8").read()
            refused, n = scan(src, a.label or a.scan_file)
            print("examined %d compartment_level=5 site(s) in %s" % (n, a.label or a.scan_file))
        elif a.rev:
            if not a.source_repo:
                raise CannotRun("--rev needs --source-repo")
            src = git_show(a.source_repo, a.rev, APPLE_REL)
            short = a.rev[:8] if re.fullmatch(r"[0-9a-f]{12,40}", a.rev) else a.rev
            refused, n = scan(src, "%s@%s" % (APPLE_REL, short))
            print("examined %d compartment_level=5 site(s) in upstream %s@%s" % (n, APPLE_REL, short))
        elif a.manifest:
            mtxt = open(a.manifest, encoding="utf-8").read()
            vpath = manifest_field(mtxt, TREE, "vendor_path")
            pin = manifest_field(mtxt, TREE, "pinned_sha")
            if not vpath or not pin:
                print("cm019 health-compartment: tree %s not in manifest; n/a" % TREE)
                return 0
            vf = os.path.join(a.repo_root, vpath, APPLE_REL)
            if not os.path.isfile(vf):
                raise CannotRun("vendored %s is missing; shipped bytes cannot be examined" % vf)
            r1, n1 = scan(open(vf, encoding="utf-8").read(), os.path.join(vpath, APPLE_REL))
            refused += r1
            print("examined %d compartment_level=5 site(s) in vendored %s" % (n1, os.path.join(vpath, APPLE_REL)))
            # was the pin moved? compare with BASE
            base = subprocess.run(
                ["git", "-C", a.repo_root, "show", "%s:vendor/VENDOR_MANIFEST.toml" % a.base_ref],
                capture_output=True, text=True)
            if base.returncode != 0:
                raise CannotRun("cannot read base manifest at %s (%s); cannot tell whether the pin moved"
                                % (a.base_ref, base.stderr.strip()))
            base_pin = manifest_field(base.stdout, TREE, "pinned_sha")
            if base_pin == pin:
                print("pin unchanged vs %s (%s): no re-pin to refuse; vendored bytes checked above" % (a.base_ref, pin[:8]))
            else:
                repo = os.environ.get("CM019") or expand_repo(manifest_field(mtxt, TREE, "source_repo") or "")
                if not repo or not os.path.isdir(repo):
                    raise CannotRun("re-pin %s -> %s but the CM019 source repo is not readable (set CM019)"
                                    % ((base_pin or "none")[:8], pin[:8]))
                src = git_show(repo, pin, APPLE_REL)
                r2, n2 = scan(src, "%s@%s" % (APPLE_REL, pin[:8]))
                refused += r2
                print("RE-PIN %s -> %s: examined %d compartment_level=5 site(s) in upstream"
                      % ((base_pin or "none")[:8], pin[:8], n2))
        else:
            ap.error("one of --scan-file, --rev, --manifest is required")
    except CannotRun as e:
        print("CANNOT-RUN: %s" % e, file=sys.stderr)
        return 2
    for line in refused:
        print(line, file=sys.stderr)
    if refused:
        print("REFUSED: %d site(s). Health must not be compartment 5 under the 133 outbound rule "
              "(only L1, L2, untagged pass); CM019 owns the fix. Do not re-pin or re-vendor until it lands."
              % len(refused), file=sys.stderr)
        return 1
    print("cm019 health-compartment: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
