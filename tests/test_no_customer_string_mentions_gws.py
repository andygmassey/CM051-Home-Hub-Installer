#!/usr/bin/env python3
"""No customer-visible string names gws (the Google Workspace CLI).

The installer never installs gws (tests/test_install_never_installs_gws.sh),
yet the install-step hint for the Calendar / Gmail step told every customer, in
all 15 HintCopy files, that Ostler talks to Google "via Google's own Workspace
CLI (gws)". A promise about a tool that is not there.

Scans: every string VALUE in gui/OstlerInstaller/Resources/HintCopy*.json
(the internal "id" field and JSON keys are step identifiers, not shown).
NOT scanned: install.sh.strings.*.sh MSG_*GWS* log lines, which belong to the
code path that handles a gws left by an earlier install (separate follow-up).

PROVED-RED-BY: run with --self-test (planted gws value is caught, clean tree
is not) and on the pre-fix HintCopy files (15 hits).
"""
import glob, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAT = re.compile(r"\bgws\b|Workspace CLI", re.I)


def walk(x, path=""):
    if isinstance(x, str):
        yield path, x
    elif isinstance(x, dict):
        for k, v in x.items():
            if k == "id":
                continue
            yield from walk(v, f"{path}/{k}")
    elif isinstance(x, list):
        for i, v in enumerate(x):
            yield from walk(v, f"{path}/{i}")


def scan(root):
    hits, examined = [], 0
    for p in sorted(glob.glob(os.path.join(root, "gui/OstlerInstaller/Resources/HintCopy*.json"))):
        for path, s in walk(json.load(open(p, encoding="utf-8"))):
            examined += 1
            if PAT.search(s):
                hits.append(f"{os.path.relpath(p, root)}{path}")
    return hits, examined


def main():
    if "--self-test" in sys.argv:
        import tempfile
        d = tempfile.mkdtemp()
        os.makedirs(f"{d}/gui/OstlerInstaller/Resources")
        w = lambda s: json.dump({"s": {"id": "gws_install", "why": s}}, open(f"{d}/gui/OstlerInstaller/Resources/HintCopy.json", "w"))
        w("Ostler uses your Google sign-in.")
        h, n = scan(d)
        assert not h and n == 1, (h, n)
        w("via the Workspace CLI (gws)")
        h, n = scan(d)
        assert len(h) == 1, h
        print("self-test ok: clean=0 hits, planted=1 hit")
        return 0
    hits, examined = scan(ROOT)
    nfiles = len(glob.glob(os.path.join(ROOT, "gui/OstlerInstaller/Resources/HintCopy*.json")))
    print(f"examined {examined} customer strings, {nfiles} HintCopy files")
    if nfiles < 15 or examined < 300:
        print("CANNOT-RUN: denominator too small, predicate may be broken"); return 2
    for h in hits:
        print("FAIL", h)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
