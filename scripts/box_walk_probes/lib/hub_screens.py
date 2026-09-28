#!/usr/bin/env python3
"""Screen checks: open the Hub the way a customer does and judge what it SHOWS.

Why this exists (Andy, walk of v1.0.105, 2026-09-28): every walk probe drove
the box over ssh and asked the ENGINE questions. None opened a page. So an
unstyled wiki (every stylesheet a 401), a Timeline that ended part way through
today, every row labelled MEETING, companies in People and a "Not me" that did
not stick all passed six walks in a row. This script is the missing instrument.

Two halves, kept apart on purpose:

  collect(base, token, out_dir, allow_write) -> facts   (needs a browser)
  judge(facts) -> list of (name, ok, detail)            (pure; mutation-tested)

The judge never sees the browser, so every assertion can be shown to fail on a
mutated fact (--self-test) without a box. The collector saves a PNG of each
page, and the WIKI screenshot is the evidence the tag gate demands.

Usage:
  hub_screens.py collect --base URL --token-file F --out DIR [--allow-write]
                         [--tailscale-running yes|no|unknown]
  hub_screens.py judge FACTS.json
  hub_screens.py --self-test

Exit codes: 0 pass, 1 fail, 78 CANNOT-RUN (no browser / page never loaded).
"""
import json
import os
import re
import sys
import time

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78

BARE_CHANNEL_TITLES = {"whatsapp", "sms", "im", "email", "imessage", "mail", "call"}
ORG_MARKERS = re.compile(
    r"\b(ltd|limited|inc|llc|plc|gmbh|co\.|company|corp|corporation|group|"
    r"promotions?|newsletter|no-?reply|noreply|research|card|bank|support|"
    r"team|store|shop|official|services?|solutions|foundation|association|"
    r"council|institute|university|academy|club|magazine|news)\b",
    re.IGNORECASE,
)
DEFAULT_FONTS = ("times", "serif")  # the browser default when no stylesheet applied


# ---------------------------------------------------------------------------
# judge: pure
# ---------------------------------------------------------------------------

def judge(f):
    out = []

    def add(name, ok, detail=""):
        out.append((name, bool(ok), detail))

    w = f.get("wiki") or {}
    css = w.get("stylesheets") or []
    bad_css = [s for s in css if "text/css" not in (s.get("content_type") or "")
               or int(s.get("status") or 0) >= 400]
    add("wiki: the page loaded inside the app", w.get("loaded"), w.get("error", ""))
    add("wiki: it references stylesheets", len(css) > 0, "0 stylesheets seen")
    add("wiki: every stylesheet arrived as text/css",
        css and not bad_css,
        "; ".join("{} {} {}".format(s.get("status"), s.get("content_type"), s.get("url", "")[-60:])
                  for s in bad_css[:4]))
    bg = (w.get("header_bg") or "").replace(" ", "")
    add("wiki: the theme header is painted",
        w.get("header_found") and bg not in ("", "rgba(0,0,0,0)", "transparent"),
        "header_found={} bg={}".format(w.get("header_found"), w.get("header_bg")))
    font = (w.get("body_font") or "").lower()
    add("wiki: the body font is the theme's, not the browser default",
        font and not any(font.strip().strip('"').startswith(d) for d in DEFAULT_FONTS),
        "font={}".format(w.get("body_font")))
    add("wiki: a screenshot was saved", w.get("screenshot"), "no PNG")

    t = f.get("timeline") or {}
    rows = t.get("rows") or []
    today = t.get("today") or ""
    add("timeline: it has rows", len(rows) > 0, t.get("error", "no rows"))
    add("timeline: it opens with Today in view", t.get("today_in_view"),
        "today anchor top={}".format(t.get("today_top")))
    past = [r for r in rows if r.get("day") and today and r["day"] < today]
    add("timeline: history is reachable by scrolling",
        len(past) > 0, "0 rows before today after scrolling down")
    kinds = {r.get("kind") for r in rows}
    add("timeline: rows are not all one type",
        len(rows) < 10 or len(kinds) > 1, "kinds={}".format(sorted(k for k in kinds if k)))
    bare = [r for r in rows if (r.get("title") or "").strip().lower() in BARE_CHANNEL_TITLES]
    add("timeline: no row is titled with a bare channel name",
        not bare, "{} bare titles".format(len(bare)))

    p = f.get("people") or {}
    names = p.get("names") or []
    orgs = [n for n in names if ORG_MARKERS.search(n or "")]
    add("people: it has rows", len(names) > 0, p.get("error", "no rows"))
    add("people: no organisations or automated senders in the list",
        not orgs, "{} of {}: {}".format(len(orgs), len(names),
                                         ", ".join(sorted(set(orgs))[:3]) if orgs else ""))

    h = f.get("home") or {}
    if h.get("not_me_checked"):
        add("home: a card marked Not me stays gone after a reload",
            h.get("not_me_gone_after_reload"),
            "card {} came back".format(h.get("not_me_card", "")[:40]))

    s = f.get("settings") or {}
    ts_ui, ts_real = s.get("tailscale_toggle"), f.get("tailscale_running")
    if ts_real in ("yes", "no") and ts_ui is not None:
        add("settings: the Tailscale switch matches whether Tailscale is running",
            (ts_ui is True) == (ts_real == "yes"),
            "switch={} running={}".format(ts_ui, ts_real))

    c = f.get("cost") or {}
    add("bursar: the page renders its totals", c.get("loaded"), c.get("error", ""))
    return out


