#!/usr/bin/env python3
"""The em dash check exempts marked customer data and nothing else (cut #13).

Walk #12 failed hub_screens_customer_read on the wiki's Trends page: the "New
discoveries" row printed a customer's bookmarked page title as plain text
(CM044 trends_pages.py:325, `article .pw-dated-list li`), so a dash inside the
customer's own title was counted as Ostler copy. CM044 now wraps every
customer value in data-ostler-customer (compiler/customer_text.py), and
customer_read.py's CUSTOMER_TITLES_JS collects the text of each marked
element so the judge removes it once before counting.

The self-test in customer_read.py is pure Python over collected facts, so it
cannot see the JavaScript. This test runs the REAL CUSTOMER_TITLES_JS in a
real Chromium against synthetic pages, feeds what it collects to the REAL
judge, and checks the em dash verdict, so each case exercises collector and
judge together. Synthetic data only.

Exit 0 all pass, 1 any fail, 2 CANNOT-RUN (no playwright or no browser).
"""
import copy
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib"))
import customer_read as cr  # noqa: E402

D = "\u2014"
TITLE = "Harbour trains " + D + " a short history"
M = '<span data-ostler-customer="1">%s</span>'
ROW = '<li><strong>12 Mar</strong> · ' + (M % TITLE) + ' · Books</li>'


def page(body):
    return '<article><h1>Trends</h1><div class="pw-dated-list"><ul>%s</ul></div></article>' % body


# (label, html, expected verdict of the em dash assertion)
CASES = [
    ("walk #12: a marked bookmark title in the New discoveries row PASSES",
     page(ROW), True),
    ("an em dash in a heading next to the marked title still FAILS",
     page(ROW).replace("<h1>Trends</h1>", "<h1>Trends</h1><h2>New discoveries " + D + " recent</h2>"), False),
    ("template copy beside the marker in the SAME row still FAILS",
     page('<li>Seen ' + D + ' ' + (M % TITLE) + '</li>'), False),
    ("a marker ON a heading does not exempt the heading",
     page(ROW).replace("<h1>Trends</h1>", '<h2 data-ostler-customer="1">Pages ' + D + ' this week</h2>'), False),
    ("a marker that holds a heading exempts nothing inside it",
     page('<li><div data-ostler-customer="1"><h3>Pages ' + D + ' this week</h3>' + TITLE + '</div></li>'), False),
    ("one marked title exempts one copy; a second unmarked copy FAILS",
     page(ROW + '<li>' + TITLE + '</li>'), False),
    ("a marked off-site link is exempted once, not by both rules",
     page('<li>' + (M % ('<a href="https://example.invalid/a">' + TITLE + '</a>')) + '</li><li>' + TITLE + '</li>'), False),
    ("a nested marker exempts its text once; a second unmarked copy FAILS",
     page('<li>' + (M % (M % TITLE)) + '</li><li>' + TITLE + '</li>'), False),
    ("#2710 kept: an unmarked off-site link title still PASSES",
     page('<li><a href="https://example.invalid/a">' + TITLE + '</a></li>'), True),
    ("an unmarked plain-text title FAILS (the walk #12 shape before CM044 marks it)",
     page('<li><strong>12 Mar</strong> · ' + TITLE + ' · Books</li>'), False),
]


def verdict(pw_page, html):
    pw_page.set_content(html)
    text = pw_page.evaluate("() => document.querySelector('article').innerText")
    titles = pw_page.evaluate(cr.CUSTOMER_TITLES_JS) or []
    facts = copy.deepcopy(cr._good())
    facts["wiki"]["nav_links"].append("Trends/")
    facts["wiki"]["crawl"]["Trends/"] = {"text": text, "mono_dates": 0, "customer_titles": titles}
    got = [ok for name, ok, _ in cr.judge(facts) if name == cr.DECLARED[1]]
    return got[0] if len(got) == 1 else ("rows", got)


# Hub screens (walk #15): the Hub People row marks a contact-written subtitle.
HUB_ROW = '<div><span>Sam Doe</span><div data-person-subtitle %s>%s</div></div>'
HUB_TITLE = "Co" + D + "founder"
HUB_CASES = [
    ("walk #15: a marked contact title on Hub People PASSES",
     '<main>%s</main>' % (HUB_ROW % ('data-ostler-customer="1"', HUB_TITLE)), True),
    ("the same title UNMARKED on Hub People still FAILS",
     '<main>%s</main>' % (HUB_ROW % ('', HUB_TITLE)), False),
    ("Hub copy beside a marked title still FAILS",
     '<main><h2>People ' + D + ' all</h2>%s</main>' % (HUB_ROW % ('data-ostler-customer="1"', HUB_TITLE)), False),
]


def hub_verdict(pw_page, html):
    pw_page.set_content(html)
    text = pw_page.evaluate("() => document.querySelector('main').innerText")
    titles = pw_page.evaluate(cr.CUSTOMER_TITLES_JS) or []
    facts = copy.deepcopy(cr._good())
    facts["screens"]["people"] = dict(facts["screens"].get("people") or {}, text=text, customer_titles=titles)
    got = [ok for name, ok, _ in cr.judge(facts) if name == cr.DECLARED[1]]
    return got[0] if len(got) == 1 else ("rows", got)


def main():
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as exc:
        print("CANNOT-RUN: playwright is not importable ({})".format(exc))
        return 2
    # Control: the good fixture alone must pass, or every FAIL below is noise.
    good = [ok for name, ok, _ in cr.judge(cr._good()) if name == cr.DECLARED[1]]
    if good != [True]:
        print("CANNOT-RUN: the good fixture does not pass the em dash assertion ({!r})".format(good))
        return 2
    fails = []
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch()
            pw_page = browser.new_page()
            for label, html, want, *hub in CASES + [(l, h, w, True) for l, h, w in HUB_CASES]:
                got = hub_verdict(pw_page, html) if hub else verdict(pw_page, html)
                if got is want:
                    print("  ok    " + label)
                else:
                    fails.append(label)
                    print("  FAIL  {} (verdict {!r}, wanted {!r})".format(label, got, want))
            browser.close()
    except Exception as exc:  # no browser binary is a harness fault, not a verdict
        print("CANNOT-RUN: the browser could not run ({})".format(str(exc)[:200]))
        return 2
    print("{} of {} cases as expected".format(len(CASES) + len(HUB_CASES) - len(fails), len(CASES) + len(HUB_CASES)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
