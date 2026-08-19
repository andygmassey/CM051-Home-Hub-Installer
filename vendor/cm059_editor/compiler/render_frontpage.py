"""Render a Front Page card feed (``frontpage.build_frontpage`` output) into a
self-contained HTML Front Page — the LOCKED masonry design (CM061
``SPEC_frontpage_card_layout.md``, mockup ``andy-frontpage-v2.html``).

This is BOTH a human-viewable surface (the Hub Doctor ``/frontpage`` route
embeds it) AND the render contract the macOS Hub / iOS apps follow when they
render the same JSON. The markup + tokens are the contract; a native surface
re-implements the same masonry from the same card fields.

Design non-negotiables encoded here (Andy, locked):
  * per-section masonry (3->2->1 cols, shortest-column packing, 2-col spans,
    variable card heights) — positioned by the inline layout JS;
  * section BANDS ("Needs you now" / "For you" / "Getting set up") with a count
    badge anchored beside the title and a warm urgency dot on "now";
  * bare, inline-coloured icons — NO rounded-square icon chips, NO watermark /
    ghost background glyphs, NO thin accent left-border rails;
  * an L2 privacy chip (outlined navy shield) shown ONLY where a card's privacy
    differs (names a person), visually distinct from the mono category eyebrow;
  * feedback buttons with a colour keyline in the card's own icon colour;
  * a filled soft-accent setup/status card, reused sparingly as a ``.tint``
    modifier on 1-2 content cards; a per-area completeness ("areas") card;
  * warm off-white / near-black ground, oxblood accent, navy/forest section
    hues; BOTH light and dark themes.

The band a card lands in, its icon, its accent hue and its category eyebrow are
DERIVED from the schema-v0.2 card fields (``kind`` / ``signal.type`` /
``domain`` / ``source`` / ``exploration`` / ``icon``), so the same render works
against the live emitter output and the synthetic fixture alike.

Usage: python3 -m compiler.render_frontpage front_page.json out.html
"""

from __future__ import annotations

import html
import json
import sys
from datetime import datetime

# ---------------------------------------------------------------------------
# Icon set (bare Lucide glyphs — inline <use>, coloured by the card accent).
# NO chip background, NO watermark. Only the glyphs this render can emit.
# ---------------------------------------------------------------------------
_ICON_DEFS = (
    '<svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs>'
    '<g id="i-reply"><polyline points="9 14 4 9 9 4"/><path d="M20 20v-7a4 4 0 0 0-4-4H4"/></g>'
    '<g id="i-gift"><rect x="3" y="8" width="18" height="4" rx="1"/><path d="M12 8v13"/>'
    '<path d="M19 12v7a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2v-7"/>'
    '<path d="M7.5 8a2.5 2.5 0 0 1 0-5C10 3 12 5 12 8c0-3 2-5 4.5-5a2.5 2.5 0 0 1 0 5"/></g>'
    '<g id="i-check"><circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/></g>'
    '<g id="i-users"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/>'
    '<path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></g>'
    '<g id="i-newspaper"><path d="M4 22h16a2 2 0 0 0 2-2V4a2 2 0 0 0-2-2H8a2 2 0 0 0-2 2v16a2 2 0 0 1-2 2Zm0 0a2 2 0 0 1-2-2v-9c0-1.1.9-2 2-2h2"/>'
    '<path d="M18 14h-8"/><path d="M15 18h-5"/><path d="M10 6h8v4h-8Z"/></g>'
    '<g id="i-clapperboard"><path d="M20.2 6 3 11l-.9-2.4c-.3-1.1.3-2.2 1.3-2.5l13.5-4c1.1-.3 2.2.3 2.5 1.3Z"/>'
    '<path d="m6.2 5.3 3.1 3.9"/><path d="m12.4 3.4 3.1 4"/><path d="M3 11h18v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"/></g>'
    '<g id="i-music"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></g>'
    '<g id="i-briefcase"><rect width="20" height="14" x="2" y="7" rx="2"/>'
    '<path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/></g>'
    '<g id="i-sparkles"><path d="M9.94 15.5A2 2 0 0 0 8.5 14.06l-6.14-1.58a.5.5 0 0 1 0-.96L8.5 9.94A2 2 0 0 0 9.94 8.5l1.58-6.14a.5.5 0 0 1 .96 0L14.06 8.5A2 2 0 0 0 15.5 9.94l6.14 1.58a.5.5 0 0 1 0 .96L15.5 14.06a2 2 0 0 0-1.44 1.44l-1.58 6.14a.5.5 0 0 1-.96 0Z"/></g>'
    '<g id="i-arrow"><path d="M5 12h14"/><path d="m12 5 7 7-7 7"/></g>'
    '<g id="i-up"><path d="M7 10v12"/><path d="M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88Z"/></g>'
    '<g id="i-down"><path d="M17 14V2"/><path d="M9 18.12 10 14H4.17a2 2 0 0 1-1.92-2.56l2.33-8A2 2 0 0 1 6.5 2H20a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.76a2 2 0 0 0-1.79 1.11L12 22a3.13 3.13 0 0 1-3-3.88Z"/></g>'
    '<g id="i-ban"><circle cx="12" cy="12" r="10"/><path d="m4.9 4.9 14.2 14.2"/></g>'
    '<g id="i-shield"><path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1Z"/></g>'
    '<g id="i-book"><path d="M12 7v14"/><path d="M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3Z"/></g>'
    '<g id="i-clock"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></g>'
    '<g id="i-message"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2Z"/></g>'
    '<g id="i-layers"><path d="m12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.9a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z"/>'
    '<path d="m22 12.5-9.17 4.16a2 2 0 0 1-1.66 0L2 12.5"/><path d="m22 17.5-9.17 4.16a2 2 0 0 1-1.66 0L2 17.5"/></g>'
    '<g id="i-sun"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M5 5l1.5 1.5M17.5 17.5 19 19M2 12h2M20 12h2M5 19l1.5-1.5M17.5 6.5 19 5"/></g>'
    '<g id="i-moon"><path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/></g>'
    '</defs></svg>'
)

