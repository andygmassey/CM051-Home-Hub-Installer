#!/usr/bin/env python3
"""MONO_DATES_JS counts a monospace date whatever its class and whatever it holds.

The v1.0.116 era predicate counted only elements with NO child elements. The
wiki's .pw-date, .pw-deadline and .pw-mast-date each hold an icon <span>, so
every one of them was skipped: the probe scored 0 on a CM044 render that still
had monospace date leaves. The predicate now reads an element's OWN text nodes.

This runs the REAL MONO_DATES_JS in real Chromium against synthetic pages.
Each RED case is a date in a monospace face and must score at least the
stated count; each GREEN case must score 0 (a display-face date, a mono COUNT,
a path inside <code>, an ancestor whose date is only in a child).
Synthetic data only.

Exit 0 all pass, 1 any fail, 2 CANNOT-RUN (no playwright or no browser).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "lib"))
import customer_read as cr  # noqa: E402

STYLE = ("<style>.m{font-family:'Courier New',monospace} .d{font-family:Georgia,serif}"
         " .ic{display:inline-block;width:1em;height:1em}</style>")
ICON = '<span class="ic" aria-hidden="true"></span>'


def page(body):
    return STYLE + "<article>" + body + "</article>"


# (label, html, expected score)
CASES = [
    ("RED  .pw-date holding an icon span (the 0-on-99 shape)",
     page('<span class="pw-date m">' + ICON + '15 August 2026</span>'), 1),
    ("RED  .pw-deadline holding an icon span",
     page('<span class="pw-deadline m">' + ICON + 'Sun 25 Oct 2026</span>'), 1),
    ("RED  .pw-mast-date holding an icon span",
     page('<span class="pw-mast-date m">' + ICON + 'as of 22 October 2026</span>'), 1),
    ("RED  a linked date inside a mono <strong> (person-page timeline)",
     page('<ul><li><strong class="m"><a href="#x">24 July 2026</a></strong> Sync</li></ul>'), 1),
    ("RED  a bare leaf in an unknown class",
     page('<table><tr><td class="whatever-new m">2026-03-04</td></tr></table>'), 1),
    ("RED  three dates are three",
     page('<p class="m">1 Mar 2026</p><p class="m">2 Mar 2026</p><p class="m">March 2026</p>'), 3),
    ("GREEN a date in the display face",
     page('<span class="pw-date d">' + ICON + '15 August 2026</span>'), 0),
    ("GREEN a mono COUNT is not a date",
     page('<table><tr><td class="num m">120</td><td class="num m">70%</td></tr></table>'), 0),
    ("GREEN a dated path inside <code>",
     page('<p>See <code class="m">2026-10-02/ai-01.md</code></p>'), 0),
    ("GREEN an ancestor is not counted for a date only its child holds",
     page('<div class="m"><span class="d">12 Mar 2026</span></div>'), 0),
]


def main():
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as exc:
        print("CANNOT-RUN: playwright is not importable ({})".format(exc))
        return 2
    fails = []
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch()
            pg = browser.new_page()
            for label, html, want in CASES:
                pg.set_content(html)
                got = pg.evaluate(cr.MONO_DATES_JS)
                if got == want:
                    print("  ok    {} (score {})".format(label, got))
                else:
                    fails.append(label)
                    print("  FAIL  {} (score {}, wanted {})".format(label, got, want))
            browser.close()
    except Exception as exc:  # no browser binary is a harness fault, not a verdict
        print("CANNOT-RUN: the browser could not run ({})".format(str(exc)[:200]))
        return 2
    print("{} of {} cases as expected".format(len(CASES) - len(fails), len(CASES)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
