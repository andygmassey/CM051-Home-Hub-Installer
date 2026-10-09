#!/usr/bin/env python3
"""List which client pins of hub_contract.yaml are stale.

    scripts/hub_contract_drift.py [--local-root DIR] [--strict]

Reads hub_contract_clients.json. For each client it fetches
contract/hub_contract.pin.json from the client's default branch (via `gh api`,
or from DIR/<name> with --local-root) and compares contract_sha256 with this
checkout's contract. Prints a table; with $GITHUB_STEP_SUMMARY set, appends it.

Exit: 0 all current (or stale without --strict) / 1 stale with --strict /
2 could not read a client (never printed as "current").
"""
import base64
import hashlib
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTRACT = os.path.join(REPO, "vendor/cm041/assistant_api/hub_contract.yaml")


def fetch_pin(client, local_root):
    if local_root:
        p = os.path.join(local_root, client["dir"], "contract/hub_contract.pin.json")
        return json.load(open(p)) if os.path.isfile(p) else "NO-PIN"
    r = subprocess.run(["gh", "api", "repos/%s/contents/contract/hub_contract.pin.json" % client["repo"],
                        "--jq", ".content"], capture_output=True, text=True)
    if r.returncode != 0:
        return "NO-PIN" if "404" in r.stderr else "UNREADABLE: " + r.stderr.strip()[:120]
    return json.loads(base64.b64decode(r.stdout))


def main(argv):
    local = argv[argv.index("--local-root") + 1] if "--local-root" in argv else None
    cur = hashlib.sha256(open(CONTRACT, "rb").read()).hexdigest()
    clients = json.load(open(os.path.join(REPO, "hub_contract_clients.json")))["clients"]
    rows, bad, unread = [], 0, 0
    for c in clients:
        pin = fetch_pin(c, local)
        if isinstance(pin, str):
            state = pin
            unread += pin.startswith("UNREADABLE")
            bad += not pin.startswith("UNREADABLE")
        elif pin["contract_sha256"] == cur:
            state = "current"
        else:
            state = "STALE (pinned %s)" % pin["contract_sha256"][:12]
            bad += 1
        rows.append((c["repo"], state))
    out = ["| client | pin vs %s |" % cur[:12], "|---|---|"] + ["| %s | %s |" % r for r in rows]
    text = "\n".join(out)
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("### hub_contract.yaml client pins\n" + text + "\n")
    if unread:
        return 2
    if bad:
        for r in rows:
            if r[1] != "current":
                print("::warning::%s pin is %s" % r)
        return 1 if "--strict" in argv else 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
