"""Mutation harness: owner mail-domain probe (install.sh) and writer (lib/write_pipeline_signals.py).

Each mutant breaks one rule in a COPY of the tree, then runs the shell probe test
(INSTALL_SH pointed at the mutant) and the writer tests. Caught = red. The control
must be green. An anchor not found exactly once is NOT APPLIED and fails the run.

Run from the repo root: python3 tests/owner_mail_domains_mutants.py
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHELL_TEST = os.path.join("tests", "test_owner_mail_domains_probe.sh")
PY_TEST = os.path.join("tests", "test_owner_mail_domains_state.py")

MUTANTS = [
    ("S1 webmail not filtered in the installer",
     "install.sh",
     '        case " $_OWNER_WEBMAIL_DOMAINS " in',
     '        case " " in'),
    ("S2 the installer emits the full address, not the domain",
     "install.sh",
     "SELECT DISTINCT lower(substr(a.ZUSERNAME, instr(a.ZUSERNAME, '@') + 1))",
     "SELECT DISTINCT lower(a.ZUSERNAME)"),
    ("S3 unreadable store masked as no accounts",
     "install.sh",
     '    " 2>&1)" || return 1',
     '    " 2>/dev/null)" || true'),
    ("S4 parent-auth child rows counted",
     "install.sh",
     "        AND (a.ZAUTHENTICATIONTYPE IS NULL OR a.ZAUTHENTICATIONTYPE != 'parent')\n        AND COALESCE(a.ZACTIVE, 1) = 1\n        AND instr(a.ZUSERNAME, '@') > 0",
     "        AND 1=1\n        AND COALESCE(a.ZACTIVE, 1) = 1\n        AND instr(a.ZUSERNAME, '@') > 0"),
    ("S5 inactive accounts counted",
     "install.sh",
     "        AND COALESCE(a.ZACTIVE, 1) = 1\n        AND instr(a.ZUSERNAME, '@') > 0",
     "        AND 1=1\n        AND instr(a.ZUSERNAME, '@') > 0"),
    ("P1 writer accepts an address and reduces it to the domain",
     "lib/write_pipeline_signals.py",
     '            raise ValueError("owner mail: addresses are refused, domains only")',
     '            d = d.rsplit("@", 1)[1]'),
    ("P2 writer keeps webmail",
     "lib/write_pipeline_signals.py",
     "        if d in WEBMAIL_DOMAINS:\n            continue",
     "        if False:\n            continue"),
    ("P3 unknown sentinel clears the prior value",
     "lib/write_pipeline_signals.py",
     '        prior_domains = existing.get("owner_mail_domains")',
     "        prior_domains = None"),
    ("P4 webmail lists drift apart (icloud dropped from the writer)",
     "lib/write_pipeline_signals.py",
     '    "gmail.com", "googlemail.com", "icloud.com", "me.com",',
     '    "gmail.com", "googlemail.com", "me.com",'),
]


def _run(cmd, cwd, env=None):
    return subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True).returncode


def _suite_rc(root: str) -> int:
    env = dict(os.environ, INSTALL_SH=os.path.join(root, "install.sh"))
    a = _run(["bash", SHELL_TEST], root, env)
    b = _run([sys.executable, "-m", "pytest", PY_TEST, "-q", "-p", "no:cacheprovider"], root)
    return 0 if (a == 0 and b == 0) else 1


def _copy(dst: str) -> None:
    shutil.copy(os.path.join(ROOT, "install.sh"), os.path.join(dst, "install.sh"))
    os.makedirs(os.path.join(dst, "lib"))
    shutil.copy(os.path.join(ROOT, "lib", "write_pipeline_signals.py"),
                os.path.join(dst, "lib", "write_pipeline_signals.py"))
    shutil.copytree(os.path.join(ROOT, "tests"), os.path.join(dst, "tests"),
                    ignore=shutil.ignore_patterns("__pycache__"))


def main() -> int:
    work = tempfile.mkdtemp(prefix="omd-mut-")
    try:
        ctrl = os.path.join(work, "control")
        os.makedirs(ctrl)
        _copy(ctrl)
        rc = _suite_rc(ctrl)
        print(f"CONTROL rc={rc} ({'green' if rc == 0 else 'RED: run void'})")
        if rc != 0:
            return 2
        caught = survived = not_applied = 0
        for i, (name, target, old, new) in enumerate(MUTANTS):
            root = os.path.join(work, f"m{i:02d}")
            os.makedirs(root)
            _copy(root)
            path = os.path.join(root, target)
            text = open(path, encoding="utf-8").read()
            n = text.count(old)
            if n != 1:
                not_applied += 1
                print(f"NOT APPLIED  {name} (anchor found {n} times)")
                continue
            open(path, "w", encoding="utf-8").write(text.replace(old, new))
            if _suite_rc(root) != 0:
                caught += 1
                print(f"CAUGHT       {name}")
            else:
                survived += 1
                print(f"SURVIVED     {name}")
        print(f"SUMMARY mutants={len(MUTANTS)} caught={caught} survived={survived} not_applied={not_applied}")
        return 0 if survived == 0 and not_applied == 0 else 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