# ---------------------------------------------------------------------------
# CSS — the warm token system + masonry, ported from the LOCKED mockup.
# Both light (:root) and dark (media query + [data-theme] override) themes.
# ---------------------------------------------------------------------------
_CSS = """
:root{
  --chassis:#F7F6F1; --panel:#FFFFFF; --ink:#141210; --page:#EEEDE7;
  --ink-70:rgba(20,18,16,.70); --ink-55:rgba(20,18,16,.55); --ink-40:rgba(20,18,16,.40);
  --accent:#7A1F1F; --accent-hover:#6E1717; --warm:#A82A2A; --navy:#25406E; --forest:#2E5233;
  --accent-soft:rgba(122,31,31,.07); --accent-line:rgba(122,31,31,.22);
  --hair:rgba(20,18,16,.11); --hair-soft:rgba(20,18,16,.07);
  --f-display:'Outfit',system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;
  --f-body:system-ui,-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;
  --f-mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  --shadow-soft:0 1px 2px rgba(20,18,16,.04),0 3px 10px rgba(20,18,16,.05);
  --shadow:0 2px 6px rgba(20,18,16,.06),0 14px 30px rgba(20,18,16,.08);
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  --chassis:#17150F; --panel:#221F18; --ink:#F2EFE8; --page:#0E0C08;
  --ink-70:rgba(242,239,232,.72); --ink-55:rgba(242,239,232,.55); --ink-40:rgba(242,239,232,.40);
  --accent:#D9837A; --accent-hover:#E5948B; --warm:#D9776B; --navy:#9DB2DD; --forest:#96BE97;
  --accent-soft:rgba(217,131,122,.13); --accent-line:rgba(217,131,122,.32);
  --hair:rgba(242,239,232,.13); --hair-soft:rgba(242,239,232,.08);
  --shadow-soft:0 1px 2px rgba(0,0,0,.4),0 3px 12px rgba(0,0,0,.34);
  --shadow:0 2px 8px rgba(0,0,0,.5),0 16px 34px rgba(0,0,0,.46);
}}
:root[data-theme="dark"]{
  --chassis:#17150F; --panel:#221F18; --ink:#F2EFE8; --page:#0E0C08;
  --ink-70:rgba(242,239,232,.72); --ink-55:rgba(242,239,232,.55); --ink-40:rgba(242,239,232,.40);
  --accent:#D9837A; --accent-hover:#E5948B; --warm:#D9776B; --navy:#9DB2DD; --forest:#96BE97;
  --accent-soft:rgba(217,131,122,.13); --accent-line:rgba(217,131,122,.32);
  --hair:rgba(242,239,232,.13); --hair-soft:rgba(242,239,232,.08);
  --shadow-soft:0 1px 2px rgba(0,0,0,.4),0 3px 12px rgba(0,0,0,.34);
  --shadow:0 2px 8px rgba(0,0,0,.5),0 16px 34px rgba(0,0,0,.46);
}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--f-body);background:var(--page);color:var(--ink);-webkit-font-smoothing:antialiased;line-height:1.5;min-height:100vh}
button{font-family:inherit}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:6px}

.appbar{position:sticky;top:0;z-index:60;background:color-mix(in srgb,var(--chassis) 92%,transparent);backdrop-filter:saturate(150%) blur(14px);border-bottom:1px solid var(--hair)}
.appbar-in{max-width:1120px;margin:0 auto;padding:12px 20px}
.brandrow{display:flex;align-items:center;gap:10px;justify-content:space-between}
.brand{font-family:var(--f-display);font-weight:600;font-size:14px;letter-spacing:-.01em;color:var(--ink);display:flex;align-items:center;gap:9px}
.brand .kick{font-family:var(--f-mono);font-size:9.5px;letter-spacing:.16em;text-transform:uppercase;color:var(--accent);font-weight:500}
.tt{width:38px;height:38px;border-radius:50%;border:1px solid var(--hair);background:var(--panel);color:var(--ink-70);cursor:pointer;box-shadow:var(--shadow-soft);display:flex;align-items:center;justify-content:center;flex-shrink:0}
.tt svg{width:17px;height:17px;stroke:currentColor;fill:none;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}

/* FRONT PAGE — masonry */
.fp{max-width:1120px;margin:0 auto;padding:8px 20px 72px}
.fp .masthead{display:flex;align-items:baseline;justify-content:space-between;gap:16px;flex-wrap:wrap;margin:20px 0 4px}
.fp .masthead h1{font-family:var(--f-display);font-weight:700;font-size:clamp(1.7rem,4vw,2.3rem);letter-spacing:-.025em;text-wrap:balance}
.fp .date{font-family:var(--f-mono);font-size:12.5px;color:var(--ink-55)}
.fp .lede{font-size:15px;color:var(--ink-55);margin:6px 0 8px;max-width:62ch}

/* section header — count anchored to the title, warm dot on "now" */
.band-head{display:flex;align-items:center;gap:12px;margin:38px 0 16px}
.band-title{display:inline-flex;align-items:center;gap:10px;font-family:var(--f-display);font-weight:700;font-size:clamp(1.05rem,2.4vw,1.3rem);letter-spacing:-.01em}
.band-count{font-family:var(--f-display);font-weight:700;font-size:12.5px;min-width:23px;height:23px;padding:0 7px;border-radius:999px;display:inline-flex;align-items:center;justify-content:center;color:#fff;background:var(--band-c)}
@media(prefers-color-scheme:dark){:root:not([data-theme="light"]) .band-count{color:#191309}}
:root[data-theme="dark"] .band-count{color:#191309}
:root[data-theme="light"] .band-count{color:#fff}
.band-rule{flex:1;height:2px;border-radius:2px;background:linear-gradient(90deg,var(--band-c),transparent);opacity:.5}
.band-now{--band-c:var(--warm)}
.band-you{--band-c:var(--navy)}
.band-set{--band-c:var(--ink-40)}
.band-now .band-title{color:var(--warm)}
.band-now .band-title::before{content:"";width:8px;height:8px;border-radius:50%;background:var(--warm);box-shadow:0 0 0 4px color-mix(in srgb,var(--warm) 20%,transparent)}
.band-set .band-title{color:var(--ink-55);font-size:1rem}

/* masonry container (JS-positioned; a plain flow stack without JS) */
.masonry{position:relative}
.masonry.ready .card{position:absolute;top:0;left:0}
.masonry:not(.ready) .card{margin-bottom:16px}

/* card — flat panel: no accent rails, no icon backings, no faint bg glyphs */
.card{background:var(--panel);border-radius:14px;box-shadow:var(--shadow-soft);padding:17px 18px 16px;border:1px solid var(--hair-soft)}
@media (prefers-reduced-motion:no-preference){.card{transition:box-shadow .18s ease}}
.card:hover{box-shadow:var(--shadow)}
.card-head{display:flex;align-items:center;gap:9px;margin-bottom:9px}
.card-ic{color:var(--accent-c);flex-shrink:0;display:flex}
.card-ic svg{width:20px;height:20px;stroke:currentColor;fill:none;stroke-width:1.9;stroke-linecap:round;stroke-linejoin:round}
.eyebrow{font-family:var(--f-mono);font-size:10px;letter-spacing:.14em;text-transform:uppercase;color:var(--ink-40);font-weight:500}
.card.hunch .eyebrow{color:var(--warm)}
/* L2 — an outlined privacy shield-badge, deliberately unlike the mono eyebrow */
.l2{margin-left:auto;flex-shrink:0;display:inline-flex;align-items:center;gap:3px;font-family:var(--f-display);font-weight:600;font-size:10px;letter-spacing:.02em;color:var(--navy);padding:2px 7px 2px 5px;border:1px solid color-mix(in srgb,var(--navy) 34%,transparent);border-radius:6px;background:color-mix(in srgb,var(--navy) 7%,transparent)}
.l2 svg{width:11px;height:11px;stroke:currentColor;fill:none;stroke-width:2}
.card-title{font-family:var(--f-display);font-weight:600;font-size:16px;line-height:1.28;letter-spacing:-.01em;text-wrap:balance}
.card.wide .card-title{font-size:18px}
.card-body{font-size:13.5px;color:var(--ink-70);margin-top:5px}
.card.wide .card-body{font-size:14.5px}
.evidence{font-family:var(--f-mono);font-size:11px;color:var(--ink-55);margin-top:11px;letter-spacing:.01em}
/* interest strength */
.strength{display:flex;align-items:center;gap:9px;margin-top:11px}
.bar{width:74px;height:6px;border-radius:3px;background:color-mix(in srgb,var(--ink) 9%,transparent);overflow:hidden}
.bar i{display:block;height:100%;border-radius:3px;background:var(--accent-c)}
.sword{font-family:var(--f-display);font-weight:600;font-size:12px;color:var(--ink-70)}
.strength .ev{font-family:var(--f-mono);font-size:10.5px;color:var(--ink-40)}

/* primary action */
.act{margin-top:14px;font-family:var(--f-display);font-weight:600;font-size:13px;padding:9px 16px;border-radius:10px;border:0;cursor:pointer;display:inline-flex;align-items:center;gap:7px;background:var(--accent);color:#fff}
.act:hover{background:var(--accent-hover)}
.act svg{width:14px;height:14px;stroke:currentColor;fill:none;stroke-width:2.2;stroke-linecap:round;stroke-linejoin:round}
@media(prefers-color-scheme:dark){:root:not([data-theme="light"]) .act{color:#1c110e}}
:root[data-theme="dark"] .act{color:#1c110e}
:root[data-theme="light"] .act{color:#fff}

/* feedback — colour keyline in the card's own icon colour, clearly clickable */
.fb{display:flex;align-items:center;gap:8px;margin-top:14px;padding-top:13px;border-top:1px solid var(--hair-soft);flex-wrap:wrap}
.fb .q{font-size:12.5px;font-weight:500;color:var(--ink-70);margin-right:2px}
.fbtn{display:inline-flex;align-items:center;gap:6px;font-family:var(--f-display);font-weight:600;font-size:12.5px;color:var(--ink);background:color-mix(in srgb,var(--accent-c) 7%,transparent);border:1.5px solid color-mix(in srgb,var(--accent-c) 42%,transparent);border-radius:9px;padding:7px 12px;cursor:pointer;transition:.14s}
.fbtn svg{width:15px;height:15px;stroke:currentColor;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;color:var(--accent-c)}
.fbtn:hover{border-color:var(--accent-c);background:color-mix(in srgb,var(--accent-c) 13%,transparent)}
.fbtn.icon{padding:7px 9px;margin-left:auto}
.fbtn.on-pos{background:var(--accent);border-color:var(--accent);color:#fff}
.fbtn.on-neg{background:transparent;border-color:var(--ink);color:var(--ink)}
.fbtn.on-pos svg,.fbtn.on-neg svg{color:inherit}
@media(prefers-color-scheme:dark){:root:not([data-theme="light"]) .fbtn.on-pos{color:#1c110e}}
:root[data-theme="dark"] .fbtn.on-pos{color:#1c110e}
:root[data-theme="light"] .fbtn.on-pos{color:#fff}
.fb.chosen .fbtn:not(.on-pos):not(.on-neg):not(.icon){opacity:.45}

/* setup / status card — filled soft-accent; .tint reuses it sparingly */
.card.setup{background:var(--accent-soft);border:1px solid var(--accent-line);box-shadow:none}
.card.setup .card-ic{color:var(--accent)}
.card.setup .card-title{color:var(--accent)}
.card.setup:hover{box-shadow:var(--shadow-soft)}
.card.tint{background:color-mix(in srgb,var(--accent-c) 6%,var(--panel));border-color:color-mix(in srgb,var(--accent-c) 20%,transparent)}
/* per-area completeness breakdown */
.areas{margin-top:13px;display:flex;flex-direction:column;gap:10px}
.area-row{display:flex;flex-direction:column;gap:4px}
.area-top{display:flex;justify-content:space-between;align-items:baseline;gap:10px}
.area-top .an{font-family:var(--f-display);font-weight:600;font-size:12.5px;color:var(--ink)}
.area-top .ap{font-family:var(--f-mono);font-size:11px;color:var(--ink-55);font-variant-numeric:tabular-nums}
.area-bar{height:6px;border-radius:3px;background:color-mix(in srgb,var(--ink) 9%,transparent);overflow:hidden}
.area-bar i{display:block;height:100%;border-radius:3px;background:linear-gradient(90deg,var(--accent),var(--warm))}
.prog{margin-top:13px;height:8px;border-radius:5px;background:color-mix(in srgb,var(--ink) 8%,transparent);overflow:hidden}
.prog i{display:block;height:100%;border-radius:5px;background:linear-gradient(90deg,var(--accent),var(--warm))}
.prog-label{font-family:var(--f-mono);font-size:11px;color:var(--ink-55);margin-top:7px}
.card.removing{opacity:0;transition:opacity .26s ease}
.empty{color:var(--ink-55);font-style:italic;padding:26px 2px}
.gfoot{font-family:var(--f-mono);font-size:11px;color:var(--ink-40);text-align:center;padding:12px 20px 44px;line-height:1.8;max-width:1120px;margin:0 auto}
"""

