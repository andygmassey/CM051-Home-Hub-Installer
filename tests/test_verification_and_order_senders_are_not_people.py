#!/usr/bin/env python3
"""Walk 121 (hub_screens_customer_read): 2 of 7,433 People rows were services.

Shapes "<x> Verification" and "order <x>" (uncarded, no phone, no email) passed
_is_automated_or_service_name, whose vocabulary had no "verification" or
"order", so people_list kept them while the probe's SERVICE_PHRASE flagged them.
Synthetic names only. A carded or phone-bearing row is never judged by this
(see people_list); the controls below are ordinary person names.

Exit 0 pass, 1 fail, 2 cannot-run.
"""
import importlib.util
import pathlib
import sys

SRC = pathlib.Path(__file__).resolve().parent.parent / "vendor/cm041/assistant_api/people_rules.py"
try:
    spec = importlib.util.spec_from_file_location("people_rules", SRC)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
except Exception as exc:
    print("CANNOT-RUN: could not import", SRC, exc)
    sys.exit(2)

f = mod._is_automated_or_service_name
SERVICES = ["acme app verification", "order review", "order confirmation", "your orders", "verify your email"]
PEOPLE = ["Jane Doe", "John Smith", "Alex Jones", "Sam Patel", "Bob Brown", "jane orderly"]
bad = [n for n in SERVICES if not f(n)] + [n for n in PEOPLE if f(n)]
for n in SERVICES:
    print("  {}    service shape hidden: {}".format("ok  " if f(n) else "FAIL", n))
for n in PEOPLE:
    print("  {}    person kept: {}".format("ok  " if not f(n) else "FAIL", n))
print("RESULT: {}".format("FAIL" if bad else "PASS"), bad or "")
sys.exit(1 if bad else 0)
