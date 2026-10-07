#!/usr/bin/env python3
"""Vendor hub_contract.yaml (+ checkers) into a client repo and write its pin.

    scripts/pin_hub_contract.py <client-repo-dir> [--js]

Writes <client>/contract/hub_contract.yaml, hub_contract.pin.json and
hub_contract_check.py (and hub_contract_check.js with --js). The client's test
refuses to run if the yaml no longer matches the pin, so a hand edit is loud.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "vendor/cm041/assistant_api/hub_contract.yaml")


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    dest = os.path.join(argv[1], "contract")
    os.makedirs(dest, exist_ok=True)
    shutil.copy(SRC, os.path.join(dest, "hub_contract.yaml"))
    shutil.copy(os.path.join(REPO, "scripts/hub_contract_check.py"), dest)
    if "--js" in argv:
        shutil.copy(os.path.join(REPO, "scripts/hub_contract_check.js"), dest)
    try:
        ref = subprocess.check_output(["git", "-C", REPO, "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        ref = "unknown"
    pin = {"contract_sha256": hashlib.sha256(open(SRC, "rb").read()).hexdigest(),
           "source_repo": "andygmassey/CM051-Home-Hub-Installer",
           "source_path": "vendor/cm041/assistant_api/hub_contract.yaml",
           "pinned_from_commit": ref}
    with open(os.path.join(dest, "hub_contract.pin.json"), "w") as f:
        json.dump(pin, f, indent=1, sort_keys=True)
        f.write("\n")
    print("pinned %s into %s" % (pin["contract_sha256"][:12], dest))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
