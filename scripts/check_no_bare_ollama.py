#!/usr/bin/env python3
"""scripts/check_no_bare_ollama.py -- no shipped file may reach Ollama through PATH.

NEW-119. Since #2977 (bd9fe1a4) the Hub's engine lives ONLY at
~/.ostler/runtime/ollama-<pin>/ollama, and nothing puts it on PATH. A bare
`ollama pull` aborted a clean-Mac install at step 12/44 with
ERR-13-MODEL-PULL-NOMIC: rc 127, zero POST /api/pull in ollama.log. Walk boxes
had passed only because a system ollama happened to be on PATH.

This scans every TRACKED file outside the excluded set below and reports each
line that reaches Ollama by name rather than by path:

  shell   `ollama <subcommand>` in command position, `command -v ollama`,
          `which ollama`, `type -P ollama`
  python  ["ollama", "<subcommand>", ...] argv lists
  plist   <string>ollama</string> (a ProgramArguments argv0 with no path)
  copy    `ollama <subcommand>` inside a quoted string a customer is shown;
          on a clean Mac that command is rc 127 too

Not hits: comment lines; `pgrep -f`/`pkill -f` patterns (they MATCH the serve
process, they do not run anything); `"$OLLAMA_APP_BIN" pull` and any other
call through a variable or an absolute path.

A hit is allowed only if it is listed, with a reason, in the allowlist
(tests/bare_ollama_allowlist.tsv: path<TAB>exact stripped line<TAB>reason). An
allowlist row that no longer matches anything is ALSO a failure, so the list
can only shrink honestly.

Usage: check_no_bare_ollama.py [--root DIR] [--allowlist FILE] [--files-from FILE]
  --files-from: newline list of paths relative to root (default: git ls-files).
Exit: 0 clean, 1 hits / stale allowlist rows, 2 could not run.
"""
import argparse
import os
import re
import subprocess
import sys

SUB = r"(?:pull|list|run|show|rm|serve|ps|create|cp|stop|push)"

# Excluded from the scan, each with its reason. Keep this list SHORT.
EXCLUDE_PREFIXES = (
    "tests/",                      # tests stub ollama on purpose
    "scripts/tests/",              # ditto
    ".github/",                    # CI definitions, not shipped
    "docs/",                       # documentation
    "cut-manifests/",              # cut records quote historical text
    "walks/",                      # walk records
    "vendor/divergences/",         # patches quote BOTH sides of a diff
    "scripts/box_walk_probes/",    # walk harness, runs on the agent side over ssh, not in the DMG
)
EXCLUDE_SUFFIXES = (".md", ".tsv", ".yaml", ".yml", ".json", ".txt", ".patch", ".csv")
EXCLUDE_PARTS = ("/tests/", "Tests/")  # vendored trees' own test dirs; Xcode test targets

R_SHELL = re.compile(r"(?:^|[;&|({!`]|\$\(|\b(?:then|do|if|while|until|nohup|exec|time|xargs|sudo|env)\s)\s*ollama\s+" + SUB + r"\b")
R_RUNARG = re.compile(r"""\b(?:hpa_run|run|_run|retry)\s+(?:"[^"]*"|'[^']*')\s+ollama\s+""" + SUB + r"\b")
R_LOOKUP = re.compile(r"\b(?:command\s+-v|which|type\s+-P|hash)\s+ollama\b")
R_PYARGV = re.compile(r"""[\[(]\s*["']ollama["']\s*,\s*["']""" + SUB + r"""["']""")
R_PLIST = re.compile(r"<string>\s*ollama\s*</string>")
R_COPY = re.compile(r"""(["'])(?:(?!\1).)*?(?<![A-Za-z0-9_./${}-])ollama\s+""" + SUB + r"\b")
R_PGREP = re.compile(r"""\b(?:pgrep|pkill)\s+(?:-[a-zA-Z]+\s+)*["'][^"']*ollama\s+serve""")


def is_comment(s):
    return s.startswith(("#", "//", "* ", "/*", "--", "<!--")) or s == "*"


def classify(line):
    s = line.strip()
    if not s or is_comment(s):
        return None
    if R_PGREP.search(s) and not (R_SHELL.search(R_PGREP.sub("", s)) or R_COPY.search(R_PGREP.sub("", s))):
        return None
    for name, rx in (("shell", R_SHELL), ("shell", R_RUNARG), ("lookup", R_LOOKUP),
                     ("python", R_PYARGV), ("plist", R_PLIST), ("copy", R_COPY)):
        if rx.search(s):
            return name
    return None


def excluded(path):
    return (path.startswith(EXCLUDE_PREFIXES) or path.endswith(EXCLUDE_SUFFIXES)
            or any(p in "/" + path for p in EXCLUDE_PARTS)
            or os.path.basename(path).startswith("test_"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--allowlist", default=None)
    ap.add_argument("--files-from", default=None)
    a = ap.parse_args()
    root = a.root
    allow_path = a.allowlist or os.path.join(root, "tests", "bare_ollama_allowlist.tsv")

    if a.files_from:
        with open(a.files_from) as fh:
            files = [l.strip() for l in fh if l.strip()]
    else:
        r = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True)
        if r.returncode != 0:
            print(f"CANNOT-RUN: git ls-files failed: {r.stderr.strip()}")
            return 2
        files = r.stdout.splitlines()

    allow = {}
    if os.path.exists(allow_path):
        with open(allow_path) as fh:
            for raw in fh:
                if not raw.strip() or raw.startswith("#"):
                    continue
                parts = raw.rstrip("\n").split("\t")
                if len(parts) != 3 or not parts[2].strip():
                    print(f"FAIL  allowlist row without path/line/reason: {raw.rstrip()}")
                    return 1
                allow[(parts[0], parts[1])] = parts[2]

    scanned, hits, used = 0, [], set()
    for f in files:
        if excluded(f):
            continue
        p = os.path.join(root, f)
        if not os.path.isfile(p) or os.path.islink(p):
            continue
        try:
            with open(p, "rb") as fh:
                data = fh.read()
        except OSError as e:
            print(f"CANNOT-RUN: could not read {f}: {e}")
            return 2
        if b"\0" in data[:8192]:
            continue
        scanned += 1
        for n, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
            kind = classify(line)
            if not kind:
                continue
            key = (f, line.strip())
            if key in allow:
                used.add(key)
                continue
            hits.append((f, n, kind, line.strip()))

    if scanned == 0:
        print("CANNOT-RUN: scanned 0 files (a zero denominator is not a pass)")
        return 2
    stale = [k for k in allow if k not in used]
    for f, n, kind, s in hits:
        print(f"FAIL  {f}:{n} [{kind}] bare ollama: {s[:160]}")
    for f, s in stale:
        print(f"FAIL  stale allowlist row (matches nothing now): {f}\t{s[:120]}")
    print(f"scanned {scanned} files; {len(hits)} bare-ollama hit(s); {len(used)} allowlisted; {len(stale)} stale allowlist row(s)")
    return 1 if (hits or stale) else 0


if __name__ == "__main__":
    sys.exit(main())
