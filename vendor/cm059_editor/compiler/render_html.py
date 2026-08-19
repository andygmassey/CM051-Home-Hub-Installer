"""Render an interest_profile.json into a standalone HTML Front Page preview.

This is a PREVIEW / data-contract reference, not the shipping surface - the
macOS Hub app and iOS app are the real renderers and consume the same JSON.
But it lets a human (and Andy tonight) actually *see* "What Ostler thinks you're
into", with the four correction controls drawn as affordances.

Usage: python3 -m compiler.render_html interest_profile.json out.html
"""

from __future__ import annotations

import html
import json
import sys


_CSS = """
:root{--bg:#0f1115;--card:#171a21;--ink:#e8eaf0;--mut:#9aa3b2;--ac:#6ea8fe;--good:#5dd39e;--warn:#e0a458}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:860px;margin:0 auto;padding:32px 20px 80px}
h1{font-size:26px;margin:0 0 4px}
.sub{color:var(--mut);margin:0 0 26px}
.dom{margin:0 0 26px}
.dom h2{font-size:17px;letter-spacing:.02em;margin:0 0 10px;display:flex;align-items:baseline;gap:8px}
.dom h2 .n{color:var(--mut);font-weight:400;font-size:13px}
.row{background:var(--card);border:1px solid #232733;border-radius:12px;padding:12px 14px;margin:0 0 8px}
.row .top{display:flex;justify-content:space-between;align-items:center;gap:12px}
.subj{font-weight:600}
.meter{margin:9px 0 7px}
.meter .lab{display:flex;justify-content:space-between;font-size:11px;color:var(--mut);margin:0 0 2px}
.bar2{height:5px;background:#232733;border-radius:3px;overflow:hidden;margin:0 0 7px}
.fill-s{height:100%;background:linear-gradient(90deg,var(--ac),var(--good))}
.fill-c{height:100%;background:linear-gradient(90deg,#b08968,var(--warn))}
.ev{color:var(--mut);font-size:12.5px}
.ctrls{display:flex;gap:6px;margin-top:9px}
.btn{font-size:12px;border:1px solid #2b3140;background:#1c212b;color:var(--mut);border-radius:7px;padding:4px 9px;cursor:default}
.btn.up{color:var(--good)}.btn.down{color:var(--warn)}.btn.drop{color:#e06a6a}
.empty{color:var(--mut);font-style:italic}
.foot{color:var(--mut);font-size:12px;margin-top:30px;border-top:1px solid #232733;padding-top:14px}
"""


def _row(it: dict) -> str:
    # TWO distinct axes, each its own labelled bar:
    #   Strength   = score (ranking weight)  -> scaled x200 since scores sit ~0..0.5
    #   Confidence = how sure we are it's real (the "% sure")
    s_pct = max(3, min(100, round(it["score"] * 200)))
    c_pct = max(3, min(100, round(it["confidence"] * 100)))
    ev = " · ".join(it.get("evidence", [])[:2])
    flagnote = ""
    if it.get("flags"):
        flagnote = f' <span style="color:var(--warn)">⚑ {html.escape(", ".join(it["flags"]))}</span>'
    corr = ""
    if it.get("corrected"):
        corr = f' <span style="color:var(--good)">✎ {html.escape(", ".join(it["corrected"]))}</span>'
    return f"""<div class="row">
  <div class="top"><span class="subj">{html.escape(it['subject'])}</span></div>
  <div class="meter">
    <div class="lab"><span>Strength (how much it stands out)</span><span></span></div>
    <div class="bar2"><div class="fill-s" style="width:{s_pct}%"></div></div>
    <div class="lab"><span>Confidence (how sure we are)</span><span>{it['confidence']:.0%} sure</span></div>
    <div class="bar2"><div class="fill-c" style="width:{c_pct}%"></div></div>
  </div>
  <div class="ev">{html.escape(ev)}{flagnote}{corr}</div>
  <div class="ctrls">
    <span class="btn up">▲ Spot on</span>
    <span class="btn down">▼ Not really</span>
    <span class="btn drop">✕ Wrong</span>
  </div>
</div>"""


def render(profile: dict, top_per_domain: int = 8) -> str:
    s = profile.get("stats", {})
    doms = []
    for b in profile.get("domains", []):
        rows = "".join(_row(it) for it in b["interests"][:top_per_domain])
        doms.append(f'<div class="dom"><h2>{html.escape(b["domain"])} '
                    f'<span class="n">{b["count"]}</span></h2>{rows}</div>')
    dislikes = ""
    if profile.get("dislikes"):
        rows = "".join(_row(it) for it in profile["dislikes"][:top_per_domain])
        dislikes = f'<div class="dom"><h2>Things to avoid</h2>{rows}</div>'
    body = "".join(doms) or '<p class="empty">No confident interests yet - still settling in.</p>'
    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>What Ostler thinks you're into</title><style>{_CSS}</style></head><body>
<div class="wrap">
  <h1>What Ostler thinks you're into</h1>
  <p class="sub">{s.get('interests','?')} interests across {s.get('domains','?')} areas ·
  every one shows its evidence · tap to correct</p>
  {body}{dislikes}
  <p class="foot">Phase 0 preview · compiled {html.escape(str(profile.get('generated_utc','')))} ·
  {s.get('suppressed_low_confidence',0)} low-confidence signals held back.
  This is a preview; the macOS Hub and iOS apps render the same JSON.</p>
</div></body></html>"""


def main(argv=None):
    argv = argv or sys.argv[1:]
    src = argv[0] if argv else "interest_profile.json"
    out = argv[1] if len(argv) > 1 else "interest_profile.html"
    with open(src) as fh:
        profile = json.load(fh)
    with open(out, "w") as fh:
        fh.write(render(profile))
    print(f"rendered {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
