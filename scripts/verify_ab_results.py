#!/usr/bin/env python3
"""A/B chat-regression gate for assistant (hub) re-pins.

A PR that changes DAEMON_SHA256 or HUB_APP_SHA256 in gui/Makefile must carry
ab-results/<new DAEMON_SHA256>.tsv with no chat regressions
(rule: n=10, drop = pass fell by more than 2, or new_pass < 8, or tools_none rose by more than 2).

  verify_ab_results.py --base <sha> --head <sha>   gate a PR (exit 0 pass/skip, 1 fail)
  verify_ab_results.py --file <path> [--sha <hex>] check one results file

The file format lives in ONE function, parse_results(). Change it there.
The file is committed to a PUBLIC repo, so the parser is an allowlist: run_stamp and run_host lines, fixed
header, an id column, integer columns, a final drops=<int> line, nothing else.
The gate checks presence and arithmetic only. The file is self-reported, so it
cannot prove the A/B ran; review checks stamp and host against the lab log.
Tests: tests/test_ab_results_gate.sh
"""
import os
import re
import subprocess
import sys

MAKEFILE = "gui/Makefile"
PIN_NAMES = ("DAEMON_SHA256", "HUB_APP_SHA256")
HEADER = ["question_id", "old_pass", "new_pass", "n", "old_tools_none",
          "new_tools_none", "old_p50_ms", "new_p50_ms"]
ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
INT_RE = re.compile(r"^[0-9]{1,9}$")
# Drop rule (Archie, 2026-10-11). n=10 runs per question; the A/B is noisy, so a
# loss of up to NOISE passes is tolerated, but the new build must still clear
# FLOOR passes on every question, even one the old build also failed.
N_REQUIRED = 10
NOISE = 2
FLOOR = 8
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
STAMP_RE = re.compile(r"^run_stamp=[0-9]{8}T[0-9]{6}Z$")
HOST_RE = re.compile(r"^run_host=[a-z0-9-]{1,40}$")


def parse_results(text):
    """Return (errors, recomputed_drops, declared_drops). Only place the format is known."""
    errors = []
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if len(lines) < 5:
        return ["file needs run_stamp, run_host, a header, at least one row, and a drops= line"], None, None
    if not STAMP_RE.match(lines[0]):
        errors.append("line 1 must be run_stamp=YYYYMMDDTHHMMSSZ")
    if not HOST_RE.match(lines[1]):
        errors.append("line 2 must be run_host=[a-z0-9-]{1,40}")
    if lines[2].split("\t") != HEADER:
        errors.append("header must be exactly: " + " ".join(HEADER)
                      + " (extra or renamed columns are rejected)")
    m = re.fullmatch(r"drops=([0-9]{1,9})", lines[-1])
    if not m:
        errors.append("last line must be drops=<int>")
    declared = int(m.group(1)) if m else None
    drops = 0
    for i, line in enumerate(lines[3:-1], start=4):
        cells = line.split("\t")
        if len(cells) != len(HEADER):
            errors.append("line %d: %d cells, want %d" % (i, len(cells), len(HEADER)))
            continue
        if not ID_RE.match(cells[0]):
            errors.append("line %d: question_id is not a plain id" % i)
            continue
        bad = [HEADER[j] for j in range(1, len(HEADER)) if not INT_RE.match(cells[j])]
        if bad:
            errors.append("line %d: not an integer: %s" % (i, ",".join(bad)))
            continue
        v = dict(zip(HEADER[1:], map(int, cells[1:])))
        if v["n"] != N_REQUIRED:
            errors.append("line %d: n must be %d, got %d" % (i, N_REQUIRED, v["n"]))
            continue
        if (v["new_pass"] < v["old_pass"] - NOISE or v["new_pass"] < FLOOR
                or v["new_tools_none"] > v["old_tools_none"] + NOISE):
            drops += 1
            errors.append("line %d: %s dropped (pass %d->%d, floor %d, tools_none %d->%d)" % (
                i, cells[0], v["old_pass"], v["new_pass"], FLOOR,
                v["old_tools_none"], v["new_tools_none"]))
    return errors, drops, declared


def check_text(text):
    errors, drops, declared = parse_results(text)
    if declared is not None and declared != 0:
        errors.append("drops line says %d, must be 0" % declared)
    if declared is not None and declared != drops:
        errors.append("drops line (%d) disagrees with recomputed rows (%d)" % (declared, drops))
    return errors


def pins(makefile_text):
    out = {}
    for name in PIN_NAMES:
        m = re.search(r"^%s\s*\?=\s*([0-9a-f]{64})\s*$" % name, makefile_text, re.M)
        out[name] = m.group(1) if m else None
    return out


def git_show(rev, path, cwd):
    r = subprocess.run(["git", "show", "%s:%s" % (rev, path)], cwd=cwd,
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def git_out(args, cwd):
    r = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def rerun_errors(base, head, cwd):
    """One file per sha: modifying/deleting an existing results file needs an ab-rerun: line."""
    changed = [l.split("\t", 1) for l in git_out(
        ["diff", "--name-status", base, head, "--", "ab-results/"], cwd).splitlines()]
    touched = [p for st, p in changed if st[0] in "MDR"]
    if not touched:
        return []
    msgs = git_out(["log", "%s..%s" % (base, head), "--format=%B"], cwd)
    if re.search(r"^ab-rerun: \S", msgs, re.M):
        return []
    return ["PR modifies existing %s without an 'ab-rerun: <reason>' line in a commit message" % p
            for p in touched]


def gate(base, head, cwd="."):
    rerr = rerun_errors(base, head, cwd)
    for e in rerr:
        print("FAIL: " + e)
    if rerr:
        return 1
    old, new = pins(git_show(base, MAKEFILE, cwd)), pins(git_show(head, MAKEFILE, cwd))
    if new["DAEMON_SHA256"] is None:
        print("FAIL: cannot read DAEMON_SHA256 from %s at head" % MAKEFILE)
        return 1
    changed = [n for n in PIN_NAMES if old[n] != new[n]]
    if not changed:
        print("SKIP: DAEMON_SHA256 and HUB_APP_SHA256 unchanged, A/B gate does not apply")
        return 0
    rel = "ab-results/%s.tsv" % new["DAEMON_SHA256"]
    print("re-pin detected (%s); requiring %s" % (",".join(changed), rel))
    text = git_show(head, rel, cwd)
    if not text:
        print("FAIL: missing A/B results file committed in this PR: %s" % rel)
        return 1
    errors = check_text(text)
    if errors:
        for e in errors:
            print("FAIL: %s: %s" % (rel, e))
        return 1
    print("PASS: %s has drops=0 and no row regressions" % rel)
    return 0


def main(argv):
    a = dict(zip(argv[::2], argv[1::2]))
    if "--file" in a:
        if not os.path.isfile(a["--file"]):
            print("FAIL: missing A/B results file: %s" % a["--file"])
            return 1
        with open(a["--file"], encoding="utf-8") as f:
            errs = check_text(f.read())
        for e in errs:
            print("FAIL: %s" % e)
        return 1 if errs else 0
    if "--base" in a and "--head" in a:
        return gate(a["--base"], a["--head"])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