# ---------------------------------------------------------------------------
# Layout + interaction JS — shortest-column masonry with 2-col spans, feedback
# wiring, theme toggle. Vanilla, self-contained, progressive-enhancement.
# ---------------------------------------------------------------------------
_JS = """
function layoutMasonry(m){
  var gap=16, w=m.clientWidth;
  if(!w) return;
  var cols = w>=900?3 : w>=600?2 : 1;
  var cards=[].slice.call(m.querySelectorAll('.card'));
  var colW=(w-gap*(cols-1))/cols;
  m.classList.add('ready');
  cards.forEach(function(c){
    var span=Math.min(c.classList.contains('wide')?2:1, cols);
    c.style.width=(span===2? colW*2+gap : colW)+'px';
  });
  var colH=new Array(cols).fill(0);
  cards.forEach(function(c){
    var span=Math.min(c.classList.contains('wide')?2:1, cols);
    var h=c.offsetHeight, x,y;
    if(span===2 && cols>1){
      var best=0,bv=Infinity;
      for(var i=0;i<cols-1;i++){var v=Math.max(colH[i],colH[i+1]); if(v<bv){bv=v;best=i;}}
      y=Math.max(colH[best],colH[best+1]); x=best*(colW+gap);
      colH[best]=colH[best+1]=y+h+gap;
    } else {
      var b2=0; for(var j=1;j<cols;j++) if(colH[j]<colH[b2]) b2=j;
      y=colH[b2]; x=b2*(colW+gap); colH[b2]+=h+gap;
    }
    c.style.left=x+'px'; c.style.top=y+'px';
  });
  m.style.height=Math.max.apply(null,colH)+'px';
}
function layoutAll(){ [].slice.call(document.querySelectorAll('.masonry')).forEach(layoutMasonry); }
function wireFeedback(){
  [].slice.call(document.querySelectorAll('.fb')).forEach(function(fb){
    var pos=fb.querySelector('.pos'),neg=fb.querySelector('.neg'),dis=fb.querySelector('.dis');
    if(pos)pos.onclick=function(){fb.classList.add('chosen');pos.classList.add('on-pos');if(neg)neg.classList.remove('on-neg');};
    if(neg)neg.onclick=function(){fb.classList.add('chosen');neg.classList.add('on-neg');if(pos)pos.classList.remove('on-pos');};
    if(dis)dis.onclick=function(){var el=dis.closest('.card');if(el){el.classList.add('removing');setTimeout(function(){el.remove();layoutAll();},260);}};
  });
}
var tt=document.getElementById('tt'),ttic=document.getElementById('ttic');
function sysDark(){return window.matchMedia('(prefers-color-scheme:dark)').matches;}
function paintIcon(){var dark=(document.documentElement.getAttribute('data-theme')||(sysDark()?'dark':'light'))==='dark';if(ttic)ttic.innerHTML='<use href="#i-'+(dark?'sun':'moon')+'"/>';}
if(tt)tt.onclick=function(){var cur=document.documentElement.getAttribute('data-theme')||(sysDark()?'dark':'light');document.documentElement.setAttribute('data-theme',cur==='dark'?'light':'dark');paintIcon();requestAnimationFrame(layoutAll);};
wireFeedback(); paintIcon();
requestAnimationFrame(layoutAll);
var rt; window.addEventListener('resize',function(){clearTimeout(rt);rt=setTimeout(layoutAll,120);});
window.addEventListener('load',layoutAll);
"""

