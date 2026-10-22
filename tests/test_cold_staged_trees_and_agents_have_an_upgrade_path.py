#!/usr/bin/env python3
"""RATCHET: everything the COLD install stages must have an upgrade counterpart,
or a recorded decision why not.

WHY. 118 blocker. The cold install stages ~15 vendored trees and installs ~35
LaunchAgents. The Sparkle upgrade path (OSTLER_UPGRADE_MODE) refreshes a handful
and exits before the rest, so cm019 and the "What you like" derive agent never
reached any box that upgraded: smart-prefs did not exist for them. The same
shape can hide anywhere, so this enumerates it FROM install.sh and fails when a
new cold-staged tree or agent has no upgrade counterpart and no baseline row.

WHAT IT ENUMERATES (from install.sh itself, never a hand list)
  trees   every `cp -R/rsync -a "${SCRIPT_DIR}/<tree>"` and `*_BUNDLE="${SCRIPT_DIR}/<tree>"`
          OUTSIDE the upgrade block (cold) vs `${_UPG_PAYLOAD}/<tree>` INSIDE it (upgrade)
  agents  every com.ostler.* / com.creativemachines.ostler* label OUTSIDE the
          upgrade block (cold) vs INSIDE it (upgrade)

BASELINE scripts/upgrade_parity.tsv: kind, name, status (covered | cold-only),
reason. FAILS when
  1  a cold item is not in the baseline (new, unclassified)
  2  a baseline `covered` item is no longer reached by the upgrade block
  3  a baseline `cold-only` item now IS covered (tighten the baseline)
  4  a baseline row names something the cold install no longer stages
A `cold-only` row needs a reason that begins `118 decision:` or `fixed:`.

SELF-TEST (mutants, run on every invocation): a fake cold-staged tree and a fake
agent must trip (1); removing the cm019 refresh from the upgrade block must trip (2).
Exit: 0 pass, 1 fail, 2 cannot-run.
"""
from __future__ import annotations

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALL = os.environ.get("INSTALL_SH", os.path.join(REPO, "install.sh"))
BASELINE = os.environ.get("UPGRADE_PARITY_TSV", os.path.join(REPO, "scripts", "upgrade_parity.tsv"))

_UPG_START = re.compile(r'^if \[\[ "\$\{OSTLER_UPGRADE_MODE:-0\}" == "1"')
_TREE_COLD = re.compile(r'^\s*(?:\[\[ -d [^\]]*\]\] && )?(?:cp -R|rsync -a)\s+"?\$\{SCRIPT_DIR\}/([A-Za-z0-9_.-]+)')
_TREE_BUNDLE = re.compile(r'^\s*[A-Z0-9_]*_BUNDLE="\$\{SCRIPT_DIR\}/([A-Za-z0-9_.-]+)"')
_TREE_UPG = re.compile(r'\$\{_UPG_PAYLOAD\}/([A-Za-z0-9_.-]+)')
_LABEL = re.compile(r'\bcom\.(?:ostler|creativemachines\.ostler)[A-Za-z0-9._-]*')


def split_regions(text):
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines) if _UPG_START.match(l)), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if lines[i] == "fi"), None)
    if end is None:
        return None
    return lines[:start] + lines[end + 1:], lines[start:end + 1]


def clean_label(raw):
    s = re.sub(r'\.(plist|log|out|err|sh)$', '', raw).rstrip('.-')
    return s if s.count('.') >= 2 or '-' in s.split('.')[-1] and s.count('.') >= 1 and s != 'com.ostler' else None


def enumerate_items(text):
    regions = split_regions(text)
    if regions is None:
        return None
    cold, upg = regions
    trees_cold, trees_upg, ag_cold, ag_upg = set(), set(), set(), set()
    for l in cold:
        if l.lstrip().startswith("#"):
            continue
        m = _TREE_COLD.match(l) or _TREE_BUNDLE.match(l)
        if m:
            trees_cold.add(m.group(1))
        for raw in _LABEL.findall(l):
            c = clean_label(raw)
            if c and c not in ("com.ostler", "com.creativemachines.ostler"):
                ag_cold.add(c)
    for l in upg:
        if l.lstrip().startswith("#"):
            continue
        for m in _TREE_UPG.finditer(l):
            trees_upg.add(m.group(1))
        # A label only counts where the upgrade ACTS on it (kick, bootstrap, a
        # *_LABEL= it manages, an _install_*_agent). A log message that names an
        # agent, or a plist it merely reads, is not coverage.
        if not re.search(r'_ks_bounded|launchctl|_LABEL=|_install_', l):
            continue
        for raw in _LABEL.findall(l):
            c = clean_label(raw)
            if c:
                ag_upg.add(c)
    # a payload tree the upgrade names under its payload alias
    alias = {"doctor": "doctor", "knowledge": "cm024_knowledge", "cm024_knowledge": "cm024_knowledge"}
    trees_upg = {alias.get(t, t) for t in trees_upg}
    return trees_cold, trees_upg, ag_cold, ag_upg