# ---------------------------------------------------------------------------
# collect: needs Playwright
# ---------------------------------------------------------------------------

def collect(base, token, out_dir, allow_write=False, tailscale_running="unknown"):
    from playwright.sync_api import sync_playwright

    os.makedirs(out_dir, exist_ok=True)
    facts = {"tailscale_running": tailscale_running}
    today = time.strftime("%Y-%m-%d")

    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True)
        ctx = browser.new_context(viewport={"width": 1280, "height": 900})
        ctx.add_init_script(
            "try { localStorage.setItem('zeroclaw_token', %s); } catch (e) {}" % json.dumps(token))
        page = ctx.new_page()

        def nav(path):
            # Client-side, as the app does. A direct GET of /wiki reaches the
            # gateway's wiki PROXY (a 401 without a token), not the Hub page.
            if not page.url.startswith(base):
                page.goto(base + "/", wait_until="domcontentloaded", timeout=45000)
                time.sleep(2)
            link = page.locator('a[href="%s"]' % path)
            if link.count() > 0:
                link.first.click()
            else:
                page.evaluate("p => { history.pushState({}, '', p);"
                              " dispatchEvent(new PopStateEvent('popstate')); }", path)
            time.sleep(1)

        # -- wiki (first: the check Andy cannot launch without) -------------
        sheets = []

        def on_resp(r):
            try:
                if r.request.resource_type == "stylesheet":
                    sheets.append({"url": r.url, "status": r.status,
                                   "content_type": r.headers.get("content-type", "")})
            except Exception:
                pass

        page.on("response", on_resp)
        w = {"loaded": False, "stylesheets": sheets}
        try:
            nav("/wiki")
            page.wait_for_selector("iframe", timeout=45000)
            frame = None
            for _ in range(60):
                frame = next((fr for fr in page.frames if "/wiki/" in (fr.url or "")), None)
                if frame and frame.url:
                    break
                time.sleep(0.5)
            if frame is None:
                raise RuntimeError("no wiki frame")
            frame.wait_for_load_state("load", timeout=45000)
            time.sleep(2)
            info = frame.evaluate("""() => {
                const h = document.querySelector('.md-header, header');
                return {
                  header_found: !!h,
                  header_bg: h ? getComputedStyle(h).backgroundColor : '',
                  body_font: getComputedStyle(document.body).fontFamily,
                };
            }""")
            w.update(info)
            w["loaded"] = True
            shot = os.path.join(out_dir, "wiki.png")
            page.screenshot(path=shot, full_page=False)
            w["screenshot"] = shot
        except Exception as exc:
            w["error"] = str(exc)[:200]
        page.remove_listener("response", on_resp)
        facts["wiki"] = w

        # -- timeline ------------------------------------------------------
        t = {"today": today}
        try:
            nav("/timeline")
            page.wait_for_selector("[data-timeline-row]", timeout=45000)
            time.sleep(1.5)
            box = page.evaluate("""() => {
                const el = document.querySelector('[data-timeline-today]');
                if (!el) return null;
                const r = el.getBoundingClientRect();
                return {top: r.top, h: window.innerHeight};
            }""")
            t["today_top"] = box and box["top"]
            t["today_in_view"] = bool(box) and -5 <= box["top"] < box["h"] * 0.6
            page.screenshot(path=os.path.join(out_dir, "timeline.png"))
            for _ in range(8):
                page.evaluate("""() => {
                    const s = document.querySelector('[data-timeline-older]');
                    if (s) s.scrollIntoView({block: 'end'});
                }""")
                time.sleep(1.2)
            t["rows"] = page.evaluate("""() => Array.from(
                document.querySelectorAll('[data-timeline-row]')).map(e => ({
                  kind: e.getAttribute('data-timeline-kind'),
                  day: e.getAttribute('data-timeline-day'),
                  title: e.getAttribute('data-timeline-title')}))""")
        except Exception as exc:
            t["error"] = str(exc)[:200]
        facts["timeline"] = t

        # -- people --------------------------------------------------------
        pp = {}
        try:
            nav("/people")
            page.wait_for_selector("[data-person-row]", timeout=45000)
            pp["names"] = page.evaluate("""() => Array.from(
                document.querySelectorAll('[data-person-row]')).map(
                  e => e.getAttribute('data-person-name') || '')""")
            page.screenshot(path=os.path.join(out_dir, "people.png"))
        except Exception as exc:
            pp["error"] = str(exc)[:200]
        facts["people"] = pp

        # -- settings: Tailscale switch -----------------------------------
        st = {}
        try:
            nav("/preferences")
            page.wait_for_selector("[role=switch]", timeout=30000)
            st["tailscale_toggle"] = page.evaluate("""() => {
                const rows = Array.from(document.querySelectorAll('*')).filter(
                  n => n.children.length === 0 && /Tailscale/i.test(n.textContent || ''));
                for (const r of rows) {
                  let n = r;
                  for (let i = 0; i < 6 && n; i++, n = n.parentElement) {
                    const sw = n.querySelector && n.querySelector('[role=switch]');
                    if (sw) return sw.getAttribute('aria-checked') === 'true';
                  }
                }
                return null;
            }""")
        except Exception as exc:
            st["error"] = str(exc)[:200]
        facts["settings"] = st

        # -- bursar --------------------------------------------------------
        c = {"loaded": False}
        try:
            nav("/cost")
            page.wait_for_selector("text=/model calls/i", timeout=30000)
            c["loaded"] = True
            page.screenshot(path=os.path.join(out_dir, "cost.png"))
        except Exception as exc:
            c["error"] = str(exc)[:200]
        facts["cost"] = c

        # -- home: Not me persists (WRITES: walk boxes only) ---------------
        hm = {"not_me_checked": False}
        if allow_write:
            try:
                page.goto(base + "/", wait_until="domcontentloaded", timeout=45000)
                btn = page.wait_for_selector("button:has-text('Not me')", timeout=30000)
                card = btn.evaluate("b => { let n=b; for (let i=0;i<8&&n;i++,n=n.parentElement)"
                                    " { const h=n.querySelector&&n.querySelector('h3,h2');"
                                    " if (h) return h.textContent; } return ''; }")
                btn.click()
                time.sleep(3)
                page.reload(wait_until="domcontentloaded")
                time.sleep(4)
                hm.update({"not_me_checked": True, "not_me_card": card,
                           "not_me_gone_after_reload":
                               bool(card) and page.locator("text=" + json.dumps(card)).count() == 0})
            except Exception as exc:
                hm["error"] = str(exc)[:200]
        facts["home"] = hm

        browser.close()
    return facts


