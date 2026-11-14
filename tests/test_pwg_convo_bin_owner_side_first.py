#!/usr/bin/env python3
"""ical-server's pwg-convo default resolves the owner-side link first.

Same-shape sweep 2026-11-14 (PWG_CONVO_BIN). The GUI installer links pwg-convo
into ${OSTLER_DIR}/bin because /usr/local/bin is root-owned on a stock Mac. The
launchd plist for com.ostler.ical-server sets no PWG_CONVO_BIN, so the default
is what runs. Proves on synthetic paths only:
  1. an owner-side pwg-convo wins over /usr/local/bin;
  2. with no owner-side link the default is /usr/local/bin (CLI install);
  3. an explicit PWG_CONVO_BIN still wins;
  4. the plist does not set PWG_CONVO_BIN (read from install.sh), so the
     default is the production path.
RED on the pre-change module: there is no _default_pwg_convo_bin, so arm 1
raises AttributeError. Run bare: python3 tests/test_pwg_convo_bin_owner_side_first.py
"""
import importlib.util
import os
import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "vendor"))  # ostler_security, which ical-server imports at load

FAILS = []


def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def load_ical():
    spec = importlib.util.spec_from_file_location(
        "ical_server_under_test", REPO / "vendor" / "cm041" / "assistant_api" / "ical-server.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ical = load_ical()
saved = {k: os.environ.pop(k, None) for k in ("PWG_CONVO_BIN", "OSTLER_DIR")}

with tempfile.TemporaryDirectory() as td:
    home = os.path.join(td, "owner")
    owner_bin = os.path.join(home, ".ostler", "bin")
    os.makedirs(owner_bin)
    owner_link = os.path.join(owner_bin, "pwg-convo")
    open(owner_link, "w").close()

    got = ical._default_pwg_convo_bin(home=home)
    check(got == owner_link, f"1 owner-side pwg-convo wins over /usr/local/bin (got {got})")

    empty = os.path.join(td, "cli-owner")
    os.makedirs(empty)
    got2 = ical._default_pwg_convo_bin(home=empty)
    check(got2 == "/usr/local/bin/pwg-convo", f"2 no owner-side link: /usr/local/bin (got {got2})")

    os.environ["PWG_CONVO_BIN"] = "/opt/synthetic/pwg-convo"
    ical2 = load_ical()
    check(ical2.PWG_CONVO_BIN == "/opt/synthetic/pwg-convo", "3 explicit PWG_CONVO_BIN still wins")
    os.environ.pop("PWG_CONVO_BIN", None)

plist_src = (REPO / "install.sh").read_text(encoding="utf-8")
ical_block = plist_src[plist_src.index("com.ostler.ical-server.plist\"\n        cat >"):]
ical_block = ical_block[:ical_block.index("ICALPLISTEOF\n", 200)]
check("OSTLER_API_PORT" in ical_block and "PWG_CONVO_BIN" not in ical_block,
      "4 the ical-server plist (block found, env present) does not override PWG_CONVO_BIN")

for k, v in saved.items():
    if v is not None:
        os.environ[k] = v

if FAILS:
    print(f"\n{len(FAILS)} FAILED")
    sys.exit(1)
print("\nAll owner-side pwg-convo default checks passed.")
