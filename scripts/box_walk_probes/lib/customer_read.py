#!/usr/bin/env python3
"""Customer read: every Hub screen and every wiki section, judged as a picky customer would.

Why this exists (v1.0.106 QA pass, 2026-10-01): hub_screens.py proved the wiki
is styled and the Timeline opens on Today, and every assertion it had passed,
while the same screens showed ISO dates, em dashes, internal ids, four
different people counts, WhatsApp ids rendered as phone numbers, a Governor
that billed Ostler's own VM to "Other apps", three copies of source status
that disagreed, and half-width tables. None of that had an instrument. Each
assertion below is one of those defect classes (CM051 #2534-#2558), and each
was RED on the v1.0.106 walk box.

Two halves, the same contract as hub_screens.py:

  collect(...) -> facts      needs a browser; READ-ONLY (every non-GET is aborted
                             and recorded, never sent)
  judge(facts) -> rows       pure; every assertion is mutation-tested in
                             self_test() against a synthetic good fixture

The Front Page cards are Tauri-only (getFrontPage() returns null outside the
app, #2516). The collector reaches them read-only: after the bundle has loaded
in browser mode it installs a __TAURI_INTERNALS__ shim whose invoke answers
get_front_page from the box's own ~/.ostler/editor/front_page.json and REFUSES
every other command, then re-mounts Home. Doctor-port calls the app makes
(box-status, routines, config...) are routed to the forwarded Doctor port,
which is what Ostler.app does.

Usage:
  customer_read.py --self-test
  customer_read.py judge FACTS.json
"""
import json
import os
import re
import sys
import time

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
NA = "N/A"

# ---------------------------------------------------------------------------
# vocabulary
# ---------------------------------------------------------------------------

ISO_DATE = re.compile(r"(?<![\d/])20\d\d-[01]\d-[0-3]\d(?![\d])")
EM_DASH = "—"
# Internal values a customer must never read. Each was on a v1.0.106 screen.
JARGON = [
    (re.compile(r"(?m)^L[0-3]$"), "privacy level badge (L0-L3)"),
    (re.compile(r"\bstrength 0\.\d"), "raw strength score"),
    (re.compile(r"\bloadavg\b"), "load average"),
    (re.compile(r"[a-z0-9-]+:latest\b"), "model id"),
    (re.compile(r"\b(channel|store):[a-z]"), "component id"),
    (re.compile(r"\b(Qdrant|Oxigraph|RDF|Kafka|SPARQL)\b"), "store name"),
    (re.compile(r"\blocalhost\b|\(:\d{3,5}\)"), "host or port"),
    (re.compile(r"Personal World Graph"), "internal product name"),
    (re.compile(r"\b[a-z]+_[a-z]+(?:_[a-z]+)*\b"), "snake_case key"),
]

# A customer source and every label any screen uses for it. A label that maps
# to an INTERNAL source is an operation, not something a customer can point at.
SOURCE_LABELS = {
    "email": ["mail", "mail messages", "email", "email (full history)", "email conversations", "your emails"],
    "imessage": ["messages", "imessage", "imessage conversations", "your message history"],
    "whatsapp": ["whatsapp", "whatsapp conversations"],
    "calendar": ["calendar", "meetings", "meetings and calendar"],
    "contacts": ["contacts", "address book", "contact", "people and contacts"],
    "browsing": ["safari history", "safari", "browsing"],
    "apple_notes": ["notes"],
    "photos": ["photos"],
    "places": ["places you go", "places"],
    "ai_conversations": ["ai chats"],
    "privacy_backfill": ["privacy labelling"],
    "dedupe": ["duplicate check", "dedupe"],
}
INTERNAL_SOURCES = {"privacy_backfill", "dedupe"}
# The API reports the graph merge as its own source; a customer knows it as contacts.
API_ALIASES = {"people": "contacts", "email_preferences": None, "reminders": None, "reminders_knowledge": None}
OK_WORDS = ("ok", "up to date", "working", "streaming", "running", "ready now")
EMPTY_WORDS = ("no_data", "not_run", "nothing found", "not started", "not run yet", "nothing to add")

BARE_TITLE = re.compile(r"^\s*(\w+\s+)?conversation\s*$", re.I)
DOUBLED_WORD = re.compile(r"\b(\w+)\s+\1\b", re.I)
PHONE = re.compile(r"\+\d[\d \u00a0\u202a-\u202e\u2066-\u2069]{6,}\d")
BIDI = re.compile(r"[‪-‮⁦-⁩]")
OSTLER_PROCS = re.compile(r"Virtualization\.VirtualMachine|llama-server|ollama|colima", re.I)

WIDTH_MIN = 0.95
# Emails and URLs carry underscores and ports legitimately; judge the prose around them.
STRIP_ADDRESSES = re.compile(r"\S+@\S+|https?://\S+|\S*\?\S*=\S*")


def source_of(label):
    l = (label or "").strip().lower()
    for src, labels in SOURCE_LABELS.items():
        if l in labels:
            return src
    return None


def status_class(word):
    w = (word or "").strip().lower()
    if any(w.startswith(x) for x in OK_WORDS):
        return "ok"
    if any(w.startswith(x) for x in EMPTY_WORDS):
        return "empty"
    return None


def _num(s):
    try:
        return int(str(s).replace(",", ""))
    except Exception:
        return None


def _lines(t):
    return [x.strip() for x in (t or "").splitlines()]


def _segment(text, start, stops):
    """Lines after the first line equal to `start` (case-insensitive) up to a stop line."""
    ls = _lines(text)
    out, on = [], False
    for x in ls:
        if not on:
            if x.lower() == start.lower():
                on = True
            continue
        if any(x.lower().startswith(s.lower()) for s in stops):
            break
        out.append(x)
    return out if on else None


def card_titles(seg):
    """Card titles in a 'Needs you now' band: the first content line after a category label."""
    if seg is None:
        return None
    titles, want = [], False
    for x in seg:
        if not x or re.fullmatch(r"L[0-3]|\d+", x):
            continue
        if re.fullmatch(r"[A-Z][A-Z '&]+", x):      # DATES, PEOPLE, DUPLICATE (CSS uppercase)
            want = True
            continue
        if want:
            titles.append(x)
            want = False
    return titles


def count_after(text, label):
    """'8,137 PEOPLE' or '8,138\\nPEOPLE' -> 8137."""
    m = re.search(r"([\d,]{1,9})\s*\n?\s*" + label + r"\b", text or "")
    return _num(m.group(1)) if m else None


