#!/usr/bin/env python3
"""CM051 #2552 and #2538, against the SHIPPED (vendored) Doctor.

#2552: GET /api/v1/config refused the Hub app's own read 403. The webview is
tauri://localhost, so WebKit stamps the fetch "cross-site"; a browser-served
Hub on :8000 stamps it "same-site". The read must be admitted for those two
callers and still refused for any other origin (half the test, or it cannot
tell "fixed" from "opened"). Same request shape as the walk probe
hub_screens_customer_read (Origin + Sec-Fetch-Site, synthetic token).

#2538: box_status bills the colima VM and llama-server to Ostler.

RED on main: the two Hub-origin reads answer 403 and the VM/runner read
"other". Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""
import os
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
AGENT = REPO / "vendor" / "doctor" / "agent"
sys.path.insert(0, str(AGENT))
sys.path.insert(0, str(REPO / "vendor" / "cm059_editor"))

try:
    from fastapi.testclient import TestClient
    tmp = tempfile.mkdtemp()
    os.environ["OSTLER_CONFIG_FILE"] = str(Path(tmp) / "config.yaml")
    import web_ui  # noqa: E402
    import box_status as bs  # noqa: E402
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT-RUN: the shipped Doctor did not import ({exc}). NOTHING was examined.")
    sys.exit(2)

client = TestClient(web_ui.app, base_url="http://127.0.0.1:8089")
fails = 0


def check(name, ok, detail=""):
    global fails
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + ("" if ok else f"  -- {detail}"))
    fails += 0 if ok else 1


def get(origin, site):
    h = {"Authorization": "Bearer synthetic-test-token"}
    if origin:
        h["Origin"] = origin
    if site:
        h["Sec-Fetch-Site"] = site
    return client.get("/api/v1/config", headers=h).status_code


r = get("tauri://localhost", "cross-site")
check("the Hub webview's read (tauri://localhost, cross-site) is admitted", 200 <= r < 300, r)
r = get("http://127.0.0.1:8000", "same-site")
check("a browser-served Hub's read (loopback :8000, same-site) is admitted", 200 <= r < 300, r)
r = get(None, "same-origin")
check("the Doctor's own /config panel (same-origin) is admitted", 200 <= r < 300, r)
r = get("https://evil.example", "cross-site")
check("a foreign page's read is still refused", r == 403, r)
r = get(None, "cross-site")
check("a cross-site read with no Origin is still refused", r == 403, r)

vm = ("/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
      "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/"
      "com.apple.Virtualization.VirtualMachine")
name = bs._basename(vm)
check("the colima VM is Ostler", bs._categorise(name, vm, "you") == "ostler", bs._categorise(name, vm, "you"))
check("llama-server is Ostler",
      bs._categorise("llama-server", "/opt/homebrew/bin/llama-server", "you") == "ostler")
check("the VM reads as a customer label", bs._LABELS.get(name) == "Ostler databases", bs._LABELS.get(name))

print(f"EXAMINED: 8 assertions, {fails} failed")
sys.exit(1 if fails else 0)