# ---------------------------------------------------------------------------
# Card-field -> presentation derivation. Everything is driven from the
# schema-v0.2 fields so the live emitter and the fixture render identically.
# ---------------------------------------------------------------------------
_ACCENT_VAR = {"ox": "var(--accent)", "warm": "var(--warm)",
               "navy": "var(--navy)", "forest": "var(--forest)"}

_ICON_BY_SIGNAL = {"reply_debt": "reply", "gone_quiet": "users",
                   "birthday": "gift", "commitment": "check"}
_ICON_BY_DOMAIN = {
    "professional": "briefcase", "music": "music", "movie_tv": "clapperboard",
    "film": "clapperboard", "film & tv": "clapperboard", "book": "book",
    "news": "newspaper", "reading": "newspaper", "people": "users",
}
_ACCENT_BY_DOMAIN = {
    "professional": "forest", "news": "forest", "reading": "forest",
    "music": "navy", "movie_tv": "ox", "film": "ox", "film & tv": "ox",
    "book": "ox", "food": "warm", "people": "ox",
}
_EYE_BY_SIGNAL = {"reply_debt": "People", "gone_quiet": "People",
                  "birthday": "Dates", "commitment": "Commitments"}
_EYE_BY_DOMAIN = {
    "movie_tv": "Film & TV", "film": "Film & TV", "professional": "Professional",
    "music": "Music", "book": "Reading", "news": "Reading", "people": "People",
    "food": "Food",
}


