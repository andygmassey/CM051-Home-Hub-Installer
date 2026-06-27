"""The Editor - Front Page view for the Hub Doctor web UI.

This is the SURFACE that makes The Editor's Front Page reachable on the Hub.
CM059 (the Editor) compiles the interest profile and emits a card feed artefact
to ``~/.ostler/editor/front_page.json`` on a launchd tick; this module reads that
artefact and renders it as an HTML page served at ``/frontpage``, linked from the
Doctor dashboard nav.

The render CONTRACT is the feed JSON schema (DESIGN_the_editor_frontpage.md
section 4), not a shared import: the Doctor (HR015) and the Editor (CM059) live in
different repos and ship on different cadences, so - exactly like the
CM044/CM052 frontmatter parsers - each side keeps its own small reader of the
agreed shape rather than a cross-repo dependency that could silently break either
side.

Graceful by design: when the artefact is missing (a brand-new install before the
Editor has run) or unreadable, we render a calm "still settling in" page rather
than an error, so the route never 500s and a fresh customer never sees a blank.
"""

from __future__ import annotations

import html
import json
import os
from pathlib import Path
from typing import Any, Optional

# Well-known path the Editor (CM059 emit_frontpage) writes. Env override mirrors
# the Editor's own OSTLER_EDITOR_DIR so a custom layout stays in lock-step.
FRONTPAGE_ENV = "OSTLER_EDITOR_FRONTPAGE"
DEFAULT_EDITOR_DIR = Path.home() / ".ostler" / "editor"
FEED_FILENAME = "front_page.json"

_CSS = """
:root{--bg:#0f1115;--card:#171a21;--ink:#e8eaf0;--mut:#9aa3b2;--ac:#6ea8fe;
--good:#5dd39e;--warn:#e0a458;--edge:#232733}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:760px;margin:0 auto;padding:30px 20px 80px}
h1{font-size:25px;margin:0 0 3px}
.sub{color:var(--mut);margin:0 0 24px;font-size:13.5px}
.back{color:var(--ac);text-decoration:none;font-size:13px}
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
.dot{width:8px;height:8px;border-radius:50%;background:var(--ac);animation:p 2s infinite}
@keyframes p{0%{box-shadow:0 0 0 0 rgba(110,168,254,.5)}70%{box-shadow:0 0 0 7px rgba(110,168,254,0)}100%{box-shadow:0 0 0 0 rgba(110,168,254,0)}}
.body{font-size:14px;margin:0 0 8px}
.ev{color:var(--mut);font-size:12.5px;margin:0 0 9px}
.bar{height:5px;background:var(--edge);border-radius:3px;overflow:hidden;margin:9px 0 11px}
.fill{height:100%;background:linear-gradient(90deg,var(--ac),var(--good))}
.ctrls{display:flex;gap:7px;flex-wrap:wrap}
.btn{font-size:12px;border:1px solid #2b3140;background:#1c212b;color:var(--mut);
border-radius:7px;padding:5px 11px;cursor:default}
.btn.go{color:var(--ink);border-color:#39526f;background:#1d2735}
.btn.up{color:var(--good)}.btn.snooze{color:var(--warn)}.btn.drop{color:#e06a6a}
.empty{color:var(--mut);font-style:italic;padding:18px 0}
.foot{color:var(--mut);font-size:12px;margin-top:28px;border-top:1px solid var(--edge);padding-top:14px}
"""


def frontpage_path() -> Path:
    env = os.environ.get(FRONTPAGE_ENV)
    if env:
        return Path(env).expanduser()
    base = os.environ.get("OSTLER_EDITOR_DIR")
    base_dir = Path(base).expanduser() if base else DEFAULT_EDITOR_DIR
    return base_dir / FEED_FILENAME


def read_feed(path: Optional[Path] = None) -> Optional[dict]:
    """Read the Front Page feed artefact, or ``None`` if absent/unreadable.
    Never raises."""
    p = path or frontpage_path()
    try:
        if not p.exists():
            return None
        data = json.loads(p.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def _settling_pct(card: dict) -> Optional[int]:
    ev = card.get("evidence") or ""
    for tok in str(ev).split():
        if tok.endswith("%"):
            try:
                return max(2, min(100, int(tok[:-1])))
            except ValueError:
                return None
    return None


def _card_html(card: dict) -> str:
    kind = card.get("kind", "system")
    settling = kind == "system" and "settling" in str(card.get("id", ""))
    cls = "card"
    kindlabel = kind
    if settling:
        cls += " settling"
        kindlabel = "settling"
    elif kind == "onboarding":
        cls += " onboarding"

    dom = card.get("domain")
    domhtml = f' <span class="dom">{html.escape(str(dom))}</span>' if dom else ""
    title = html.escape(str(card.get("title", "")))
    if settling:
        title = f'<span class="dot" aria-hidden="true"></span>{title}'
    body = html.escape(str(card.get("body", "")))
    ev = card.get("evidence")
    evhtml = f'<div class="ev">{html.escape(str(ev))}</div>' if ev else ""

    bar = ""
    if settling:
        pct = _settling_pct(card)
        if pct is not None:
            bar = f'<div class="bar"><div class="fill" style="width:{pct}%"></div></div>'

    action = card.get("action") or {}
    label = html.escape(str(action.get("label", ""))) if action else ""
    ctrls = []
    if action:
        if action.get("kind") == "strengthen":
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


def _shell(inner: str, sub: str, generated: str = "") -> str:
    return (
        '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        f'<title>Your Front Page</title><style>{_CSS}</style></head><body>'
        '<div class="wrap"><a class="back" href="/doctor">&larr; Doctor</a>'
        '<h1>Your Front Page</h1>'
        f'<p class="sub">{sub}</p>{inner}'
        f'<p class="foot">The Editor &middot; {html.escape(str(generated))}</p>'
        '</div></body></html>')


def render_frontpage(feed: Optional[dict]) -> str:
    """Render the feed (or a graceful settling page when it is missing)."""
    if not feed:
        inner = ('<div class="card settling"><div class="kind settling">settling</div>'
                 '<div class="title"><span class="dot"></span>Your Front Page is still '
                 'settling in</div><div class="body">The Editor has not produced your '
                 'Front Page yet. It fills in as Ostler finishes reading your world - '
                 'check back shortly.</div></div>')
        return _shell(inner, "still settling in")

    cards = feed.get("cards", [])
    inner = "".join(_card_html(c) for c in cards)
    if not inner:
        inner = ('<p class="empty">Nothing on your Front Page yet - Ostler is still '
                 'settling in.</p>')
    n = feed.get("card_count", len(cards))
    phase = html.escape(str(feed.get("phase", "")))
    sub = (f"{n} card{'s' if n != 1 else ''} &middot; phase: {phase} &middot; "
           "cards rank by relevance and fade with age")
    return _shell(inner, sub, feed.get("generated_utc", ""))


def render() -> str:
    """Top-level entry the route calls: read the artefact and render."""
    return render_frontpage(read_feed())
