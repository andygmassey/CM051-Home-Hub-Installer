"""Render a Front Page card feed (frontpage.build_frontpage output) into a
self-contained HTML Front Page.

This is BOTH a human-viewable surface (the Hub Doctor ``/frontpage`` route
embeds it today) AND the render contract the macOS Hub app / iOS app follow when
they render the same JSON. It is deliberately a single string of static HTML +
inline CSS - no JS, no external assets - so any surface can drop it in.

The card controls (Dismiss forever / Remind me later / Proceed) are drawn as
affordances. Wiring the taps to the CorrectionStore / card-state store is the
surface's job; the contract is the markup + the card schema.

Usage: python3 -m compiler.render_frontpage front_page.json out.html
"""

from __future__ import annotations

import html
import json
import sys

_CSS = """
:root{--bg:#0f1115;--card:#171a21;--ink:#e8eaf0;--mut:#9aa3b2;--ac:#6ea8fe;
--good:#5dd39e;--warn:#e0a458;--edge:#232733}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:760px;margin:0 auto;padding:30px 20px 80px}
h1{font-size:25px;margin:0 0 3px}
.sub{color:var(--mut);margin:0 0 24px;font-size:13.5px}
.card{background:var(--card);border:1px solid var(--edge);border-radius:13px;
padding:15px 16px;margin:0 0 12px}
.card.settling{border-color:#2f3a4a;background:linear-gradient(180deg,#172131,#161a21)}
.card.onboarding{border-color:#34405a}
.kind{display:inline-block;font-size:10.5px;letter-spacing:.06em;text-transform:uppercase;
color:var(--mut);margin:0 0 6px}
.kind.settling{color:var(--ac)}.kind.onboarding{color:var(--good)}
.dom{color:var(--mut);font-weight:400;font-size:11px;text-transform:none;letter-spacing:0}
.title{font-weight:650;font-size:16px;margin:0 0 4px}
.settling .title{display:flex;align-items:center;gap:8px}
.dot{width:8px;height:8px;border-radius:50%;background:var(--ac);
box-shadow:0 0 0 0 rgba(110,168,254,.6);animation:p 2s infinite}
@keyframes p{0%{box-shadow:0 0 0 0 rgba(110,168,254,.5)}70%{box-shadow:0 0 0 7px rgba(110,168,254,0)}100%{box-shadow:0 0 0 0 rgba(110,168,254,0)}}
.body{color:var(--ink);font-size:14px;margin:0 0 8px}
.ev{color:var(--mut);font-size:12.5px;margin:0 0 9px}
.bar{height:5px;background:var(--edge);border-radius:3px;overflow:hidden;margin:9px 0 11px}
.fill{height:100%;background:linear-gradient(90deg,var(--ac),var(--good))}
.ctrls{display:flex;gap:7px;flex-wrap:wrap}
.btn{font-size:12px;border:1px solid #2b3140;background:#1c212b;color:var(--mut);
border-radius:7px;padding:5px 11px;cursor:default}
.btn.go{color:var(--ink);border-color:#39526f;background:#1d2735}
.btn.up{color:var(--good)}.btn.snooze{color:var(--warn)}.btn.drop{color:#e06a6a}
.empty{color:var(--mut);font-style:italic;padding:20px 0}
.foot{color:var(--mut);font-size:12px;margin-top:28px;border-top:1px solid var(--edge);
padding-top:14px}
"""


def _settling_pct(card: dict):
    ev = card.get("evidence") or ""
    # evidence carries "<n>% of the first read-in done" when we have a percent
    for tok in ev.split():
        if tok.endswith("%"):
            try:
                return max(2, min(100, int(tok[:-1])))
            except ValueError:
                return None
    return None


def _card_html(card: dict) -> str:
    kind = card.get("kind", "system")
    settling = kind == "system" and "settling" in card.get("id", "")
    cls = "card"
    kindlabel = kind
    if settling:
        cls += " settling"
        kindlabel = "settling"
    elif kind == "onboarding":
        cls += " onboarding"

    dom = card.get("domain")
    domhtml = f' <span class="dom">{html.escape(dom)}</span>' if dom else ""
    title = html.escape(card.get("title", ""))
    if settling:
        title = f'<span class="dot" aria-hidden="true"></span>{title}'
    body = html.escape(card.get("body", ""))
    ev = card.get("evidence")
    evhtml = f'<div class="ev">{html.escape(ev)}</div>' if ev else ""

    bar = ""
    if settling:
        pct = _settling_pct(card)
        if pct is not None:
            bar = (f'<div class="bar"><div class="fill" style="width:{pct}%">'
                   f'</div></div>')

    # controls: every card gets dismiss + snooze; action cards get a Proceed
    action = card.get("action") or {}
    label = html.escape(action.get("label", "")) if action else ""
    ctrls = []
    if action:
        akind = action.get("kind", "")
        if akind == "strengthen":
            ctrls.append(f'<span class="btn up">&#9650; {label or "Spot on"}</span>')
            ctrls.append('<span class="btn drop">&#10005; Not me</span>')
        else:
            ctrls.append(f'<span class="btn go">{label or "Proceed"}</span>')
    ctrls.append('<span class="btn snooze">Remind me later</span>')
    ctrls.append('<span class="btn drop">Dismiss</span>')
    ctrlhtml = '<div class="ctrls">' + "".join(ctrls) + "</div>"

    return (f'<div class="{cls}">'
            f'<div class="kind {kindlabel}">{html.escape(kindlabel)}{domhtml}</div>'
            f'<div class="title">{title}</div>'
            f'<div class="body">{body}</div>'
            f'{bar}{evhtml}{ctrlhtml}</div>')


def render(feed: dict) -> str:
    cards = feed.get("cards", [])
    phase = feed.get("phase", "")
    body = "".join(_card_html(c) for c in cards)
    if not body:
        body = ('<p class="empty">Nothing on your Front Page yet - Ostler is '
                'still settling in.</p>')
    n = feed.get("card_count", len(cards))
    sub = (f"{n} card{'s' if n != 1 else ''} &middot; phase: "
           f"{html.escape(phase)} &middot; cards rank by relevance and fade "
           "with age")
    return (f'<!doctype html><html><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>Your Front Page</title><style>{_CSS}</style></head><body>'
            f'<div class="wrap"><h1>Your Front Page</h1>'
            f'<p class="sub">{sub}</p>{body}'
            f'<p class="foot">The Editor &middot; compiled '
            f'{html.escape(str(feed.get("generated_utc", "")))} &middot; '
            "this preview renders the same JSON the Hub and iOS apps consume."
            "</p></div></body></html>")


def render_fragment(feed: dict) -> str:
    """Just the cards + the inline CSS, for embedding inside another page (the
    Doctor dashboard) rather than a full HTML document."""
    cards = feed.get("cards", [])
    body = "".join(_card_html(c) for c in cards)
    if not body:
        body = ('<p class="empty">Nothing on your Front Page yet - Ostler is '
                'still settling in.</p>')
    return f"<style>{_CSS}</style><div class=\"wrap\">{body}</div>"


def main(argv=None):
    argv = argv or sys.argv[1:]
    src = argv[0] if argv else "front_page.json"
    out = argv[1] if len(argv) > 1 else "front_page.html"
    with open(src, encoding="utf-8") as fh:
        feed = json.load(fh)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(render(feed))
    print(f"rendered {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
