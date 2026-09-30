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
# An arm whose precondition did not arise: neither a pass nor a fail nor a
# CANNOT-RUN, and never counted as any of them.
NA = "N/A"


class CannotRun(Exception):
    pass

BARE_CHANNEL_TITLES = {"whatsapp", "sms", "im", "email", "imessage", "mail", "call"}
ORG_MARKERS = re.compile(
    r"\b(ltd|limited|inc|llc|plc|gmbh|co\.|company|corp|corporation|group|"
    r"promotions?|newsletter|no-?reply|noreply|research|card|bank|support|"
    r"team|store|shop|official|services?|solutions|foundation|association|"
    r"council|institute|university|academy|club|magazine|news)\b",
    re.IGNORECASE,
)
ROLE_LOCAL = re.compile(
    r"^(no-?reply|noreply|do-?not-?reply|support|help(desk)?|team|info|news(letter)?|"
    r"promo(tions?)?|marketing|notifications?|alerts?|hello|contact|sales|billing)\b",
    re.IGNORECASE,
)


def _org_like(name):
    """An organisation or automated sender shown as a person. A name that is an
    email address (a provisional name, #2361) is judged by its LOCAL PART only:
    the domain says where a person works (".co.uk", "...group.com"), not what
    they are."""
    n = (name or "").strip()
    if "@" in n:
        return bool(ROLE_LOCAL.search(n.split("@", 1)[0]))
    if re.search(r"^[\w-]+(\.[\w-]+)*\.(com|net|org|io|co|uk|hk|de|fr)$", n, re.IGNORECASE):
        return True
    return bool(ORG_MARKERS.search(n))


DEFAULT_FONTS = ("times", "serif")  # the browser default when no stylesheet applied


# ---------------------------------------------------------------------------
# judge: pure
# ---------------------------------------------------------------------------

