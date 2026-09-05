#!/usr/bin/env bash
# ===========================================================================
# EVERY PlistBuddy READ MUST TAKE ITS EXIT CODE OR VALIDATE THE SHAPE.
#
# test_a_plistbuddy_read_takes_its_exit_code.sh proves the CLASS is real and
# drives ONE site: install.sh's _upg_ensure_token read. That is why five other
# sites carried the same defect unnoticed until 2026-09-05.
#
# PlistBuddy answers on STDOUT when it fails, so `2>/dev/null` cannot suppress
# it and `|| true` discards the exit code. The message is NON-EMPTY, which
# defeats a bare `[[ -n ... ]]` or `[ -z ... ]` guard: the failure text travels
# on as the value. Measured consequences in this repo:
#
#   verify_commit_parity.sh   the message became the executable NAME and the
#                             gate blamed "wrapper binary not found" (#1524)
#   verify_app_provenance.sh  same shape, same wrong subject
#   post_walk_qa.sh           with no version argument, recorded the message as
#                             version_source=measured(...)
#   verify_customer_download_path.sh  printed it as "served version"
#
# This is a CENSUS, not a single drive: it finds every PlistBuddy read and
# requires each to be guarded by an exit-code test or a shape test within a few
# lines. A bare emptiness check is not a guard.
# ===========================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$REPO" ] || { printf 'CANNOT-RUN: no repo root.\n' >&2; exit 2; }

python3 - "$REPO" <<'PY'
import os, re, sys
repo = sys.argv[1]

files = [os.path.join(repo, "install.sh")]
sdir = os.path.join(repo, "scripts")
for n in sorted(os.listdir(sdir)):
    if n.endswith(".sh"):
        files.append(os.path.join(sdir, n))

READ  = re.compile(r'PlistBuddy\s+-c\s')
# `if VAR="$(...)"` is the HARDENED form -- it takes the exit code -- so the
# assignment matcher has to see it, or the census flags exactly the shape it
# is asking people to adopt. Measured: it flagged my own two fixes.
ASSIGN = re.compile(r'^\s*(if\s+)?(\w+)="\$\(')

sites, unguarded = 0, []
for f in files:
    if not os.path.isfile(f):
        continue
    lines = open(f, encoding="utf-8", errors="replace").read().split("\n")
    for i, l in enumerate(lines):
        if not READ.search(l) or l.lstrip().startswith("#"):
            continue
        sites += 1

        # KEY ON THE ASSIGNED VARIABLE, NOT ON A LINE WINDOW.
        #
        # A fixed window is the wrong shape twice over: a multi-line read pushes
        # the guard past it, and so does a long comment explaining the guard.
        # Measured: my own fix in post_walk_qa.sh sat at :378 for a read at
        # :358 and this census called it unguarded, because the comment
        # justifying it was fourteen lines long.
        var, takes_rc = None, False
        for j in range(i, max(-1, i - 6), -1):
            m = ASSIGN.match(lines[j])
            if m:
                takes_rc = bool(m.group(1))
                var = m.group(2)
                break
        if takes_rc:
            # `if VAR="$(...)"` IS the remedy: the exit code decides whether the
            # value is used at all. Nothing further to look for.
            continue
        if var is None:
            unguarded.append(f"{os.path.relpath(f, repo)}:{i+1} (no assignment found)")
            continue

        # Guarded if, before the next blank-line-separated paragraph ends OR
        # within 30 lines, that variable is shape-checked or emptied on failure.
        v = re.escape(var)
        guard = re.compile("|".join([
            r'\$\{?' + v + r'\b[^\n]*(=~\s*\^|== /\*)',
            r'case\s+"?\$\{?' + v,
            r'\|\|\s*' + v + r'=""',
        ]))
        window = "\n".join(lines[max(0, i - 3): i + 30])
        if guard.search(window):
            continue
        unguarded.append(f"{os.path.relpath(f, repo)}:{i+1} (${var})")

print(f"  PlistBuddy read sites examined : {sites}")
print(f"  unguarded                      : {len(unguarded)}")

# ANTI-VACUITY. A census that finds no sites has not proved anything.
if sites < 4:
    print(f"CANNOT-RUN: only {sites} PlistBuddy read(s) found; the scan no longer "
          "matches how these reads are written.", file=sys.stderr)
    raise SystemExit(2)

if unguarded:
    print("FAIL: a PlistBuddy read with no exit-code or shape guard:", file=sys.stderr)
    for u in unguarded:
        print(f"      {u}", file=sys.stderr)
    print("      PlistBuddy answers on STDOUT when it fails, so a bare -n/-z check", file=sys.stderr)
    print("      passes on the failure message and it travels on as the value.", file=sys.stderr)
    raise SystemExit(1)

print(f"PASS: all {sites} PlistBuddy reads take an exit code or check a shape.")
PY
