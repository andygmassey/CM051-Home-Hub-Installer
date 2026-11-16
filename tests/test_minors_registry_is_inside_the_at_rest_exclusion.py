#!/usr/bin/env python3
"""The under-18 list sits inside the tree install.sh keeps out of Time Machine.

The file holds children's names. install.sh excludes ${OSTLER_DIR} (~/.ostler)
from Time Machine (a per-path xattr, which covers everything beneath it) and
drops a Spotlight opt-out marker there. The registry's DEFAULT path, as read by
the Doctor row and by the PWG ingest loader, is ~/.ostler/minors.json, so it is
covered WITHOUT a new exclusion. This test pins the three facts that makes true:

  1. install.sh calls _ostler_harden_at_rest on "$OSTLER_DIR".
  2. OSTLER_DIR defaults to ${HOME}/.ostler.
  3. the Doctor rule resolves the same default path.

NOT COVERED, stated plainly: an owner who points OSTLER_MINORS_FILE somewhere
else. That is an explicit override outside the hardened tree and nothing here
(or in install.sh) excludes it.

Run bare: python3 tests/test_minors_registry_is_inside_the_at_rest_exclusion.py
"""
import os
import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor" / "doctor" / "agent"))
FAILS = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


src = (REPO / "install.sh").read_text()
check(re.search(r'^_ostler_harden_at_rest "\$OSTLER_DIR"', src, re.M) is not None,
      'install.sh runs _ostler_harden_at_rest "$OSTLER_DIR"')
check(re.search(r'^OSTLER_DIR="\$\{OSTLER_DIR:-\$\{HOME\}/\.ostler\}"', src, re.M) is not None,
      "OSTLER_DIR defaults to ${HOME}/.ostler")
check('tmutil addexclusion "$_dir"' in src, "the exclusion is set on the directory (covers its contents)")

import diagnostic_rules as D  # noqa: E402

home = tempfile.mkdtemp()
os.environ.pop("OSTLER_MINORS_FILE", None)
os.environ["HOME"] = home
p = D._minors_registry_path()
check(p == Path(home) / ".ostler" / "minors.json", "the Doctor's default registry path is $HOME/.ostler/minors.json")
check(Path(home, ".ostler") in p.parents, "the registry default sits under the hardened tree")
# control: the predicate can fail
os.environ["OSTLER_MINORS_FILE"] = str(Path(home) / "elsewhere" / "minors.json")
check(Path(home, ".ostler") not in D._minors_registry_path().parents,
      "control: an OSTLER_MINORS_FILE override outside ~/.ostler is detected as outside")

print("RESULT:", "FAIL" if FAILS else "PASS")
sys.exit(1 if FAILS else 0)