# ---------------------------------------------------------------------------
# judge: pure
# ---------------------------------------------------------------------------

DECLARED = [
    "customer text: no ISO dates on any Hub screen or wiki page",
    "customer text: no em dash on any Hub screen or wiki page",
    "customer text: no internal values (badges, scores, store names, ports, keys)",
    "hub: every page title matches its sidebar label",
    "hub: every GET a screen makes returns 2xx",
    "hub: the device bearer never appears in a URL",
    "home: dates read as English ('in five days', not 'In five days away')",
    "home: every Spot on / Not me card carries the interest id its POST needs",
    "home: Needs you now is the same list in the app and on the wiki front page",
    "governor: Ostler's own VM and model runner are counted as Ostler",
    "doctor: the connected-sources count matches the sources it lists",
    "timeline: every message row is titled, with no doubled word",
    "people: no phone number is an internal id (14+ digits) or carries bidi controls",
    "people: no UNREVIEWED phone number appears on two rows",
    "counts: people agree across the Hub, the wiki front page and the People index",
    "counts: organisations agree across the wiki front page and the Organisations page",
    "sources: the wiki source list has no duplicate source",
    "sources: no internal operation is listed as a source",
    "sources: the Doctor data sources tab agrees with /api/v1/sources",
    "sources: wiki Data freshness lists every source the box reports as working",
    "wiki: every table and box is at least 95% of the page width",
    "doctor: the Hub's own config read (as the app sends it) is accepted",
    "bursar: model calls recorded within 5% of Ollama's logged calls",
]