# ---------------------------------------------------------------------------
# self-test: every assertion must be able to fail
# ---------------------------------------------------------------------------

def _good():
    return {
        "tailscale_running": "yes",
        "wiki": {"loaded": True, "header_found": True, "header_bg": "rgb(122, 31, 31)",
                 "body_font": '"Inter", sans-serif', "screenshot": "/tmp/w.png",
                 "stylesheets": [{"url": "u/assets/main.css", "status": 200,
                                  "content_type": "text/css"}]},
        "timeline": {"today": "2026-09-28", "today_in_view": True, "today_top": 40,
                     "rows": [{"kind": "meeting", "day": "2026-09-28", "title": "Lunch"},
                              {"kind": "message", "day": "2026-09-20",
                               "title": "WhatsApp with A"}] * 6},
        "people": {"names": ["person one", "person two"]},
        "home": {"not_me_checked": True, "not_me_card": "X", "not_me_gone_after_reload": True},
        "settings": {"tailscale_toggle": True},
        "cost": {"loaded": True},
    }


MUTANTS = [
    ("wiki stylesheet served as JSON 401", lambda f: f["wiki"]["stylesheets"].__setitem__(
        0, {"url": "u", "status": 401, "content_type": "application/json"})),
    ("wiki header unpainted", lambda f: f["wiki"].update(header_bg="rgba(0, 0, 0, 0)")),
    ("wiki browser-default font", lambda f: f["wiki"].update(body_font="Times")),
    ("wiki never loaded", lambda f: f["wiki"].update(loaded=False)),
    ("wiki no screenshot", lambda f: f["wiki"].update(screenshot=None)),
    ("timeline opens a year ahead", lambda f: f["timeline"].update(today_in_view=False)),
    ("timeline has no history", lambda f: f["timeline"].update(
        rows=[{"kind": "meeting", "day": "2026-09-29", "title": "x"}] * 3)),
    ("timeline all MEETING", lambda f: f["timeline"].update(
        rows=[{"kind": "meeting", "day": "2026-09-20", "title": "t%d" % i} for i in range(12)])),
    ("timeline bare channel title", lambda f: f["timeline"]["rows"].append(
        {"kind": "message", "day": "2026-09-20", "title": "whatsapp"})),
    ("people contains a company", lambda f: f["people"]["names"].append("acme promotions")),
    ("not me came back", lambda f: f["home"].update(not_me_gone_after_reload=False)),
    ("tailscale switch disagrees", lambda f: f["settings"].update(tailscale_toggle=False)),
    ("bursar did not render", lambda f: f["cost"].update(loaded=False)),
]