def _signal_type(card: dict):
    return (card.get("signal") or {}).get("type")


def _is_digest(card: dict) -> bool:
    return "scout_newsletters" in (card.get("source") or "")


def _band_of(card: dict) -> str:
    kind = card.get("kind")
    if kind == "signal":
        return "now"
    if kind in ("system", "onboarding", "consent"):
        return "set"
    return "you"


def _icon_of(card: dict) -> str:
    if card.get("icon"):
        return card["icon"]
    sig = _signal_type(card)
    if sig:
        return _ICON_BY_SIGNAL.get(sig, "message")
    if card.get("areas"):
        return "layers"
    if card.get("exploration"):
        return "sparkles"
    kind = card.get("kind")
    if kind == "system":
        return "sparkles"
    if kind == "onboarding":
        return "check"
    if kind == "consent":
        return "shield"
    src = card.get("source") or ""
    if "scout_newsletters" in src:
        return "newspaper"
    if "scout_film" in src:
        return "clapperboard"
    if "scout_music" in src:
        return "music"
    dom = (card.get("domain") or "").lower()
    return _ICON_BY_DOMAIN.get(dom, "sparkles")


def _accent_of(card: dict) -> str:
    sig = _signal_type(card)
    if sig == "birthday":
        return "warm"
    if sig == "commitment":
        return "navy"
    if sig:
        return "ox"
    if card.get("exploration"):
        return "warm"
    if _band_of(card) == "set":
        return "ox"
    src = card.get("source") or ""
    if "scout_film" in src:
        return "ox"
    if "scout_music" in src:
        return "navy"
    if _is_digest(card):
        return "forest"
    dom = (card.get("domain") or "").lower()
    return _ACCENT_BY_DOMAIN.get(dom, "ox")