def judge(f, declared=None):
    declared = DECLARED if declared is None else declared
    out = []

    def add(name, ok, detail=""):
        out.append((name, ok if ok is None or ok == NA else bool(ok), detail))

    screens = f.get("screens") or {}
    wiki = (f.get("wiki") or {}).get("pages") or {}
    texts = [("hub " + k, (v or {}).get("text") or "") for k, v in screens.items()]
    texts += [("wiki " + k, (v or {}).get("text") or "") for k, v in wiki.items()]
    measured = [t for t in texts if t[1].strip()]

    def over_text(name, pred, show):
        if not measured:
            add(name, None, "NOT MEASURED: no screen text was collected")
            return
        bad = []
        for where, t in measured:
            hits = pred(t)
            if hits:
                bad.append("{}: {}".format(where, show(hits)))
        add(name, not bad, "; ".join(bad[:6]) + (" (+{} more)".format(len(bad) - 6) if len(bad) > 6 else ""))

    over_text(DECLARED[0], lambda t: ISO_DATE.findall(t), lambda h: "{} ISO date(s) (values withheld)".format(len(h)))
    # Decision 2026-10-01: Ostler never rewrites the customer's own titles. The
    # exemption is FIELD-LEVEL: only the title of a Timeline row whose kind is
    # "event" (a verbatim calendar item, as the API returned it) is exempt, and
    # only on the Timeline screen. Every other dash on that screen (a placeholder,
    # a label, a separator) and every dash anywhere else still counts.
    # TODO(#2565): key this on the entry's source field once the timeline API
    # carries one, instead of on kind == "event".
    exempt = sorted({r.get("title") or "" for r in (f.get("timeline_rows") or [])
                     if r.get("kind") == "event" and EM_DASH in (r.get("title") or "")},
                    key=len, reverse=True)

    def ostler_dashes(where, t):
        if where == "hub timeline":
            for title in exempt:
                t = t.replace(title, "")
        return t.count(EM_DASH)
    if not measured:
        add(DECLARED[1], None, "NOT MEASURED: no screen text was collected")
    else:
        bad = ["{}: {} em dash(es) written by Ostler".format(w, n) for w, t in measured
               for n in [ostler_dashes(w, t)] if n]
        add(DECLARED[1], not bad, "; ".join(bad[:6]))
    over_text(DECLARED[2],
              lambda t: [why for rx, why in JARGON if rx.search(STRIP_ADDRESSES.sub(" ", t))],
              lambda h: ", ".join(sorted(set(h))))

    # page titles
    if not screens:
        add(DECLARED[3], None, "NOT MEASURED: no Hub screens")
    else:
        bad = ["{} shows '{}'".format(v.get("nav"), v.get("title")) for v in screens.values()
               if v.get("nav") and v.get("title") is not None
               and v.get("title").strip().lower() != v.get("nav").strip().lower()]
        add(DECLARED[3], not bad, "; ".join(bad))

    # requests
    reqs = f.get("requests")
    if reqs is None:
        add(DECLARED[4], None, "NOT MEASURED: no request log")
    else:
        bad = sorted({"{} {}".format(r.get("s"), r.get("u")) for r in reqs
                      if r.get("m") == "GET" and int(r.get("s") or 0) >= 400})
        add(DECLARED[4], not bad, "; ".join(bad[:5]))
    bu = f.get("bearer_in_url")
    if bu is None:
        add(DECLARED[5], None, "NOT MEASURED: the collector did not check URLs for the bearer")
    else:
        add(DECLARED[5], bu == 0, "{} URL(s) carried the device bearer (e.g. ?token= on the wiki iframe or the chat WebSocket)".format(bu))

    home = (screens.get("home") or {}).get("text")
    if not home:
        add(DECLARED[6], None, "NOT MEASURED: Home was not read")
    else:
        bad = re.findall(r"\bIn [^.\n]* away\b", home)
        add(DECLARED[6], not bad, "; ".join(sorted(set(bad))[:3]))

    feed = f.get("feed")
    if feed is None:
        add(DECLARED[7], None, "NOT MEASURED: the Front Page feed was not read")
    else:
        fb = [c for c in feed if c.get("action_kind") == "strengthen"]
        missing = [c for c in fb if not c.get("has_interest_id")]
        add(DECLARED[7], NA if not fb else not missing,
            "{} of {} feedback cards carry no interest_id, so their POST is refused 400".format(len(missing), len(fb)))

    wfront = (wiki.get("front") or {}).get("text")
    a = card_titles(_segment(home, "Needs you now", ["For you", "Getting set up"])) if home else None
    b = card_titles(_segment(wfront, "Needs you now", ["For you", "Getting set up"])) if wfront else None
    if a is None or b is None:
        add(DECLARED[8], None, "NOT MEASURED: app={} wiki={}".format(a is not None, b is not None))
    else:
        add(DECLARED[8], sorted(a) == sorted(b),
            "app has {} card(s), wiki has {}; {} in common".format(len(a), len(b), len(set(a) & set(b))))

    gov = (screens.get("governor") or {}).get("text")
    seg = _segment(gov, "Other apps", ["Pause", "Processing speed"]) if gov else None
    if seg is None:
        add(DECLARED[9], None if not gov else NA, "NOT MEASURED: Governor not read" if not gov else "no Other apps row")
    else:
        hits = sorted(set(m.group(0) for x in seg for m in [OSTLER_PROCS.search(x)] if m))
        add(DECLARED[9], not hits, "Ostler's own process(es) listed under Other apps: " + ", ".join(hits))

    doc = (screens.get("doctor") or {}).get("text")
    if not doc:
        add(DECLARED[10], None, "NOT MEASURED: Doctor not read")
    else:
        m = re.search(r"CONNECTED SOURCES\s*\n\s*(\d+)", doc)
        seg = _segment(doc, "Active", ["WHAT'S RUNNING", "DIAGNOSTICS"])
        listed = len([x for x in (seg or []) if re.fullmatch(r"Streaming|Connected|Idle|Paused|Offline|Error|Waiting", x)])
        if not m or seg is None:
            add(DECLARED[10], None, "NOT MEASURED: tile={} list={}".format(bool(m), seg is not None))
        else:
            add(DECLARED[10], int(m.group(1)) == listed, "tile says {}, list shows {}".format(m.group(1), listed))

    tl = f.get("timeline_titles")
    if tl is None:
        add(DECLARED[11], None, "NOT MEASURED: Timeline rows not read")
    else:
        bare = sorted({t.strip() for t in tl if BARE_TITLE.match(t or "")})
        doubled = [t for t in tl if not BARE_TITLE.match(t or "") and DOUBLED_WORD.search(t or "")]
        # A bare title is product copy and safe to print; any other title is the
        # customer's own data, so only its count reaches a walk record.
        add(DECLARED[11], not bare and not doubled,
            "{} untitled ({}); {} other title(s) with a doubled word (withheld)".format(
                len(bare), "; ".join(bare[:4]), len(doubled)))

    rows = f.get("people_rows")
    if rows is None:
        add(DECLARED[12], None, "NOT MEASURED: People rows not read")
        add(DECLARED[13], None, "NOT MEASURED: People rows not read")
    else:
        bad, seen, dup = [], {}, set()
        for i, r in enumerate(rows):
            nums = set()
            for p in PHONE.findall(r):
                d = re.sub(r"\D", "", p)
                if len(d) >= 14 or BIDI.search(p):
                    bad.append("row {}: {} digits{}".format(i, len(d), ", bidi control" if BIDI.search(p) else ""))
                nums.add(d)
            for d in nums:
                if d in seen:
                    dup.add(d)
                seen.setdefault(d, i)
        add(DECLARED[12], not bad, "{} of {} rows: {}".format(len(bad), len(rows), "; ".join(bad[:4])))
        # CM051 walk-probe fix (v1.0.107): a phone shared by two DISTINCT real
        # people (a household landline, a shared office number) is not the
        # same defect as a silent duplicate Contacts card for the SAME
        # person (CM051 #2545) -- the first is a fact about the world, the
        # second is a bug. Both used to fail this assertion identically. A
        # number that the customer can already see on their own Doctor "tidy
        # your contacts" page (identity_resolver.tidy, via
        # /api/v1/contacts/diff) -- either as a one-click merge proposal or
        # as a review card, which is exactly what CM051 #2604 routes a
        # RULE-2-refused auto-merge into -- is no longer SILENT, so it no
        # longer fails here. A duplicate absent from that surface is still
        # silent and still fails. `reviewed` is None (not an empty set) when
        # the collector could not read the diff endpoint at all, so a
        # transport failure cannot masquerade as "nothing to review" and
        # silently pass every duplicate through -- see the CANNOT-RUN branch
        # immediately below.
        reviewed_raw = f.get("duplicate_review_phones")
        if dup and reviewed_raw is None:
            add(DECLARED[13], None,
                "NOT MEASURED: {} duplicate number(s) found but the duplicate-review "
                "surface (/api/v1/contacts/diff) could not be read, so reviewed-vs-"
                "silent cannot be told apart: {}".format(
                    len(dup), f.get("duplicate_review_phones_error") or "no error recorded"))
        else:
            reviewed = {re.sub(r"\D", "", p) for p in (reviewed_raw or [])}
            silent = dup - reviewed
            add(DECLARED[13], not silent,
                "{} of {} duplicated number(s) are UNREVIEWED (numbers withheld); "
                "{} already surfaced as a duplicate-review card".format(
                    len(silent), len(dup), len(dup & reviewed)))

    ppl = {"hub": count_after((screens.get("people") or {}).get("text"), "PEOPLE"),
           "wiki front": count_after(wfront, "PEOPLE"),
           "People index": _num((re.search(r"([\d,]+) (?:contacts|people)\b",
                                           (wiki.get("people") or {}).get("text") or "") or [None, None])[1])}
    got = {k: v for k, v in ppl.items() if v}
    if len(got) < 2:
        add(DECLARED[14], None, "NOT MEASURED: {}".format(ppl))
    else:
        lo, hi = min(got.values()), max(got.values())
        add(DECLARED[14], lo >= hi * 0.99, ", ".join("{} {}".format(k, v) for k, v in got.items()))
    org = {"wiki front": count_after(wfront, "ORGANISATIONS"),
           "Organisations page": count_after((wiki.get("organisations") or {}).get("text"), "ORGANISATIONS")}
    if not all(org.values()):
        add(DECLARED[15], None, "NOT MEASURED: {}".format(org))
    else:
        add(DECLARED[15], org["wiki front"] == org["Organisations page"], ", ".join("{} {}".format(k, v) for k, v in org.items()))

    # sources
    api = {}
    for s, st in (f.get("api") or {}).get("sources") or []:
        s2 = API_ALIASES.get(s, s)
        if s2:
            c = status_class(st)
            api[s2] = "ok" if (api.get(s2) == "ok" or c == "ok") else c
    wl = (wiki.get("front") or {}).get("sources")
    if wl is None:
        add(DECLARED[16], None, "NOT MEASURED: the wiki source list was not read")
        add(DECLARED[17], None, "NOT MEASURED: the wiki source list was not read")
    else:
        by = {}
        for label, _st in wl:
            by.setdefault(source_of(label), []).append(label)
        dups = ["{} as {}".format(k, " + ".join(v)) for k, v in by.items() if k and len(v) > 1]
        add(DECLARED[16], not dups, "; ".join(dups))
        internal = [l for l, _ in wl if source_of(l) in INTERNAL_SOURCES]
        add(DECLARED[17], not internal, ", ".join(internal))
    dt = (screens.get("doctor_sources") or {}).get("rows")
    if dt is None or not api:
        add(DECLARED[18], None, "NOT MEASURED: tab rows={} api={}".format(dt is not None, bool(api)))
    else:
        bad = []
        for label, st in dt:
            s = source_of(label)
            if s and s in api and status_class(st) and status_class(st) != api[s]:
                bad.append("{} reads '{}', the box says {}".format(label, st, api[s]))
        add(DECLARED[18], not bad, "; ".join(bad))
    fr = (wiki.get("front") or {}).get("freshness")
    if fr is None or not api:
        add(DECLARED[19], None, "NOT MEASURED: freshness={} api={}".format(fr is not None, bool(api)))
    else:
        listed = {source_of(l) for l in fr}
        missing = sorted(s for s, c in api.items() if c == "ok" and s not in INTERNAL_SOURCES and s not in listed)
        add(DECLARED[19], not missing, "{} working source(s) absent: {}".format(len(missing), ", ".join(missing)))

    boxes = [(p, b) for p, v in wiki.items() for b in (v or {}).get("boxes") or []]
    if not wiki:
        add(DECLARED[20], None, "NOT MEASURED: no wiki page was measured")
    else:
        narrow = ["{} '{}' {}%".format(p, b.get("label", "")[:30], int(100 * b["w"] / b["aw"]))
                  for p, b in boxes if b.get("aw") and b["w"] < WIDTH_MIN * b["aw"]]
        add(DECLARED[20], not narrow, "{} of {} narrow: {}".format(len(narrow), len(boxes), "; ".join(narrow[:5])))

    cfg = (f.get("api") or {}).get("config_as_app")
    if cfg is None:
        add(DECLARED[21], None, "NOT MEASURED: config not read")
    else:
        add(DECLARED[21], 200 <= int(cfg) < 300, "GET /api/v1/config with the app's Origin and Sec-Fetch-Site answered {}".format(cfg))

    bx = f.get("box") or {}
    oc, jr = bx.get("ollama_calls"), bx.get("journal_rows")
    if not oc:
        add(DECLARED[22], None if oc is None else NA, "NOT MEASURED: no Ollama call count" if oc is None else "Ollama logged no calls in the window")
    else:
        add(DECLARED[22], (jr or 0) >= 0.95 * oc,
            "{} recorded vs {} Ollama calls in {} min ({}%)".format(jr, oc, bx.get("window_min"), int(100 * (jr or 0) / oc)))

    # a judge that produced no assertion, or skipped a declared one, is itself a failure
    names = [n for n, _, _ in out]
    missing = [d for d in declared if d not in names]
    add("customer read: every declared assertion produced a row", not missing and len(out) >= len(declared),
        "{} declared, {} emitted, missing: {}".format(len(declared), len(names), "; ".join(missing)))
    return out


