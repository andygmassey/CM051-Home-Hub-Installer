#!/usr/bin/env python3
"""A click timeout in the customer-read probe must name its cause.

v1.0.120 walk: the log stopped at 'locator resolved to <a href="/people" ...>'
because the probe printed str(exc)[:200], cutting off the line that says WHY
(for a covered link: '<div ...> intercepts pointer events'). This drives the
real click_target() in Chromium against a synthetic page whose link is covered
by an overlay, and asserts the failure text names 'intercepts pointer events',
that the target is reported as covered with the covering selector, and that a
screenshot plus the console errors are written to the evidence dir (never
committed). Control: an uncovered link clicks without raising.

CUSTOMER_READ_SUBJECT=<path> points at another copy of customer_read.py (used to
show RED on main, which has no click_target: the fallback reproduces main's
behaviour, a plain click whose failure is printed as str(exc)[:200]).

Exit: 0 holds | 1 broken | 2 CANNOT RUN
"""
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SUBJ = os.environ.get("CUSTOMER_READ_SUBJECT") or os.path.join(HERE, "..", "scripts", "box_walk_probes", "lib", "customer_read.py")
try:
    from playwright.sync_api import sync_playwright
except ImportError as exc:
    print("CANNOT RUN: no Playwright (%s)" % exc)
    sys.exit(2)

spec = importlib.util.spec_from_file_location("customer_read_subject", SUBJ)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

PAGE = """<!doctype html><html><body style="margin:0">
<a id="free" href="#free" style="position:absolute;left:10px;top:200px">Free link</a>
<a href="/people" style="position:absolute;left:10px;top:10px;width:120px;height:30px;display:block">People</a>
<div id="cookie-wall" class="overlay wide" style="position:fixed;left:0;top:0;width:400px;height:100px;background:#ccc">Synthetic overlay</div>
<script>console.error('synthetic console error for the evidence file');</script>
</body></html>"""

fail = 0


def check(label, ok, detail=""):
    global fail
    print("  %s  %s%s" % ("ok  " if ok else "FAIL", label, "" if ok else "  [" + detail[:300] + "]"))
    fail += 0 if ok else 1


with sync_playwright() as pw, tempfile.TemporaryDirectory() as out:
    try:
        browser = pw.chromium.launch(headless=True)
    except Exception as exc:
        print("CANNOT RUN: chromium would not launch (%s)" % str(exc)[:160])
        sys.exit(2)
    page = browser.new_page(viewport={"width": 800, "height": 600})
    errs = []
    page.on("console", lambda m: errs.append("%s: %s" % (m.type, m.text)) if m.type == "error" else None)
    page.set_content(PAGE)
    page.wait_for_timeout(300)

    # control: an uncovered link clicks cleanly
    ctl = "none"
    try:
        if hasattr(mod, "click_target"):
            mod.click_target(page, "a#free", out, "control", errs, timeout_ms=2500)
        else:
            page.locator("a#free").first.click(timeout=2500)
    except Exception as exc:
        ctl = str(exc)
    check("control: an uncovered link clicks without raising", ctl == "none", ctl)

    # subject: the covered link
    msg = ""
    try:
        if hasattr(mod, "click_target"):
            mod.click_target(page, 'a[href="/people"]', out, "people", errs, timeout_ms=2500)
        else:
            page.locator('a[href="/people"]').first.click(timeout=2500)
    except Exception as exc:
        msg = str(exc) if hasattr(mod, "click_target") else str(exc)[:200]
    print("  --- failure text the walk would print ---")
    print("\n".join("      " + l for l in msg.splitlines()[-12:]))
    print("  ---")
    check("the failure text names 'intercepts pointer events'", "intercepts pointer events" in msg, msg)
    check("the target is reported covered, by which selector (div#cookie-wall)", "covered_by=div#cookie-wall" in msg, msg)
    check("visible and enabled are reported", "visible=True" in msg and "enabled=True" in msg, msg)
    shot = os.path.join(out, "cr-click-timeout-people.png")
    cons = os.path.join(out, "cr-click-timeout-people-console.txt")
    check("a screenshot is saved to the evidence dir", os.path.isfile(shot) and os.path.getsize(shot) > 0)
    check("the console errors are saved", os.path.isfile(cons) and "synthetic console error" in open(cons).read() if os.path.isfile(cons) else False)
    check("exc_tail keeps the last lines, not the first 200 chars",
          hasattr(mod, "exc_tail") and mod.exc_tail("a\n" * 100 + "THE CAUSE").endswith("THE CAUSE"))
    browser.close()

print("%s" % ("FAIL" if fail else "all hold"))
sys.exit(1 if fail else 0)