def _eyebrow_of(card: dict):
    if card.get("exploration"):
        return "A hunch"
    sig = _signal_type(card)
    if sig:
        return _EYE_BY_SIGNAL.get(sig, "People")
    if card.get("kind") in ("system", "onboarding", "consent"):
        return None  # setup cards read as icon + title, no mono eyebrow
    if _is_digest(card):
        return "Reading"
    dom = card.get("domain")
    if not dom:
        return None
    return _EYE_BY_DOMAIN.get(dom.lower(), dom.replace("_", " ").title())


def _is_wide(card: dict) -> bool:
    if card.get("wide"):
        return True
    if _signal_type(card) == "reply_debt":
        return True
    return _is_digest(card)


def _is_tint(card: dict) -> bool:
    if card.get("tint"):
        return True
    if card.get("exploration"):
        return True
    return _is_digest(card)


def _is_setup(card: dict) -> bool:
    return card.get("kind") in ("system", "onboarding", "consent")


def _is_classification(card: dict) -> bool:
    """A correctable interest-classification card (from the interest profile,
    not a scout): shows a strength meter + feedback verbs, NOT a primary action.
    Scouts / digests / hunches carry an action instead — they come from a
    ``scout_*`` source or are flagged ``exploration``. The correctable interest
    is the one whose 'Spot on' verb IS the feedback, so we render the feedback
    row rather than a strengthen button."""
    return (card.get("kind") == "interest"
            and not card.get("exploration")
            and (card.get("source") or "") == "ostler:interest_profile")


