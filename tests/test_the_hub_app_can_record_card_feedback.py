#!/usr/bin/env python3
"""The Hub app's own webview may record a Front Page card tap (#106c, item g).

"Not me" never stuck. The Hub posted nothing at all (fixed in the hub web
code), and the route it must reach, /api/v1/editor/feedback on the Doctor,
refused the app's origin anyway: the bundled frontend is served from the
tauri:// scheme and origin_is_local() accepted only http(s) loopback. So a tap
from the real app was a 403 before it reached CM059's CorrectionStore.

Exit 0 all pass, 1 any fail, 2 CANNOT-RUN.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "vendor", "doctor", "agent"))
try:
    from editor_feedback import origin_is_local
except Exception as exc:
    print("CANNOT-RUN: {}".format(exc))
    sys.exit(2)

FAILS = []


def check(name, cond):
    print(("  ok    " if cond else "  FAIL  ") + name)
    if not cond:
        FAILS.append(name)


check("the Hub app webview origin is accepted", origin_is_local("tauri://localhost"))
check("a loopback browser origin is still accepted", origin_is_local("http://127.0.0.1:8000"))
check("an absent origin (non-browser caller) is accepted", origin_is_local(None))
check("a remote web origin is still refused", not origin_is_local("https://evil.example"))
check("a lookalike tauri host is refused", not origin_is_local("tauri://localhost.evil.example"))
check("a lookalike subdomain is refused", not origin_is_local("http://localhost.evil.example"))
print("{} fail".format(len(FAILS)))
sys.exit(1 if FAILS else 0)
