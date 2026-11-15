#!/usr/bin/env python3
"""The customer read must dismiss the Hub's first-run welcome the way a customer does.

v1.0.121 trial: click a[href="/"] timed out because the GovernorWelcomeModal
(<div role="dialog" aria-labelledby="governor-welcome-title">) intercepted pointer
events. This drives the real click_target() in Chromium against synthetic pages
shaped like that modal (its "Not now" and "Close welcome" buttons, both closing it
the way React does: unmounting on a click handler).

Cases:
  1. modal present: the nav click succeeds, the modal was closed by a real click on
     its own button (recorded by the page's handler, so a JS removal or a
     force-click would not satisfy it), and the dialog is gone.
  2. only the corner X ("Close welcome") present: dismissed through it.
  3. no modal (control): the click succeeds, nothing else happens.
  4. modal with no known button: fails LOUD, naming the cause (not a 30 s timeout).
  5. modal whose button does not close it: fails LOUD ("still open").

CUSTOMER_READ_SUBJECT=<path> points at another copy of customer_read.py (the trial
tree's copy gives RED: case 1 and 2 time out on 'intercepts pointer events').

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

NAV = '<nav><a id="home" href="#went" onclick="window.__went=true">Home</a></nav>'
COVER = ('<div role="dialog" aria-modal="true" aria-labelledby="governor-welcome-title" '
         'style="position:fixed;left:0;top:0;width:100%;height:100%;z-index:1000;background:rgba(0,0,0,.35)">'
         '<div style="position:relative;margin:80px auto;width:400px;background:#fff;padding:20px">')
H1 = '<h1 id="governor-welcome-title">Synthetic welcome</h1>'
CLOSE_JS = "window.__closedBy=%s;this.closest('[role=dialog]').remove()"
X_BTN = '<button aria-label="Close welcome" onclick="' + CLOSE_JS % "'x'" + '">x</button>'
NOTNOW = '<button onclick="' + CLOSE_JS % "'notnow'" + '">Not now</button>'
OPEN_GOV = '<button onclick="window.__closedBy=\'open\'">Open Governor</button>'
END = "</div></div>"

PAGES = {
    "both": "<!doctype html><body>" + NAV + COVER + X_BTN + H1 + OPEN_GOV + NOTNOW + END,
    "x_only": "<!doctype html><body>" + NAV + COVER + X_BTN + H1 + END,
    "none": "<!doctype html><body>" + NAV,
    "unknown_button": "<!doctype html><body>" + NAV + COVER + H1 + '<button>Whatever</button>' + END,
    "stuck": "<!doctype html><body>" + NAV + COVER + H1 + '<button onclick="window.__closedBy=\'stuck\'">Not now</button>' + END,
}

fail = 0


def check(label, ok, detail=""):
    global fail
    print("  %s  %s%s" % ("ok  " if ok else "FAIL", label, "" if ok else "  [" + detail[-300:].replace("\n", " | ") + "]"))
    fail += 0 if ok else 1


def run(page, out, key):
    page.set_content(PAGES[key])
    page.wait_for_timeout(150)
    try:
        mod.click_target(page, "a#home", out, key, [], timeout_ms=2500)
        return ""
    except Exception as exc:
        return str(exc)


with sync_playwright() as pw, tempfile.TemporaryDirectory() as out:
    try:
        browser = pw.chromium.launch(headless=True)
    except Exception as exc:
        print("CANNOT RUN: chromium would not launch (%s)" % str(exc)[:160])
        sys.exit(2)
    page = browser.new_page(viewport={"width": 800, "height": 600})

    err = run(page, out, "both")
    check("modal present: the nav click succeeds", err == "", err)
    check("modal present: closed by a real click on its own 'Not now' button",
          page.evaluate("window.__closedBy") == "notnow", str(page.evaluate("window.__closedBy")))
    check("modal present: the dialog is gone and the nav click landed",
          page.locator('[role="dialog"]').count() == 0 and page.evaluate("window.__went === true"))

    err = run(page, out, "x_only")
    check("only the corner X present: the nav click succeeds", err == "", err)
    check("only the corner X present: dismissed through 'Close welcome'", page.evaluate("window.__closedBy") == "x")

    err = run(page, out, "none")
    check("control, no modal: the nav click succeeds", err == "", err)
    check("control, no modal: the click landed", page.evaluate("window.__went === true"))
    if hasattr(mod, "dismiss_welcome_modal"):
        check("control, no modal: reports 'absent'", mod.dismiss_welcome_modal(page) == "absent")

    err = run(page, out, "unknown_button")
    check("modal with no known button fails loud, naming it", "no button named" in err, err)

    err = run(page, out, "stuck")
    check("modal that does not close fails loud ('still open')", "still open" in err, err)
    browser.close()

print("%s" % ("FAIL" if fail else "all hold"))
sys.exit(1 if fail else 0)