# ---------------------------------------------------------------------------
# collect: needs Playwright. READ-ONLY.
# ---------------------------------------------------------------------------

DOCTOR_PATHS = ("/api/v1/box-status", "/api/v1/config", "/api/v1/governor-status", "/api/v1/hydration/status",
                "/api/v1/pause", "/api/v1/remote-access", "/api/v1/routines", "/doctor/api/", "/api/v1/sources")
HUB_ROUTES = [("/", "home"), ("/chat", "chat"), ("/timeline", "timeline"), ("/people", "people"),
              ("/cost", "bursar"), ("/doctor", "doctor"), ("/governor", "governor"),
              ("/pairing", "pairing"), ("/preferences", "settings")]
WIKI_SECTIONS = {"front": "", "people": "People/", "activity": "Meetings/", "life": "Topics/",
                 "knowledge": "Knowledge/", "organisations": "Organisations/", "system": "data-sources/"}

WIDTH_JS = r"""() => {
  const art = document.querySelector('article.md-content__inner') || document.querySelector('article');
  if (!art) return null;
  const cs = getComputedStyle(art);
  const aw = art.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
  const head = el => { let p = el; for (let i = 0; i < 8 && p && p !== art; i++, p = p.parentElement) {
      let s = p.previousElementSibling; while (s && !/^H[1-4]$/.test(s.tagName)) s = s.previousElementSibling;
      if (s) return s.innerText.replace('¶', '').trim(); } return ''; };
  const out = [];
  art.querySelectorAll('table').forEach(t => {
    const r = t.querySelector('tr');
    const w = r ? r.getBoundingClientRect().width : t.getBoundingClientRect().width;
    out.push({what: 'table', label: head(t), w: Math.round(w), aw: Math.round(aw)});
  });
  art.querySelectorAll('div, section, details, aside').forEach(el => {
    if (el.querySelector('table')) return;
    const st = getComputedStyle(el);
    const framed = (parseFloat(st.borderTopWidth) > 0 && st.borderTopStyle !== 'none') || st.boxShadow !== 'none';
    if (!framed) return;
    const p = el.parentElement; const pd = p ? getComputedStyle(p).display : '';
    if (/grid|flex/.test(pd) && p.children.length > 1) return;     // a card in a row of cards
    const r = el.getBoundingClientRect(); if (r.width < 1 || r.height < 1) return;
    out.push({what: 'box', label: head(el) || (el.innerText || '').slice(0, 30), w: Math.round(r.width), aw: Math.round(aw)});
  });
  return out;
}"""


