#!/usr/bin/env python3
"""hub_screens judges EVERY People row, not only the rows on screen.

Ostler DMG #21 / ostler-assistant #514: the People page now mounts only its
first window of rows (100 of 6,700 on the walk box). The probe's
"no organisations or automated senders" check read the screen, so after #514
it would judge 100 names and pass an organisation at row 6,500. It now reads
the full list from the same people API the page renders.

Two arms, synthetic data only:

  JUDGE   facts shaped as collect() writes them after #514: 100 names on
          screen, 6,700 from the API, one organisation at row 6,500. The full
          list check must FAIL; the cleaned list must PASS.
  BROWSER (with --browser ENGINE) collect_people() against a local server
          that renders 100 rows and serves /api/v1/people only with the
          right Bearer token, proving the collector reads all 6,700 through
          the real request path. A wrong token must come back NOT MEASURED.

Run against another copy of the lib with HUB_SCREENS_LIB=<path> (the red
control: origin/main before this change has no API read and passes the org).

Exit 0 pass, 1 fail, 2 cannot-run.
"""
import copy
import http.server
import importlib.util
import json
import os
import socketserver
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.environ.get("HUB_SCREENS_LIB") or os.path.join(
    HERE, "..", "scripts", "box_walk_probes", "lib", "hub_screens.py")

N, WINDOW, ORG_AT = 6700, 100, 6500
ORG = "acme promotions"
TOKEN = "synthetic-walk-token"

spec = importlib.util.spec_from_file_location("hub_screens", LIB)
hs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hs)

FULL = "people: no organisations or automated senders in the list"
fails = 0


def check(label, cond, detail=""):
    global fails
    print("  {} {}{}".format("ok  " if cond else "FAIL", label, "" if cond else "  -- " + detail))
    if not cond:
        fails += 1


def synthetic_names(with_org):
    names = ["Synthetic Person %d" % i for i in range(N)]
    if with_org:
        names[ORG_AT] = ORG
    return names


def facts_after_514(api_names):
    f = copy.deepcopy(hs._good())
    f["people"] = {"names": api_names[:WINDOW]}
    if hasattr(hs, "people_api_facts"):
        f["people"]["api"] = {"names": api_names, "total": len(api_names)}
    return f


def verdict(f):
    rows = [(n, ok) for n, ok, _ in hs.judge(f) if n.startswith(FULL)]
    return rows, all(ok for _, ok, _ in hs.judge(f))


print("--- judge: an organisation at row {} of {}, {} rows on screen ---".format(ORG_AT, N, WINDOW))
rows, all_ok = verdict(facts_after_514(synthetic_names(True)))
check("the organisation at row {} fails the full-list check".format(ORG_AT),
      any(ok is False for _, ok in rows), "rows={}".format(rows))
check("the probe as a whole does not pass", not all_ok, "judge passed every assertion")
rows, all_ok = verdict(facts_after_514(synthetic_names(False)))
check("the cleaned list passes the full-list check",
      rows and all(ok is True for _, ok in rows), "rows={}".format(rows))
check("the cleaned list passes the whole judge", all_ok, "some assertion failed on clean facts")


def browser_arm(engine):
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("CANNOT-RUN: no playwright for --browser")
        sys.exit(2)
    names = synthetic_names(True)
    rows_html = "".join('<div data-person-row data-person-name="%s">%s</div>' % (n, n)
                        for n in names[:WINDOW])
    page_html = "<!doctype html><html><body><main>%s</main></body></html>" % rows_html
    api_body = json.dumps({"people": [{"id": str(i), "name": n} for i, n in enumerate(names)],
                           "total": N})
    seen = {"auth": []}

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            if self.path.startswith("/api/v1/people"):
                seen["auth"].append(self.headers.get("Authorization"))
                if self.headers.get("Authorization") != "Bearer " + TOKEN:
                    self.send_response(401)
                    self.end_headers()
                    return
                body, ctype = api_body.encode(), "application/json"
            else:
                body, ctype = page_html.encode(), "text/html"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    httpd = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % httpd.server_address[1]
    out = tempfile.mkdtemp()
    try:
        with sync_playwright() as pw:
            browser = getattr(pw, engine).launch(headless=True)
            page = browser.new_page()
            page.goto(base + "/people")
            pp = hs.collect_people(page, base, TOKEN, out, timeout_ms=15000)
            bad = hs.collect_people(page, base, "wrong-token", out, timeout_ms=15000)
            browser.close()
    finally:
        httpd.shutdown()
    print("--- browser ({}): collect_people against a local Hub stand-in ---".format(engine))
    check("{} names read from the screen".format(WINDOW), len(pp.get("names", [])) == WINDOW,
          "got {}".format(len(pp.get("names", []))))
    api = pp.get("api") or {}
    check("all {} names read from the people API with the Bearer token".format(N),
          len(api.get("names") or []) == N, "api={}".format({k: v for k, v in api.items() if k != "names"}))
    check("the request carried the token", ("Bearer " + TOKEN) in seen["auth"], "auth={}".format(seen["auth"]))
    f = copy.deepcopy(hs._good())
    f["people"] = pp
    check("judged end to end, the organisation at row {} fails".format(ORG_AT),
          any(ok is False for n, ok, _ in hs.judge(f) if n.startswith(FULL)))
    check("a refused token is NOT MEASURED, not an empty clean list",
          "error" in (bad.get("api") or {}) and "401" in bad["api"]["error"], "api={}".format(bad.get("api")))


if "--browser" in sys.argv:
    if not hasattr(hs, "collect_people"):
        check("the lib has a collect_people() that reads the people API", False, LIB)
    else:
        browser_arm(sys.argv[sys.argv.index("--browser") + 1])

print("RESULT: {}".format("PASS" if not fails else "FAIL ({} assertion(s))".format(fails)))
sys.exit(1 if fails else 0)