def judge(f):
    out = []

    def add(name, ok, detail=""):
        # ok is True (pass), False (fail), None (CANNOT-RUN: not measured)
        # or NA (the arm's precondition did not arise on this box).
        out.append((name, ok if ok is None or ok == NA else bool(ok), detail))

    w = f.get("wiki") or {}
    css = w.get("stylesheets") or []
    bad_css = [s for s in css if "text/css" not in (s.get("content_type") or "")
               or int(s.get("status") or 0) >= 400]
    add("wiki: the page loaded inside the app", w.get("loaded"), w.get("error", ""))
    add("wiki: it references stylesheets", len(css) > 0, "0 stylesheets seen")
    add("wiki: every stylesheet arrived as text/css",
        css and not bad_css,
        "; ".join("{} {} {}".format(s.get("status"), s.get("content_type"), redact_url(s.get("url", ""))[-60:])
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
    js = w.get("scripts") or []
    bad_js = [x for x in js if int(x.get("status") or 0) >= 400
              or "javascript" not in (x.get("content_type") or "")]
    add("wiki: every wiki script arrived as JavaScript", not bad_js,
        "; ".join("{} {} {}".format(x.get("status"), x.get("content_type"), redact_url(x.get("url", ""))[-60:])
                  for x in bad_js[:4]))
    denied = w.get("denied") or []
    add("wiki: no request was refused 401 while the wiki loaded", not denied,
        "{} refused, e.g. {}".format(len(denied), (redact_url(denied[0].get("url", ""))[-60:] if denied else "")))
    add("wiki: loaded through the signed session path (/wiki/s/...)",
        w.get("frame_url_session"), "frame did not use /wiki/s/")
    add("engine: checked in WebKit, the engine Ostler.app uses",
        f.get("engine") == "webkit", "engine={}".format(f.get("engine")))
    pl = f.get("person_link") or {}
    if not pl.get("person_checked"):
        add("chat: a person link opens inside the app, sidebar still there", None,
            "NOT MEASURED: needs --allow-write and HUB_SCREENS_PERSON (the seed person)")
    else:
        add("chat: no reply link points at the raw wiki port (:8044)",
            pl.get("raw_port_links", 0) == 0,
            "{} raw :8044 link(s) in the reply".format(pl.get("raw_port_links")))
        asks = pl.get("asks") or []
        if not asks or not all(a.get("replied") for a in asks):
            add("chat: every one of 3 replies carries an in-app person link", None,
                "NOT MEASURED: {} of {} asks got a reply".format(
                    sum(1 for a in asks if a.get("replied")), len(asks) or 3))
        else:
            add("chat: every one of 3 replies carries an in-app person link",
                all(a.get("anchor") for a in asks),
                "{} of {} replies carried a link".format(
                    sum(1 for a in asks if a.get("anchor")), len(asks)))
        pg = pl.get("page") or {}
        st = pg.get("state")
        seen = "page state={} heading_names_person={} h1_read={!r} expected={!r}".format(
            st, pg.get("heading_names_person"), pg.get("h1_read"), pg.get("expected"))
        if st in ("rendered", "not_built", "raw_404"):
            add("chat: the linked person page is not the raw wiki 404",
                st in ("rendered", "not_built"), seen)
        else:
            add("chat: the linked person page is not the raw wiki 404", None,
                "NOT MEASURED: " + seen)
        if st == "not_built":
            add("chat: a not-yet-built person page says it is still being written",
                True, seen)
        else:
            add("chat: a not-yet-built person page says it is still being written",
                NA, "page is not the not-built page: " + seen)
        if "link_is_this_person" in pl:
            add("chat: the link opened is the asked person's page, not another reply's",
                pl.get("link_is_this_person"), "link_is_this_person={}".format(pl.get("link_is_this_person")))
        if st == "rendered":
            add("chat: a rendered person page names that person in its heading",
                pg.get("heading_names_person"), seen)
        else:
            add("chat: a rendered person page names that person in its heading",
                NA, "page is not rendered: " + seen)
        rp = pl.get("real_person")
        if not rp:
            add("chat: a real person's compiled page renders with their name", None,
                "NOT MEASURED: set HUB_SCREENS_REAL_PERSON to a person with a compiled page")
        elif rp.get("error") or not rp.get("page"):
            add("chat: a real person's compiled page renders with their name", None,
                "NOT MEASURED: anchor={} error={}".format(rp.get("anchor"), rp.get("error")))
        else:
            rpg = rp["page"]
            add("chat: a real person's compiled page renders with their name",
                rp.get("anchor") and rp.get("link_is_this_person", True) is True
                and rpg.get("state") == "rendered" and rpg.get("heading_names_person"),
                "anchor={} page state={} heading_names_person={} (name withheld)".format(
                    rp.get("anchor"), rpg.get("state"), rpg.get("heading_names_person")))
        add("chat: a person link opens inside the app, sidebar still there",
            pl.get("url_in_app") and pl.get("sidebar_present") and pl.get("person_frame_loaded"),
            pl.get("error") or "in_app={} sidebar={} frame={}".format(
                pl.get("url_in_app"), pl.get("sidebar_present"), pl.get("person_frame_loaded")))

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
    orgs = [n for n in names if _org_like(n)]
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


_PEOPLE_SEG = re.compile(r"(/People/)[^/?#\s]+")


def redact_url(url):
    """Never record a person's slug: the walk record is public (CM051)."""
    return _PEOPLE_SEG.sub(r"\1<redacted>", url or "")

def _err(exc, n=200):
    """An exception as it may enter the public record: Playwright quotes the
    frame URL, and a person page URL carries the person's slug."""
    return redact_url(str(exc))[:n]


def person_link_selector(name):
    """The chat link to THIS person's page, never merely the newest wiki link.

    v1.0.106 c6 quiet re-run: two seed asks replied late, their links landed
    during the real-person ask, and the probe clicked the newest link, which
    was the seed's page, and judged it as the real person's."""
    slug = re.sub(r"[^a-z0-9]+", "-", (name or "").casefold()).strip("-")
    return 'main a[href*="/People/{0}"], main a[href*="/people/{0}"]'.format(slug) if slug else None


def _wait_chat_idle(page, max_s=240, stable_s=10):
    """Until the chat transcript stops growing: a reply still streaming, or a
    queued ask, must not be read as the answer to the next one."""
    t0, last, since = time.time(), -1, time.time()
    while time.time() - t0 < max_s:
        n = len(page.inner_text("main"))
        if n != last:
            last, since = n, time.time()
        elif time.time() - since >= stable_s:
            return True
        time.sleep(2)
    return False


def _norm(t):
    return " ".join((t or "").split()).casefold()


def classify_person_page(html, name):
    """Classify the IFRAME document's markup (never the app shell around it):
    raw_404 (the wiki server's bare error page), not_built (the proxy's styled
    'still being written' page), rendered (a page with an h1) or blank (no h1
    and no marker: still loading). Pure, so --self-test runs it on markup.

    v1.0.106 candidate 6 walk: the old reader took the first /wiki/ frame 4s
    after the click and read an h1 that was not there yet, so a page that the
    screenshot shows rendered, heading and all, was recorded as 'unnamed'."""
    from html.parser import HTMLParser

    class P(HTMLParser):
        def __init__(self):
            super().__init__()
            self.depth_h1, self.skip, self.h1, self.text = 0, 0, [], []

        def handle_starttag(self, tag, attrs):
            if tag in ("script", "style"):
                self.skip += 1
            elif tag == "h1":
                self.depth_h1 += 1

        def handle_endtag(self, tag):
            if tag in ("script", "style") and self.skip:
                self.skip -= 1
            elif tag == "h1" and self.depth_h1:
                self.depth_h1 -= 1
                self.h1.append("\n")

        def handle_data(self, data):
            if self.skip:
                return
            self.text.append(data)
            if self.depth_h1:
                self.h1.append(data)

    p = P()
    p.feed(html or "")
    txt = _norm(" ".join(p.text))
    h1 = _norm(" ".join(p.h1))
    raw404 = ("error code: 404" in txt) or ("file not found" in txt)
    not_built = "is still being written" in txt
    named = bool(name) and _norm(name) in h1
    if raw404:
        state = "raw_404"
    elif not_built:
        state = "not_built"
    elif h1:
        state = "rendered"
    else:
        state = "blank"
    return {"state": state, "heading_names_person": named, "h1": h1}


def _person_page_facts(page, name, public_name=True, wait_s=30):
    """What the person page actually shows: never trust 'the sidebar stayed'.
    Reads the document INSIDE the app's wiki iframe, polling until it is past
    loading. The h1 text and the expected name are kept only for the seed
    person (public_name); a real person's are withheld from every record."""
    t0, facts = time.time(), {"state": "no_frame"}
    while True:
        try:
            el = page.query_selector('iframe[src*="/wiki/"]') or page.query_selector("iframe")
            frame = el.content_frame() if el else None
            if frame is not None:
                try:
                    frame.wait_for_load_state("load", timeout=10000)
                except Exception:
                    pass
                facts = classify_person_page(frame.content(), name)
        except Exception as exc:
            facts = {"state": "unreadable", "error": _err(exc, 120)}
        if facts["state"] in ("rendered", "not_built", "raw_404") or time.time() - t0 > wait_s:
            break
        time.sleep(2)
    h1 = facts.pop("h1", None)
    if public_name:
        facts["h1_read"], facts["expected"] = h1, name
    else:
        facts["h1_read"] = facts["expected"] = "<withheld>"
    return facts

def collect(base, token, out_dir, allow_write=False, tailscale_running="unknown"):
    from playwright.sync_api import sync_playwright

    os.makedirs(out_dir, exist_ok=True)
    facts = {"tailscale_running": tailscale_running}
    today = time.strftime("%Y-%m-%d")

    with sync_playwright() as pw:
        engine = os.environ.get("HUB_SCREENS_ENGINE", "webkit")
        facts["engine"] = engine
        try:
            browser = getattr(pw, engine).launch(headless=True)
        except Exception as exc:
            raise CannotRun("the {} engine would not launch ({}); run "
                            "`python -m playwright install {}` on the driver. "
                            "No fallback to another engine.".format(engine, str(exc)[:120], engine))
        ctx = browser.new_context(viewport={"width": 1280, "height": 900})
        ctx.add_init_script(
            "try { localStorage.setItem('zeroclaw_token', %s); } catch (e) {}" % json.dumps(token))
        page = ctx.new_page()
        if os.environ.get("HUB_SCREENS_RED_CONTROL") == "strip-wiki-session":
            # RED CONTROL: reproduce v1.0.105. There the wiki's stylesheets and
            # scripts were fetched from /wiki/... with no credential. Rewrite every
            # non-document request under /wiki/s/<session>/ back to /wiki/, so the
            # check must go RED if it can see that failure at all.
            import re as _re

            def _strip(route, request):
                if request.resource_type != "document":
                    return route.continue_(url=_re.sub(r"/wiki/s/[^/]+/", "/wiki/", request.url))
                return route.continue_()
            page.route("**/wiki/s/**", _strip)
            facts["red_control"] = "strip-wiki-session"

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
        sheets, scripts, denied = [], [], []

        def on_resp(r):
            try:
                rt = r.request.resource_type
                row = {"url": redact_url(r.url), "status": r.status,
                       "content_type": r.headers.get("content-type", "")}
                if rt == "stylesheet":
                    sheets.append(row)
                elif rt == "script" and "/wiki/" in r.url:
                    scripts.append(row)
                if r.status == 401:
                    denied.append(row)
            except Exception:
                pass

        page.on("response", on_resp)
        w = {"loaded": False, "stylesheets": sheets, "scripts": scripts, "denied": denied}
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
            w["frame_url_session"] = "/wiki/s/" in (frame.url or "")
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
            w["error"] = _err(exc)
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
            t["error"] = _err(exc)
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
            pp["error"] = _err(exc)
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
            st["error"] = _err(exc)
        facts["settings"] = st

        # -- bursar --------------------------------------------------------
        c = {"loaded": False}
        try:
            nav("/cost")
            page.wait_for_selector("text=/model calls/i", timeout=30000)
            c["loaded"] = True
            page.screenshot(path=os.path.join(out_dir, "cost.png"))
        except Exception as exc:
            c["error"] = _err(exc)
        facts["cost"] = c

        # -- a chat citation to a person page stays inside the app ----------
        pl = {"person_checked": False}
        who = os.environ.get("HUB_SCREENS_PERSON") or os.environ.get("OSTLER_GATE_KNOWN_PERSON")
        if allow_write and who:
            pl["person_checked"] = True
            try:
                nav("/chat")
                # Ask THREE times. Whether a reply links the person depended on
                # the model's formatting (a path in backticks carried no anchor
                # on v1.0.106 candidate 5), so one lucky reply proves nothing.
                sel = 'main a[href*="/wiki/"], main a[href*=":8044"]'
                own = person_link_selector(who)
                asks = []
                for _ in range(3):
                    _wait_chat_idle(page)
                    before = page.locator(sel).count()
                    before_text = len(page.inner_text("main"))
                    box = page.wait_for_selector("textarea", timeout=30000)
                    box.fill("Who is {}? Include a link to their wiki page.".format(who))
                    box.press("Enter")
                    got, replied, t0 = False, False, time.time()
                    while time.time() - t0 < 240:
                        if page.locator(sel).count() > before:
                            got = replied = True
                            break
                        if len(page.inner_text("main")) > before_text + len(who) + 80:
                            replied = True
                        time.sleep(3)
                    if replied and not got:
                        time.sleep(5)
                        got = page.locator(sel).count() > before
                    asks.append({"replied": replied, "anchor": got})
                pl["asks"] = asks
                _wait_chat_idle(page)
                pl["link_is_this_person"] = page.locator(own).count() > 0
                link = page.locator(own if pl["link_is_this_person"] else sel).last
                pl["raw_port_links"] = page.locator('main a[href*=":8044"]').count()
                link.click()
                time.sleep(4)
                pl["url_in_app"] = page.url.startswith(base)
                pl["sidebar_present"] = page.locator('a[href="/timeline"]').count() > 0
                fr = next((f2 for f2 in page.frames if "/wiki/" in (f2.url or "")), None)
                pl["person_frame_loaded"] = fr is not None
                pl["page"] = _person_page_facts(page, who, public_name=True)
                page.screenshot(path=os.path.join(out_dir, "person.png"))
                pl["screenshot"] = os.path.join(out_dir, "person.png")
                # A real person WITH a compiled page must render their own
                # heading (name withheld from every public record: only the
                # facts below are kept, never the name).
            except Exception as exc:
                pl["error"] = _err(exc)
            real = os.environ.get("HUB_SCREENS_REAL_PERSON")
            if real:
                # The seed ask above leaves the page ON the person page, where
                # there is no chat box: go back to chat first (candidate 6 timed
                # out here, and the arm silently read as NOT MEASURED).
                rp = {"checked": True}
                mine = person_link_selector(real)
                try:
                    nav("/chat")
                    _wait_chat_idle(page)
                    before = page.locator(mine).count()
                    box = page.wait_for_selector("textarea", timeout=30000)
                    box.fill("Who is {}? Include a link to their wiki page.".format(real))
                    box.press("Enter")
                    t0 = time.time()
                    while time.time() - t0 < 240 and page.locator(mine).count() <= before:
                        time.sleep(3)
                    # Only a link to THIS person's page counts, never the
                    # newest link in the chat.
                    rp["anchor"] = page.locator(mine).count() > before
                    rp["link_is_this_person"] = rp["anchor"]
                    if rp["anchor"]:
                        page.locator(mine).last.click()
                        time.sleep(4)
                        rp["page"] = _person_page_facts(page, real, public_name=False)
                        page.screenshot(path=os.path.join(out_dir, "person-real.png"))
                except Exception as exc:
                    rp["error"] = _err(exc).replace(real, "<withheld>")
                pl["real_person"] = rp
        facts["person_link"] = pl

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
                hm["error"] = _err(exc)
        facts["home"] = hm

        browser.close()
    return facts


# ---------------------------------------------------------------------------
# self-test: every assertion must be able to fail
# ---------------------------------------------------------------------------

def _good():
    return {
        "tailscale_running": "yes", "engine": "webkit",
        "person_link": {"person_checked": True, "url_in_app": True, "sidebar_present": True,
                        "person_frame_loaded": True, "raw_port_links": 0,
                        "link_is_this_person": True,
                        "asks": [{"replied": True, "anchor": True}] * 3,
                        "page": {"state": "not_built", "heading_names_person": False},
                        "real_person": {"checked": True, "anchor": True, "link_is_this_person": True,
                                        "page": {"state": "rendered", "heading_names_person": True}}},
        "wiki": {"loaded": True, "header_found": True, "header_bg": "rgb(122, 31, 31)",
                 "body_font": '"Inter", sans-serif', "screenshot": "/tmp/w.png",
                 "frame_url_session": True, "denied": [],
                 "scripts": [{"url": "u/wiki/s/x/assets/b.js", "status": 200,
                              "content_type": "application/javascript"}],
                 "stylesheets": [{"url": "u/assets/main.css", "status": 200,
                                  "content_type": "text/css"}]},
        "timeline": {"today": "2026-09-28", "today_in_view": True, "today_top": 40,
                     "rows": [{"kind": "meeting", "day": "2026-09-28", "title": "Lunch"},
                              {"kind": "message", "day": "2026-09-20",
                               "title": "WhatsApp with A"}] * 6},
        "people": {"names": ["person one", "person two", "someone" + "@" + "examplemail.co.uk", "a.person" + "@" + "bigco-group.com"]},
        "home": {"not_me_checked": True, "not_me_card": "X", "not_me_gone_after_reload": True},
        "settings": {"tailscale_toggle": True},
        "cost": {"loaded": True},
    }


MUTANTS = [
    ("wiki stylesheet served as JSON 401", lambda f: f["wiki"]["stylesheets"].__setitem__(
        0, {"url": "u", "status": 401, "content_type": "application/json"})),
    ("wiki script refused", lambda f: f["wiki"]["scripts"].__setitem__(
        0, {"url": "u", "status": 401, "content_type": "application/json"})),
    ("wiki 401 in the network log", lambda f: f["wiki"]["denied"].append({"url": "u", "status": 401})),
    ("wiki not on the session path (v1.0.105 behaviour)",
     lambda f: f["wiki"].update(frame_url_session=False)),
    ("checked in chromium, not webkit", lambda f: f.update(engine="chromium")),
    ("person link left the app", lambda f: f["person_link"].update(sidebar_present=False)),
    ("chat reply links the raw wiki port", lambda f: f["person_link"].update(raw_port_links=1)),
    ("person link opens the raw wiki 404 page (sidebar intact)",
     lambda f: f["person_link"].update(page={"state": "raw_404", "heading_names_person": False})),
    ("the seed link clicked was another reply's link",
     lambda f: f["person_link"].update(link_is_this_person=False)),
    ("the real-person link clicked was another reply's link",
     lambda f: f["person_link"]["real_person"].update(link_is_this_person=False)),
    ("a rendered person page names someone else",
     lambda f: f["person_link"].update(page={"state": "rendered", "heading_names_person": False})),
    ("a real person's page renders but names someone else",
     lambda f: f["person_link"].update(real_person={"checked": True, "anchor": True,
                                                    "page": {"state": "rendered",
                                                             "heading_names_person": False}})),
    ("a real person's compiled page does not render",
     lambda f: f["person_link"].update(real_person={"checked": True, "anchor": True,
                                                    "page": {"state": "raw_404"}})),
    ("one of 3 replies carried no person link (path in backticks)",
     lambda f: f["person_link"].update(asks=[{"replied": True, "anchor": True},
                                             {"replied": True, "anchor": False},
                                             {"replied": True, "anchor": True}])),
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
    ("people contains a role address", lambda f: f["people"]["names"].append("support@example.com")),
    ("people contains a domain as a name", lambda f: f["people"]["names"].append("Examplefare.co.uk")),
    ("not me came back", lambda f: f["home"].update(not_me_gone_after_reload=False)),
    ("tailscale switch disagrees", lambda f: f["settings"].update(tailscale_toggle=False)),
    ("bursar did not render", lambda f: f["cost"].update(loaded=False)),
]


def self_test():
    import copy
    f0 = copy.deepcopy(_good())
    f0["person_link"] = {"person_checked": False}
    row = [ok for n, ok, _ in judge(f0) if n.startswith("chat: a person link")]
    if row != [None]:
        print("SELF-TEST FAIL: an unmeasured person link must be an explicit CANNOT-RUN row, got {}".format(row))
        return EX_FAIL
    print("  ok    unmeasured person link is an explicit CANNOT-RUN row")
    # PRIVACY ARM: no person slug may reach the public walk record, through
    # the network recorder or a failure detail.
    slug = "zz-real-person-slug"
    leak = copy.deepcopy(_good())
    leak["wiki"]["stylesheets"] = [{"url": "http://h/wiki/s/k/People/%s/x.css" % slug,
                                    "status": 404, "content_type": "text/html"}]
    leak["wiki"]["denied"] = [{"url": "http://h/wiki/People/%s/" % slug, "status": 401}]
    printed = " ".join(d for _, _, d in judge(leak))
    if slug in printed or slug in redact_url("http://h/wiki/People/%s/?a=1" % slug):
        print("SELF-TEST FAIL: a person slug reached the record: redact_url is not applied")
        return EX_FAIL
    print("  ok    no person slug reaches the record (network rows and failure details)")
    # EXCEPTION ARM: a Playwright error quotes the frame URL, slug and all.
    exc = RuntimeError('Timeout 30000ms exceeded.\nnavigated to "http://127.0.0.1:30330/wiki/s/k/People/%s/"' % slug)
    err = copy.deepcopy(_good())
    err["person_link"]["error"] = _err(exc)
    err["person_link"]["sidebar_present"] = False
    err["person_link"]["real_person"] = {"checked": True, "anchor": True, "error": _err(exc)}
    printed = " ".join(d for _, _, d in judge(err)) + json.dumps(err)
    if slug in printed or slug in _err(exc):
        print("SELF-TEST FAIL: a person slug in an exception reached the record: _err is not applied")
        return EX_FAIL
    print("  ok    no person slug reaches the record through an exception message")
    # MARKUP ARMS: the classifier runs on the iframe document's markup, and
    # each of the three pages it must tell apart is a fixture here.
    rendered = ('<html><head><style>h1{x:1}</style></head><body><nav>People'
                ' &gt; Jane Doe</nav><article class="md-content__inner"><h1 id="jane-doe">'
                '\n  Jane   Doe\n</h1><p>Works at Acme Corp.</p></article></body></html>')
    # The gateway's not-built page, as wiki_proxy.rs person_page_not_built emits it.
    not_built = ('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Jane Doe'
                 '</title><style>h1{font-size:22px}</style></head><body><main><h1>Jane Doe</h1>'
                 '<p>Jane Doe&#39;s page is still being written. It appears after the next'
                 ' wiki update.</p></main></body></html>')
    raw_404 = ('<html><head><title>Error response</title></head><body><h1>Error response'
               '</h1><p>Error code: 404</p><p>Message: File not found.</p></body></html>')
    blank = '<html><body><div id="app"></div></body></html>'
    arms = [("rendered", rendered, "rendered", True), ("not_built", not_built, "not_built", True),
            ("raw_404", raw_404, "raw_404", False), ("blank (loading)", blank, "blank", False)]
    for label, html, want, named in arms:
        got = classify_person_page(html, "Jane Doe")
        if got["state"] != want or got["heading_names_person"] != named:
            print("SELF-TEST FAIL: {} markup classified {} (heading_names_person={}), want {} ({})".format(
                label, got["state"], got["heading_names_person"], want, named))
            return EX_FAIL
        print("  ok    {} markup classified {}".format(label, want))
    if classify_person_page(rendered, "John Smith")["heading_names_person"]:
        print("SELF-TEST FAIL: a rendered page for another person was read as naming the asked person")
        return EX_FAIL
    print("  ok    a rendered page for another person does not name the asked person")
    # OWN-LINK ARM: the selector for a person matches that person's page and
    # no other person's.
    own = person_link_selector("Jane Doe")
    if not own or "/People/jane-doe" not in own or "john-smith" in own \
            or person_link_selector("John Smith") == own:
        print("SELF-TEST FAIL: person_link_selector does not single out the asked person: {!r}".format(own))
        return EX_FAIL
    print("  ok    the link selector singles out the asked person's page")
    # N/A ARM: 'still being written' is judged only on the not-built page.
    na = copy.deepcopy(_good())
    na["person_link"]["page"] = {"state": "rendered", "heading_names_person": True}
    row = [ok for n, ok, _ in judge(na) if n.startswith("chat: a not-yet-built")]
    if row != [NA]:
        print("SELF-TEST FAIL: the still-being-written arm on a rendered page must be N/A, got {}".format(row))
        return EX_FAIL
    print("  ok    still-being-written arm is N/A on a rendered page")
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
        except CannotRun as exc:
            print("CANNOT-RUN: {}".format(exc))
            return EX_CANNOT
        json.dump(json.loads(redact_url(json.dumps(facts))), open(os.path.join(a["--out"], "facts.json"), "w"), indent=1)
    else:
        print(__doc__)
        return 2
    results = judge(facts)
    for name, ok, detail in results:
        tag = "  N/A   " if ok == NA else ("  ok    " if ok else ("  CANNOT " if ok is None else "  FAIL  "))
        print(tag + name + ("" if ok or not detail else "  -- " + detail))
    fails = [n for n, ok, _ in results if ok is False]
    cannot = [n for n, ok, _ in results if ok is None]
    na = [n for n, ok, _ in results if ok == NA]
    print("EXAMINED: {} screen assertions ({} not measured, {} not applicable)".format(
        len(results), len(cannot), len(na)))
    if fails:
        return EX_FAIL
    return EX_CANNOT if cannot else EX_PASS


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