def _strength_word(s: float) -> str:
    if s >= 0.8:
        return "strong"
    if s >= 0.55:
        return "clear"
    if s >= 0.3:
        return "emerging"
    return "faint"


def _settling_pct(card: dict):
    """Percent for a setup/settling card: explicit ``progress`` field, else
    parsed from an evidence string like ``82% of the first read-in done``."""
    p = card.get("progress")
    if isinstance(p, (int, float)):
        return max(2, min(100, int(p)))
    ev = card.get("evidence") or ""
    for tok in ev.split():
        if tok.endswith("%"):
            try:
                return max(2, min(100, int(tok[:-1])))
            except ValueError:
                return None
    return None


def _icon(name: str) -> str:
    return f'<svg viewBox="0 0 24 24"><use href="#i-{html.escape(name)}"/></svg>'


# ---------------------------------------------------------------------------
# Card rendering
# ---------------------------------------------------------------------------

def _card_html(card: dict) -> str:
    accent = _accent_of(card)
    accent_var = _ACCENT_VAR.get(accent, "var(--accent)")
    classes = ["card"]
    if _is_wide(card):
        classes.append("wide")
    if card.get("exploration"):
        classes.append("hunch")
    if _is_setup(card):
        classes.append("setup")
    if _is_tint(card):
        classes.append("tint")
    cls = " ".join(classes)

    # head: bare coloured icon + optional mono eyebrow + optional L2 chip
    eyebrow = _eyebrow_of(card)
    head = f'<div class="card-head"><span class="card-ic">{_icon(_icon_of(card))}</span>'
    if eyebrow:
        head += f'<span class="eyebrow">{html.escape(eyebrow)}</span>'
    if card.get("privacy") == "L2":
        head += f'<span class="l2">{_icon("shield")}L2</span>'
    head += "</div>"

    title = html.escape(card.get("title", ""))
    body = html.escape(card.get("body", ""))
    core = f'<div class="card-title">{title}</div><div class="card-body">{body}</div>'

    # per-area completeness card
    areas = card.get("areas")
    if areas:
        rows = "".join(
            f'<div class="area-row"><div class="area-top">'
            f'<span class="an">{html.escape(str(a[0]))}</span>'
            f'<span class="ap">{int(a[1])}%</span></div>'
            f'<div class="area-bar"><i style="width:{int(a[1])}%"></i></div></div>'
            for a in areas)
        return (f'<div class="{cls}" style="--accent-c:{accent_var}">'
                f'{head}{core}<div class="areas">{rows}</div></div>')

    classification = _is_classification(card)
    strength = card.get("strength")
    meta = ""
    # settling / setup progress
    pct = _settling_pct(card) if _is_setup(card) else None
    if pct is not None:
        meta = (f'<div class="prog"><i style="width:{pct}%"></i></div>'
                f'<div class="prog-label">{pct}% of the first read-in done</div>')
    elif classification and isinstance(strength, (int, float)):
        s = float(strength)
        ev = html.escape(card.get("evidence") or "")
        meta = (f'<div class="strength"><span class="bar">'
                f'<i style="width:{round(s * 100)}%"></i></span>'
                f'<span class="sword">{_strength_word(s)}</span>'
                f'<span class="ev">{ev}</span></div>')
    elif card.get("evidence"):
        meta = f'<div class="evidence">{html.escape(card["evidence"])}</div>'

    foot = ""
    action = card.get("action") or {}
    # Classification cards render the feedback row (the 'Spot on' verb IS their
    # action); every other card with an action gets a primary button.
    if classification:
        foot += ('<div class="fb"><span class="q">Is this you?</span>'
                 f'<button class="fbtn pos" type="button">{_icon("up")}Spot on</button>'
                 f'<button class="fbtn neg" type="button">{_icon("down")}Not me</button>'
                 '<button class="fbtn icon dis" type="button" '
                 f'aria-label="Never show this again">{_icon("ban")}</button></div>')
    elif action and action.get("label"):
        foot += (f'<button class="act" type="button">'
                 f'{html.escape(action["label"])}{_icon("arrow")}</button>')

    return (f'<div class="{cls}" style="--accent-c:{accent_var}">'
            f'{head}{core}{meta}{foot}</div>')