def self_test():
    import copy
    base = judge(_good())
    bad = [n for n, ok, _ in base if not ok]
    if bad:
        print("SELF-TEST BROKEN: the good fixture fails: " + "; ".join(bad))
        return EX_FAIL
    missed = []
    for name, mutate in MUTANTS:
        f = copy.deepcopy(_good())
        mutate(f)
        if all(ok for _, ok, _ in judge(f)):
            missed.append(name)
        else:
            print("  ok    mutant caught: " + name)
    if missed:
        print("SELF-TEST FAIL: mutants NOT caught: " + "; ".join(missed))
        return EX_FAIL
    print("SELF-TEST PASS: good fixture passes, {} of {} mutants caught".format(
        len(MUTANTS), len(MUTANTS)))
    return EX_PASS


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] == ["judge"]:
        facts = json.load(open(argv[1]))
    elif argv[:1] == ["collect"]:
        a = {"--allow-write": False, "--tailscale-running": "unknown"}
        i = 1
        while i < len(argv):
            if argv[i] == "--allow-write":
                a["--allow-write"] = True
                i += 1
            else:
                a[argv[i]] = argv[i + 1]
                i += 2
        try:
            token = open(a["--token-file"]).read().strip()
        except Exception as exc:
            print("CANNOT-RUN: token unreadable: {}".format(exc))
            return EX_CANNOT
        try:
            facts = collect(a["--base"], token, a["--out"], a["--allow-write"],
                            a["--tailscale-running"])
        except ImportError as exc:
            print("CANNOT-RUN: no browser on this driver ({}); install Playwright".format(exc))
            return EX_CANNOT
        json.dump(facts, open(os.path.join(a["--out"], "facts.json"), "w"), indent=1)
    else:
        print(__doc__)
        return 2
    results = judge(facts)
    for name, ok, detail in results:
        print(("  ok    " if ok else "  FAIL  ") + name + ("" if ok or not detail else "  -- " + detail))
    fails = [n for n, ok, _ in results if not ok]
    print("EXAMINED: {} screen assertions".format(len(results)))
    return EX_FAIL if fails else EX_PASS


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