def load_baseline(path):
    rows = {}
    with open(path) as f:
        for ln in f:
            if ln.startswith("#") or not ln.strip():
                continue
            p = ln.rstrip("\n").split("\t")
            if len(p) < 4:
                raise SystemExit(f"CANNOT-RUN: malformed baseline row: {ln!r}")
            rows[(p[0], p[1])] = (p[2], p[3])
    return rows


def check(text, baseline):
    """-> list of failure strings."""
    en = enumerate_items(text)
    if en is None:
        raise SystemExit("CANNOT-RUN: could not find the upgrade block in install.sh")
    tc, tu, ac, au = en
    if not tc or not ac:
        raise SystemExit(f"CANNOT-RUN: enumeration found {len(tc)} trees / {len(ac)} agents; the scan is blind")
    fails = []
    for kind, cold, upg in (("tree", tc, tu), ("agent", ac, au)):
        for name in sorted(cold):
            row = baseline.get((kind, name))
            covered = name in upg
            if row is None:
                fails.append(f"1 NEW {kind} {name!r} is staged by the cold install with {'an' if covered else 'NO'} upgrade counterpart and is not in the baseline")
                continue
            status, reason = row
            if status == "covered" and not covered:
                fails.append(f"2 {kind} {name!r} is baseline-covered but the upgrade block no longer reaches it")
            if status == "cold-only" and covered:
                fails.append(f"3 {kind} {name!r} is now covered by the upgrade block; mark it covered in the baseline")
            if status == "cold-only" and not re.match(r'(118 decision|fixed):', reason):
                fails.append(f"5 {kind} {name!r} is cold-only without a '118 decision:' or 'fixed:' reason")
        for (k, name), _ in baseline.items():
            if k == kind and name not in cold:
                fails.append(f"4 baseline names {kind} {name!r} but the cold install no longer stages it")
    return fails


def main():
    if not os.path.isfile(INSTALL) or not os.path.isfile(BASELINE):
        print("CANNOT-RUN: install.sh or the baseline is missing")
        return 2
    text = open(INSTALL).read()
    baseline = load_baseline(BASELINE)
    en = enumerate_items(text)
    if en is None:
        print("CANNOT-RUN: upgrade block not found")
        return 2
    tc, tu, ac, au = en
    cov_t = sorted(tc & tu); only_t = sorted(tc - tu)
    cov_a = sorted(ac & au); only_a = sorted(ac - au)
    print(f"TABLE  cold-staged trees {len(tc)}: upgrade-covered {len(cov_t)}, cold-only {len(only_t)}")
    print(f"TABLE  cold agents       {len(ac)}: upgrade-covered {len(cov_a)}, cold-only {len(only_a)}")
    fails = check(text, baseline)
    for f in fails:
        print("  FAIL", f)
    ok = not fails
    print("  %s the baseline accounts for every cold-staged tree and agent" % ("PASS" if ok else "FAIL"))

    # --- self-test: mutants must trip the ratchet --------------------------------
    mut_ok = True
    fake_tree = text + '\ncp -R "${SCRIPT_DIR}/zz_fake_tree" "$HOME/.ostler/zz/"\n'
    if not any(f.startswith("1 NEW tree 'zz_fake_tree'") for f in check(fake_tree, baseline)):
        print("  FAIL mutant: a fake cold-staged tree did not trip the ratchet"); mut_ok = False
    else:
        print("  PASS mutant: a fake cold-staged tree trips the ratchet (RED)")
    fake_agent = text + '\n# x\nlaunchctl bootstrap gui/501 "$HOME/Library/LaunchAgents/com.ostler.zz-fake-agent.plist"\n'
    if not any("'com.ostler.zz-fake-agent'" in f for f in check(fake_agent, baseline)):
        print("  FAIL mutant: a fake cold agent did not trip the ratchet"); mut_ok = False
    else:
        print("  PASS mutant: a fake cold agent trips the ratchet (RED)")
    # the payload path inside the upgrade block IS the upgrade counterpart
    stripped = re.sub(r'\$\{_UPG_PAYLOAD\}/cm019_preferences', '${_UPG_PAYLOAD}/removed', text)
    if not any("tree 'cm019_preferences'" in f and f.startswith("2") for f in check(stripped, baseline)):
        print("  FAIL mutant: removing the cm019 refresh did not trip the ratchet"); mut_ok = False
    else:
        print("  PASS mutant: removing the cm019 refresh from the upgrade block trips the ratchet (RED)")
    return 0 if (ok and mut_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