_BANDS = [
    ("now", "Needs you now", "band-now"),
    ("you", "For you", "band-you"),
    ("set", "Getting set up", "band-set"),
]


def _bands_html(cards: list) -> str:
    grouped: dict[str, list] = {"now": [], "you": [], "set": []}
    for c in cards:
        grouped[_band_of(c)].append(c)
    for band in grouped.values():
        band.sort(key=lambda c: c.get("priority", 0), reverse=True)
    out = []
    for key, label, cls in _BANDS:
        band_cards = grouped[key]
        if not band_cards:
            continue
        out.append(
            f'<div class="band-head {cls}"><span class="band-title">'
            f'{html.escape(label)}<span class="band-count">{len(band_cards)}'
            f'</span></span><span class="band-rule"></span></div>'
            f'<div class="masonry" data-band="{key}">'
            + "".join(_card_html(c) for c in band_cards) + "</div>")
    return "".join(out)


def _human_date(generated_utc) -> str:
    if not generated_utc:
        return ""
    try:
        dt = datetime.fromisoformat(str(generated_utc).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return ""
    # e.g. "Saturday, 18 July · 07:42"
    return dt.strftime("%A, %-d %B · %H:%M") if hasattr(dt, "strftime") else ""


def _masthead(feed: dict) -> str:
    date = _human_date(feed.get("generated_utc"))
    date_html = f'<span class="date">{html.escape(date)}</span>' if date else ""
    return (
        '<div class="masthead"><h1>Your Front Page</h1>'
        f'{date_html}</div>'
        '<p class="lede">What Ostler thinks is worth your attention today, drawn '
        'from across your whole life — and ranked, not dumped.</p>')


def render(feed: dict) -> str:
    """Full standalone HTML document — the masonry Front Page."""
    cards = feed.get("cards", [])
    bands = _bands_html(cards)
    if not bands:
        bands = ('<p class="empty">Nothing on your Front Page yet — Ostler is '
                 'still settling in.</p>')
    return (
        '<!doctype html><html><head><meta charset="utf-8"><meta name="lang" content="en-GB">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>Your Front Page</title>'
        f'<style>{_CSS}</style></head><body>'
        f'{_ICON_DEFS}'
        '<div class="appbar"><div class="appbar-in"><div class="brandrow">'
        '<div class="brand"><span class="kick">Ostler · The Editor</span> '
        'Front Page</div>'
        '<button class="tt" id="tt" type="button" '
        'aria-label="Toggle light or dark theme">'
        '<svg id="ttic" viewBox="0 0 24 24"></svg></button>'
        '</div></div></div>'
        f'<div class="fp">{_masthead(feed)}<div id="bands">{bands}</div></div>'
        '<p class="gfoot">The Editor · compiled '
        f'{html.escape(str(feed.get("generated_utc", "")))} · '
        'this preview renders the same JSON the Hub and iOS apps consume.</p>'
        f'<script>{_JS}</script>'
        '</body></html>')


def render_fragment(feed: dict) -> str:
    """Icons + inline CSS + the bands (no <html>/<head>), for embedding inside
    another page (the Doctor dashboard). Includes the layout JS so the masonry
    still positions itself in the host page."""
    cards = feed.get("cards", [])
    bands = _bands_html(cards)
    if not bands:
        bands = ('<p class="empty">Nothing on your Front Page yet — Ostler is '
                 'still settling in.</p>')
    return (f'<style>{_CSS}</style>{_ICON_DEFS}'
            f'<div class="fp"><div id="bands">{bands}</div></div>'
            f'<script>{_JS}</script>')


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