def collect(base, token, doctor_base, feed_path, out_dir, wiki_wait_s=120):
    from playwright.sync_api import sync_playwright

    os.makedirs(out_dir, exist_ok=True)
    f = {"screens": {}, "requests": [], "blocked_writes": [], "bearer_in_url": 0, "wiki": {"pages": {}}, "api": {}}

    def clean(u):
        u = u.replace(base, "").replace(doctor_base or "@@", "[doctor]")
        u = re.sub(r"/wiki/s/[^/]+/", "/wiki/s/<s>/", u)
        u = re.sub(r"([?&]token=)[^&]+", r"\1<redacted>", u)
        return re.sub(r"/[0-9a-f]{8}-[0-9a-f-]{27,}", "/<id>", u)

    def saw(url):
        if token and token in url:
            f["bearer_in_url"] += 1

    feed_json = None
    if feed_path:
        try:
            feed_json = json.load(open(feed_path))
            f["feed"] = [{"kind": c.get("kind"), "action_kind": (c.get("action") or {}).get("kind"),
                          "has_interest_id": bool(c.get("interest_id") or (c.get("action") or {}).get("interest_id")
                                                  or (c.get("feedback") or {}).get("interest_id"))}
                         for c in feed_json.get("cards") or []]
        except Exception as exc:
            f["feed_error"] = str(exc)[:200]

    with sync_playwright() as pw:
        browser = pw.webkit.launch(headless=True)
        ctx = browser.new_context(viewport={"width": 1440, "height": 1000})
        ctx.add_init_script("try { localStorage.setItem('zeroclaw_token', %s); } catch (e) {}" % json.dumps(token))
        page = ctx.new_page()

        def guard(route, request):
            saw(request.url)
            if request.method not in ("GET", "HEAD", "OPTIONS"):
                f["blocked_writes"].append({"m": request.method, "u": clean(request.url)})
                return route.abort()
            path = request.url.replace(base, "")
            if doctor_base and any(path.startswith(d) for d in DOCTOR_PATHS):
                return route.continue_(url=doctor_base + path)
            return route.continue_()

        page.route("**/*", guard)
        page.on("websocket", lambda ws: saw(ws.url))

        def on_resp(r):
            try:
                f["requests"].append({"m": r.request.method, "u": clean(r.url), "s": r.status})
            except Exception:
                pass
        page.on("response", on_resp)

        page.goto(base + "/", wait_until="domcontentloaded", timeout=60000)
        page.wait_for_selector('a[href="/chat"]', timeout=180000)
        time.sleep(3)
        if feed_json is not None:
            page.evaluate("""feed => { window.__TAURI_INTERNALS__ = { invoke: async (cmd) => {
                if (cmd === 'get_front_page') return {available: true, feed: feed};
                if (cmd.startsWith('get_')) return null;
                throw new Error('read-only probe refuses ' + cmd); }, transformCallback: () => 0 }; }""", feed_json)
        nav_labels = dict(page.evaluate("() => Array.from(document.querySelectorAll('nav a, aside a')).map(a => [a.getAttribute('href'), a.innerText.trim()])"))

        def go(path):
            link = page.locator('a[href="%s"]' % path)
            if link.count():
                link.first.click()
            else:
                page.evaluate("p => { history.pushState({}, '', p); dispatchEvent(new PopStateEvent('popstate')); }", path)
            time.sleep(3)
            for _ in range(40):
                busy = page.evaluate("() => { const m = document.querySelector('main') || document.body;"
                                     " return /\\bLoading\\b|Preparing|Connecting/i.test(m.innerText || '')"
                                     " || !!m.querySelector('.animate-spin'); }")
                if not busy:
                    break
                time.sleep(2)
            time.sleep(2)

        def read(name, path):
            s = {"path": path, "nav": nav_labels.get(path)}
            s["title"] = page.evaluate("() => { const h = document.querySelector('header h1'); return h ? h.innerText.trim() : null }")
            s["text"] = page.evaluate("() => { const m = document.querySelector('main'); return m ? m.innerText : '' }")
            page.screenshot(path=os.path.join(out_dir, "cr-%s.png" % name))
            f["screens"][name] = s
            return s

        if feed_json is not None:      # re-mount Home so it reads the feed through the shim
            go("/people")
        for path, name in HUB_ROUTES:
            go(path)
            read(name, path)
            if name == "timeline":
                f["timeline_rows"] = page.evaluate("() => Array.from(document.querySelectorAll('[data-timeline-row]')).map(e => ({kind: e.getAttribute('data-timeline-kind') || '', title: e.getAttribute('data-timeline-title') || ''}))")
                f["timeline_titles"] = [r["title"] for r in f["timeline_rows"]]
            if name == "people":
                f["people_rows"] = page.evaluate("() => Array.from(document.querySelectorAll('[data-person-row]')).map(e => e.innerText)")
            if name == "doctor":
                tab = page.locator("button", has_text="Data sources")
                if tab.count():
                    tab.first.click()
                    time.sleep(5)
                    rows = page.evaluate("() => Array.from(document.querySelectorAll('main table tr')).map(tr => Array.from(tr.querySelectorAll('td')).map(td => td.innerText.trim()))")
                    f["screens"]["doctor_sources"] = {"rows": [[r[0], r[-1]] for r in rows if len(r) >= 2]}
                    page.screenshot(path=os.path.join(out_dir, "cr-doctor-sources.png"))

        # wiki
        go("/wiki")
        fr, t0 = None, time.time()
        while time.time() - t0 < wiki_wait_s:
            fr = next((x for x in page.frames if "/wiki/" in (x.url or "")), None)
            if fr:
                break
            time.sleep(2)
        if fr is None:
            # #2496: while hydration is incomplete the Hub shows no wiki frame. The
            # wiki itself is still served; read it the way the frame would have
            # (one gateway navigation, redirected to a /wiki/s/ session) in a
            # separate page, so the probe's own token URL is not counted above.
            f["wiki"]["frame_absent"] = "no wiki frame in the Hub within {}s (#2496)".format(wiki_wait_s)
            # Same geometry as the in-app frame (viewport minus the 240px sidebar):
            # the wiki's tables collapse to content width below a breakpoint,
            # so a wider read would hide exactly the defect it is measuring.
            wpage = ctx.new_page()
            wpage.set_viewport_size({"width": 1440 - 240, "height": 944})
            # TODO(#2558): this mirrors the app's own iframe navigation, which puts the device
            # bearer in the URL. When the single-use wiki ticket lands, mint one with a Bearer
            # fetch and navigate with the ticket instead; then no URL here carries the token.
            wpage.goto(base + "/wiki/?token=" + token, wait_until="load", timeout=90000)
            fr = wpage.main_frame
        if fr is not None:
            fr.wait_for_load_state("load", timeout=60000)
            wbase = re.match(r"(.*/wiki/s/[^/]+/)", fr.url)
            wbase = wbase.group(1) if wbase else fr.url.split("?")[0]
            for name, rel in WIKI_SECTIONS.items():
                try:
                    fr.goto(wbase + rel, wait_until="load", timeout=60000)
                    time.sleep(2)
                    pg = {"text": fr.evaluate("() => { const a = document.querySelector('article') || document.body; return a.innerText }"),
                          "boxes": fr.evaluate(WIDTH_JS) or []}
                    if name == "front":
                        pg["sources"] = fr.evaluate(r"""() => {
                          const h = [...document.querySelectorAll('h2,h3,div,p')].find(e => /where your information is coming from/i.test(e.innerText || '') && e.children.length < 3);
                          if (!h) return null;
                          const box = h.parentElement; const lines = box.innerText.split('\n').map(s => s.trim()).filter(Boolean);
                          const out = []; for (let i = 0; i < lines.length - 1; i++) {
                            if (/^(Up to date|Nothing found|Not started|Working|Failed)/i.test(lines[i + 1])) out.push([lines[i], lines[i + 1]]); }
                          return out; }""")
                        pg["freshness"] = fr.evaluate(r"""() => {
                          const h = [...document.querySelectorAll('h2,h3')].find(e => /data freshness/i.test(e.innerText || ''));
                          if (!h) return null; let t = h.nextElementSibling; while (t && !t.querySelector('table') && t.tagName !== 'TABLE') t = t.nextElementSibling;
                          if (!t) return []; const tb = t.tagName === 'TABLE' ? t : t.querySelector('table');
                          return Array.from(tb.querySelectorAll('tbody tr')).map(tr => tr.cells[0].innerText.trim()); }""")
                    f["wiki"]["pages"][name] = pg
                    page.screenshot(path=os.path.join(out_dir, "cr-wiki-%s.png" % name))
                except Exception as exc:
                    f["wiki"].setdefault("errors", []).append("{}: {}".format(name, str(exc)[:160]))
        browser.close()

    # GETs the app makes, sent the way the app sends them (read-only)
    import urllib.request
    if doctor_base:
        try:
            with urllib.request.urlopen(doctor_base + "/api/v1/sources", timeout=20) as r:
                f["api"]["sources"] = [[s.get("source"), s.get("status")] for s in json.load(r).get("sources") or []]
        except Exception as exc:
            f["api"]["sources_error"] = str(exc)[:160]
        req = urllib.request.Request(doctor_base + "/api/v1/config", headers={
            "Authorization": "Bearer " + token, "Origin": "tauri://localhost", "Sec-Fetch-Site": "cross-site"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                f["api"]["config_as_app"] = r.status
        except urllib.error.HTTPError as exc:
            f["api"]["config_as_app"] = exc.code
        except Exception as exc:
            f["api"]["config_error"] = str(exc)[:160]

    # CM051 walk-probe fix (v1.0.107): DECLARED[13] ("no phone number appears
    # on two rows") used to fail a shared landline between two distinct real
    # people exactly as hard as a silent duplicate-contact-card defect, with
    # no way to tell them apart from the People page alone. Read the SAME
    # duplicate-review surface the customer's own Doctor "tidy your contacts"
    # tab renders -- /api/v1/contacts/diff (identity_resolver.tidy.TidyEngine,
    # read-only, writes nothing) -- and extract ONLY the bare digits of any
    # phone_match pair's number, discarding the surrounding evidence text
    # immediately: `details` holds a readable "Shared phone: <number> (names
    # agree)" string, which must never survive into the walk artefact. A pair
    # that shows up here (propose_merge OR review -- both are customer-visible
    # cards; review is also exactly what CM051 #2604 routes a RULE-2-refused
    # auto-merge into) is a number the customer can already see is shared and
    # can already act on, which is not the same defect as a number nobody was
    # ever told about.
    try:
        req = urllib.request.Request(base + "/api/v1/contacts/diff", headers={
            "Authorization": "Bearer " + token})
        with urllib.request.urlopen(req, timeout=180) as r:
            diff = json.load(r)
        reviewed = set()
        for item in diff.get("items") or []:
            strategy = (item.get("evidence") or {}).get("strategy") or ""
            if not strategy.startswith("phone"):
                continue
            details = (item.get("evidence") or {}).get("details") or ""
            for p in PHONE.findall(details):
                reviewed.add(re.sub(r"\D", "", p))
        f["duplicate_review_phones"] = sorted(reviewed)
    except Exception as exc:
        f["duplicate_review_phones_error"] = str(exc)[:160]
    return f


# ---------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------

def _good():
    """A synthetic box on which every assertion holds. No real names or numbers."""
    return {
        "screens": {
            "home": {"nav": "Home", "title": "Home", "text":
                     "From the Editor\nNeeds you now\n2\nDATES\nJane Doe's birthday is in five days\nIn five days.\n"
                     "PEOPLE\nYou've gone quiet with John Doe\nLast spoke in March.\nFor you\n1\n"},
            "people": {"nav": "People", "title": "People", "text": "YOUR NETWORK\nPeople\n1,000 PEOPLE\n"},
            "governor": {"nav": "Governor", "title": "Governor", "text":
                         "Busy\nOther apps\n40%\nExampleEditor 30% · ExampleBrowser 10%\nPause background work\n"},
            "doctor": {"nav": "Doctor", "title": "Doctor", "text":
                       "CONNECTED SOURCES\n2\nBringing in your data\nCONNECTED SOURCES\nActive\niMessage\nStreaming\n"
                       "WhatsApp\nStreaming\nWHAT'S RUNNING\nMessages\nRunning\n"},
            "doctor_sources": {"rows": [["Email conversations", "Working"], ["WhatsApp conversations", "Working"]]},
            "bursar": {"nav": "Bursar", "title": "Bursar", "text": "October 2026\nMODEL CALLS\n1,234\nrates read on 15 Jan 2026\n"},
            "settings": {"nav": "Settings", "title": "Settings", "text": "Your timezone\nthe owner's time zone\n"},
            "timeline": {"nav": "Timeline", "title": "Timeline", "text": "Today\nEVENT\nOffsite \u2014 day one\n1 OCT\n"},
        },
        "requests": [{"m": "GET", "u": "/api/status", "s": 200}],
        "bearer_in_url": 0,
        "feed": [{"kind": "interest", "action_kind": "strengthen", "has_interest_id": True},
                 {"kind": "signal", "action_kind": None, "has_interest_id": False}],
        "timeline_titles": ["WhatsApp with Jane Doe", "Lunch with John Doe", "Offsite \u2014 day one"],
        "timeline_rows": [{"kind": "message", "title": "WhatsApp with Jane Doe"},
                          {"kind": "meeting", "title": "Lunch with John Doe"},
                          {"kind": "event", "title": "Offsite \u2014 day one"}],
        "people_rows": ["Jane Doe\n+44 7700 900001", "John Doe\n+" + "1 555 0100 222"],
        "duplicate_review_phones": [],
        "wiki": {"pages": {
            "front": {"text": "Your Front Page\nNeeds you now\n2\nDATES\n\nJane Doe's birthday is in five days\n\n"
                              "PEOPLE\nYou've gone quiet with John Doe\nFor you\n1,000\nPEOPLE\n50\nORGANISATIONS\n",
                      "sources": [["Mail", "Up to date · 1 hour ago"], ["WhatsApp", "Up to date · 1 hour ago"],
                                  ["Contacts", "Up to date · 1 hour ago"]],
                      "freshness": ["Mail", "WhatsApp", "Contacts"],
                      "boxes": [{"what": "table", "label": "Data freshness", "w": 900, "aw": 912}]},
            "people": {"text": "People\n1,000 people, from your address book and conversations.\n", "boxes": []},
            "organisations": {"text": "Organisations\n50\nORGANISATIONS\n", "boxes": []},
        }},
        "api": {"sources": [["email", "ok"], ["whatsapp", "ok"], ["contacts", "ok"], ["people", "ok"]],
                "config_as_app": 200},
        "box": {"ollama_calls": 1000, "journal_rows": 990, "window_min": 60},
    }


def _set(path, value):
    def m(f):
        o = f
        for k in path[:-1]:
            o = o[k]
        o[path[-1]] = value
    return m


def _app(path, value):
    def m(f):
        o = f
        for k in path:
            o = o[k]
        o.append(value)
    return m


def _txt(path, add):
    def m(f):
        o = f
        for k in path[:-1]:
            o = o[k]
        o[path[-1]] = o[path[-1]] + add
    return m


# One mutant per defect class, each the v1.0.106 shape, synthetic values.
MUTANTS = [
    ("ISO date on a card (#2534, #2550)", _txt(["screens", "home", "text"], "last seen 2026-01-15\n")),
    ("em dash on a wiki page (#2550)", _txt(["wiki", "pages", "front", "text"], "spans 5 years — from 2021\n")),
    ("Ostler placeholder dash on People (#2562)", _txt(["screens", "people", "text"], "Jane Doe\n\u2014\n")),
    ("Ostler placeholder dash on the SAME Timeline screen as an exempt title (#2562)",
     _txt(["screens", "timeline", "text"], "EVENT\nUntitled\n\u2014\n")),
    ("Ostler label dash beside the exempt title on the Timeline (#2562)",
     _txt(["screens", "timeline", "text"], "1 OCT \u2014 Offsite \u2014 day one\n")),
    ("a dashed title on a NON-event Timeline row is not exempt",
     lambda f: (f["timeline_rows"].append({"kind": "message", "title": "Chat \u2014 recap"}),
                f["screens"]["timeline"].__setitem__("text", f["screens"]["timeline"]["text"] + "Chat \u2014 recap\n"))),
    ("L2 badge and strength score (#2534)", _txt(["screens", "home", "text"], "L2\nfrom linkedin · strength 0.50\n")),
    ("store names on the System page (#2548)", _txt(["wiki", "pages", "people", "text"], "Qdrant collections\n")),
    ("snake_case key on the front page (#2549)", _txt(["wiki", "pages", "front", "text"], "tv_show\t100\n")),
    ("internal component id (#2539)", _txt(["screens", "doctor", "text"], "channel:imessage\n")),
    ("Settings page titled Home (#2540)", _set(["screens", "settings", "title"], "Home")),
    ("a screen GET 404s (#2554)", _app(["requests"], {"m": "GET", "u": "/api/sessions/<id>/state", "s": 404})),
    ("bearer in a URL (#2558)", _set(["bearer_in_url"], 2)),
    ("'In five days away' (#2535)", _txt(["screens", "home", "text"], "In 10 days away.\n")),
    ("feedback card with no interest_id (#2467)", _app(["feed"], {"kind": "interest", "action_kind": "strengthen", "has_interest_id": False})),
    ("app and wiki Needs you now differ (#2537)", _set(["wiki", "pages", "front", "text"],
        "Needs you now\n1\nDUPLICATE\nTwo records for Jane Doe?\nFor you\n1,000\nPEOPLE\n50\nORGANISATIONS\n")),
    ("Ostler VM under Other apps (#2538)", _set(["screens", "governor", "text"],
                                               "Other apps\n120%\ncom.apple.Virtualization.VirtualMachine 90% · llama-server 30%\nPause\n")),
    ("connected 15, listed 2 (#2539)", _set(["screens", "doctor", "text"],
                                            "CONNECTED SOURCES\n15\nx\nActive\niMessage\nStreaming\nWhatsApp\nStreaming\nWHAT'S RUNNING\n")),
    ("Conversation conversation (#2542)", _app(["timeline_titles"], "Conversation conversation")),
    ("bare channel conversation title (#2542)", _app(["timeline_titles"], "iMessage conversation")),
    ("WhatsApp LID as a phone (#2543)", _app(["people_rows"], "Unknown contact\n+" + "1" + "0" * 13 + "1")),
    ("bidi control in a phone (#2543)", _app(["people_rows"], "Jane Doe\n+44‭ 7700 900003")),
    ("one phone on two rows (#2545)", _app(["people_rows"], "Unknown contact\n+44 7700 900001")),
    ("People index count 40% low (#2546)", _set(["wiki", "pages", "people", "text"], "600 contacts in the graph\n")),
    ("org counts differ (#2547)", _set(["wiki", "pages", "organisations", "text"], "60\nORGANISATIONS\n")),
    ("Mail listed twice (#2533)", _app(["wiki", "pages", "front", "sources"], ["Mail messages", "Nothing found to read yet"])),
    ("Privacy labelling as a source (#2533)", _app(["wiki", "pages", "front", "sources"], ["Privacy labelling", "Up to date"])),
    ("Doctor tab Working, box no_data (#2526)", _set(["api", "sources"], [["email", "no_data"], ["whatsapp", "ok"], ["contacts", "ok"]])),
    ("Data freshness lists 3 of N (#2551)", _set(["wiki", "pages", "front", "freshness"], ["Meetings"])),
    ("half-width table (#2551, #2548)", _app(["wiki", "pages", "front", "boxes"], {"what": "table", "label": "RDF Types", "w": 222, "aw": 912})),
    ("config 403 from the app (#2552)", _set(["api", "config_as_app"], 403)),
    ("Bursar records 62% of Ollama calls (#2472)", _set(["box", "journal_rows"], 620)),
]


# Each mutant must be caught by the assertion written for it, not incidentally by another.
MUTANT_TARGETS = dict(zip([n for n, _ in MUTANTS], [0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 11, 12, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22]))


def self_test():
    import copy
    base = judge(_good())
    bad = [(n, d) for n, ok, d in base if ok is not True and ok != NA]
    if bad:
        print("SELF-TEST BROKEN: the good fixture fails: " + "; ".join("{} ({})".format(n, d) for n, d in bad))
        return EX_FAIL
    print("  ok    good fixture: {} assertions, all pass".format(len(base)))
    missed = []
    for name, mutate in MUTANTS:
        f = copy.deepcopy(_good())
        mutate(f)
        rows = judge(f)
        want = DECLARED[MUTANT_TARGETS[name]]
        if [ok for n, ok, _ in rows if n == want] != [False]:
            missed.append(name + " (by its own assertion: " + want + ")")
        else:
            print("  ok    mutant caught: {}  [by: {}]".format(name, want))
    # CM051 walk-probe fix (v1.0.107): a shared landline the customer can
    # already see on their own Doctor "tidy your contacts" page must PASS; a
    # duplicate absent from that surface -- silent -- must still FAIL. Two
    # dedicated fixtures, not folded into the MUTANTS list above, because a
    # mutant's whole contract is "must be caught"; the first of these two
    # must NOT be.
    want13 = DECLARED[13]

    shared_landline = copy.deepcopy(_good())
    shared_landline["people_rows"].append("Jane Doe\n+44 7700 900009")
    shared_landline["people_rows"].append("John Doe\n+44 7700 900009")
    shared_landline["duplicate_review_phones"] = ["447700900009"]
    rows = judge(shared_landline)
    got13 = [ok for n, ok, _ in rows if n == want13]
    if got13 != [True]:
        missed.append("a shared landline recorded on the duplicate-review surface "
                       "still fails ({!r}, want [True])".format(got13))
    else:
        print("  ok    a shared landline surfaced as a duplicate-review card PASSES")

    silent_duplicate = copy.deepcopy(_good())
    silent_duplicate["people_rows"].append("Jane Doe\n+44 7700 900008")
    silent_duplicate["people_rows"].append("John Doe\n+44 7700 900008")
    # duplicate_review_phones stays [] -- this number was never surfaced anywhere.
    rows = judge(silent_duplicate)
    got13 = [ok for n, ok, _ in rows if n == want13]
    if got13 != [False]:
        missed.append("a silent duplicate (not on the duplicate-review surface) "
                       "does not fail ({!r}, want [False])".format(got13))
    else:
        print("  ok    a silent duplicate, absent from the duplicate-review surface, FAILS")

    # The collector could not read /api/v1/contacts/diff at all: a real
    # duplicate must read CANNOT-RUN, never a silent pass -- a transport
    # failure must not masquerade as "nothing to review".
    unmeasured_reviewed = copy.deepcopy(_good())
    unmeasured_reviewed["people_rows"].append("Jane Doe\n+44 7700 900008")
    unmeasured_reviewed["people_rows"].append("John Doe\n+44 7700 900008")
    del unmeasured_reviewed["duplicate_review_phones"]
    unmeasured_reviewed["duplicate_review_phones_error"] = "simulated transport failure"
    rows = judge(unmeasured_reviewed)
    got13 = [ok for n, ok, _ in rows if n == want13]
    if got13 != [None]:
        missed.append("a duplicate with the review surface unreadable does not read "
                       "CANNOT-RUN ({!r}, want [None])".format(got13))
    else:
        print("  ok    a duplicate with the review surface unreadable is CANNOT-RUN, never a pass")

    # an empty collection must not pass: every assertion CANNOT, and the count row fails
    empty = judge({})
    if any(ok is True for n, ok, _ in empty if not n.startswith("customer read:")):
        missed.append("an empty collection reads as a pass")
    else:
        print("  ok    an empty collection is CANNOT-RUN, never a pass")
    # a judge that drops a declared assertion must fail its own count row
    cnt = [ok for n, ok, _ in judge(_good(), DECLARED + ["a declared assertion nobody emits"])
           if n.startswith("customer read:")]
    if cnt != [False]:
        missed.append("a declared but silent assertion is not caught")
    else:
        print("  ok    a declared assertion that prints no row FAILS")
    if missed:
        print("SELF-TEST FAIL: not caught: " + "; ".join(missed))
        return EX_FAIL
    print("SELF-TEST PASS: good fixture passes, {} of {} mutants caught".format(len(MUTANTS), len(MUTANTS)))
    return EX_PASS


def report(rows):
    for name, ok, detail in rows:
        tag = "  N/A   " if ok == NA else ("  ok    " if ok is True else ("  CANNOT " if ok is None else "  FAIL  "))
        print(tag + name + ("" if ok is True or not detail else "  -- " + detail))
    fails = [n for n, ok, _ in rows if ok is False]
    cannot = [n for n, ok, _ in rows if ok is None]
    print("EXAMINED: {} customer-read assertions ({} failed, {} not measured)".format(len(rows), len(fails), len(cannot)))
    if not rows:
        return EX_FAIL
    return EX_FAIL if fails else (EX_CANNOT if cannot else EX_PASS)


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] == ["judge"]:
        return report(judge(json.load(open(argv[1]))))
    if argv[:1] == ["collect"]:
        a = dict(zip(argv[1::2], argv[2::2]))
        try:
            token = open(a["--token-file"]).read().strip()
        except Exception as exc:
            print("CANNOT-RUN: token unreadable: {}".format(exc))
            return EX_CANNOT
        try:
            facts = collect(a["--base"], token, a.get("--doctor-base"), a.get("--front-page-json"), a["--out"])
        except ImportError as exc:
            print("CANNOT-RUN: no Playwright on this driver ({})".format(exc))
            return EX_CANNOT
        except Exception as exc:
            print("CANNOT-RUN: the browser did not complete the read ({})".format(str(exc)[:200]))
            return EX_CANNOT
        if a.get("--box-facts"):
            try:
                facts["box"] = json.load(open(a["--box-facts"]))
            except Exception as exc:
                facts["box_error"] = str(exc)[:160]
        if token and token in json.dumps(facts):
            print("CANNOT-RUN: the collected facts contain the device bearer; refusing to write them")
            return EX_CANNOT
        json.dump(facts, open(os.path.join(a["--out"], "customer_read.json"), "w"), indent=1)
        return report(judge(facts))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
