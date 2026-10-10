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
    # Not after "@": an account handle (@ann_lee) is the customer's own data, a
    # real identifier, and Ostler must not rewrite it (walk #10 review, CM044 #312).
    (re.compile(r"(?<![@\w.])[a-z]+_[a-z]+(?:_[a-z]+)*\b"), "snake_case key"),
    # Walk #16: raw YAML frontmatter leaked into customer text, both as an
    # inline fragment ("--- conversation_id: ...") and as a block of lowercase
    # "key: value" lines. Keys with no underscore ("date:", "title:", "source:")
    # slip past the snake_case rule, so these are their own patterns.
    (re.compile(r"(?:^|\s)---[ \t]*\n?[ \t]*[a-z][a-z0-9_]*:[ \t]"), "raw frontmatter"),
    (re.compile(r"(?m)^(?:[ \t]*[a-z][a-z0-9_]*:[ \t]+\S[^\n]*\n){2,}"), "raw frontmatter key block"),
    # Walk #16: internal provenance tags ("[pwg:src=...]") in customer text.
    (re.compile(r"\[pwg:[a-z_]+=[^\]]*\]"), "internal provenance tag"),
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
EMAIL = re.compile(r"[^\s@]+@[^\s@]+\.[A-Za-z]{2,}")
URL = re.compile(r"https?://\S+", re.I)
SERVICE_PHRASE = re.compile(
    r"\b(notifications?|no-?reply|do-?not-?reply|payments?|updates?|alerts?|receipts?|statements?|"
    r"newsletters?|rewards?|gifts?|offers?|verif(y|ication)|members?hip|accounts?|orders?|deliver(y|ies)|"
    r"subscriptions?|invoices?|promotions?|deals?|unsubscribe|via \w*sign)\b", re.I)
SERVICE_LOCAL = re.compile(
    r"^(no-?reply|noreply|do-?not-?reply|support|help(desk)?|team|info|news(letter)?|promo(tions?)?|"
    r"marketing|notifications?|alerts?|billing|sales|service|accounts?|orders?|ebill\w*)$", re.I)
MARKETPLACES = re.compile(
    r"\b(amazon|ebay|etsy|aliexpress|alibaba|shopee|lazada|taobao|tmall|rakuten|walmart|temu|shein|"
    r"zalando|asos|wish)\b", re.I)
DOMAIN_NAME = re.compile(r"^[\w-]+(\.[\w-]+)*\.(com|net|org|io|co|uk|hk|de|fr|shop|store)$", re.I)
# Walk #16 console, "customer eyes" (Andy): a People row named by a username,
# an id, a calendar address or digits is not a name a customer recognises.
# Measured on the walk #16 box (7,782 rows): 138 handles or ids, 5 calendar or
# invite ids, 2 rows with no letters, and the check that existed caught none.
# A name in decorative Unicode letters IS a name (isalpha counts it).
JUNK_HANDLE = re.compile(r"^(?=\S*\d)(?=\S*[A-Za-z])[A-Za-z0-9._]{4,20}$")
CALENDAR_ID = re.compile(r"@(group|resource)\.calendar\.google\.com$|@imip\.me\.com$", re.I)
ORG_NAME = re.compile(
    r"\b(ltd|limited|llc|inc|plc|gmbh|corp|corporation|bank|official|holdings|insurance|airways|"
    r"airlines?|hotels?|restaurant|clinic|hospital|university|college|school|foundation|association|"
    r"council|ministry|department)\b", re.I)
GONE_QUIET = re.compile(r"gone quiet|no contact for|not been in touch|haven.t (spoken|been in touch)", re.I)
QUIET_SPAN = re.compile(r"(\d[\d,]*)\s+(day|week|month|year)s?\b", re.I)
RAW_MONTHS = re.compile(r"\b(\d[\d,]*)\s+months?\b", re.I)


def _digest(v):
    import hashlib
    return hashlib.sha256(v.encode()).hexdigest()


def _norm_handle(h):
    h = (h or "").strip().lower()
    if "@" in h:
        return h
    d = re.sub(r"\D", "", h)
    return d[-9:] if len(d) >= 7 else ""


def _norm_name(n):
    return re.sub(r"\s+", " ", (n or "").strip().lower())


def _name_windows(text, lo=2, hi=4):
    w = re.findall(r"[^\W\d_][\w'.-]*", (text or "").lower())
    for k in range(lo, hi + 1):
        for i in range(0, max(0, len(w) - k + 1)):
            yield " ".join(w[i:i + k])


FRESH_STATUS = re.compile(r"^(Up to date|Nothing found|Not started|Working|Failed|Behind|Stale)", re.I)


def freshness_labels(section):
    """Source labels in the wiki's Data freshness section, from either shape:
    {kind: table, rows: [...]} or {kind: list, text: '<icon>\\n<label>\\n<status>...'}.
    None when the section is absent (NOT MEASURED), [] when it is present but empty."""
    if section is None:
        return None
    kind = section.get("kind")
    if kind == "table":
        return [r for r in section.get("rows") or [] if r]
    if kind != "list":
        return []
    lines = [x.strip() for x in (section.get("text") or "").splitlines() if x.strip()]
    out, i = [], 0
    while i < len(lines):
        if len(lines[i]) <= 2:            # the status icon
            i += 1
            continue
        if i + 1 < len(lines) and FRESH_STATUS.match(lines[i + 1]):
            out.append(lines[i])
            i += 2
            continue
        i += 1
    return out


CHIP_WORDS = {"private", "l0", "l1", "l2", "l3"}


def norm_title(t):
    """A card title compared across surfaces: case, curly quotes, punctuation
    and spacing differ between the app and the wiki and carry no meaning."""
    t = (t or "").replace("\u2019", "'").replace("\u2018", "'").lower()
    t = re.sub(r"[^\w' ]+", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def doctor_list_count(doc):
    """(tile, listed) from the Doctor health-tab text, or (tile, None) when the list
    is not there. Two shapes are read: the old 'Active' list of channel rows
    with a Streaming-style status, and the current list under a second
    CONNECTED SOURCES heading: an 'All' filter chip, then name/status pairs,
    ending at the next ALL-CAPS heading."""
    lines = [x.strip() for x in (doc or "").splitlines()]
    m = re.search(r"CONNECTED SOURCES\s*\n\s*(\d+)", doc or "")
    tile = int(m.group(1)) if m else None
    heads = [i for i, x in enumerate(lines) if x.upper() == "CONNECTED SOURCES"]
    if len(heads) >= 2:
        body = []
        for x in lines[heads[1] + 1:]:
            if not x:
                continue
            if len(x) > 3 and x.isupper() and x not in ("ALL",):
                break
            body.append(x)
        while body and body[0].lower() in ("all", "active"):
            body = body[1:]
        if body and len(body) % 2 == 0:
            return tile, len(body) // 2
    seg = _segment(doc, "Active", ["WHAT'S RUNNING", "DIAGNOSTICS"])
    if seg is not None:
        return tile, len([x for x in seg if re.fullmatch(r"Streaming|Connected|Idle|Paused|Offline|Error|Waiting", x)])
    return tile, None


def service_sender(name):
    """A People row name that is a service, organisation or subject line, not a person."""
    n = (name or "").strip()
    if not n:
        return None
    if n.startswith("#"):
        return "hash-prefixed"
    if "@" in n:
        local = n.split("@", 1)[0]
        if SERVICE_LOCAL.match(local) or MARKETPLACES.search(n):
            return "service mailbox"
        return None
    words = re.findall(r"[A-Za-z]+", n)
    if len(words) >= 2 and all(w.isupper() for w in words) and sum(len(w) for w in words) >= 4:
        return "all-caps multiword"
    if SERVICE_PHRASE.search(n):
        return "notification phrasing"
    if MARKETPLACES.search(n) or DOMAIN_NAME.match(n):
        return "marketplace or domain"
    if ORG_NAME.search(n):
        return "organisation name"
    return None


def junk_name(name):
    """A People row name a customer cannot read as a person's name (walk #16 console)."""
    n = (name or "").strip()
    if not n:
        return None
    if not any(ch.isalpha() for ch in n):
        return "no letters"
    if CALENDAR_ID.search(n):
        return "calendar or invite id"
    if JUNK_HANDLE.match(n):
        return "handle or id"
    return None


def _months(num, unit):
    v = float(str(num).replace(",", ""))
    return {"day": v / 30.44, "week": v / 4.35, "month": v, "year": v * 12}[unit.lower()]
# Emails and URLs carry underscores and ports legitimately; judge the prose around them.
STRIP_ADDRESSES = re.compile(r"\S+@\S+|https?://\S+|\S*\?\S*=\S*")


# Local calls never go through a proxy. The walk driver may carry HTTP_PROXY
# with no NO_PROXY (measured 2026-10-03 on a laptop running a local privacy
# proxy), and urllib then sends the forwarded 127.0.0.1 ports through it and
# reads back "503 Forwarding failure", which looks exactly like the product
# failing. Every HTTP call this probe makes is to a forwarded loopback port, so
# it uses an opener with no proxies at all, and refuses a non-loopback URL.
_LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1")


def _local_urlopen(req, timeout):
    import urllib.parse
    import urllib.request
    url = req.full_url if hasattr(req, "full_url") else req
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    if host not in _LOOPBACK_HOSTS:
        raise ValueError("not a loopback URL, refusing to bypass the proxy for it: host={}".format(host))
    return urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout)


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
        if want and x.strip().lower() in CHIP_WORDS:  # the app's privacy chip, not a title
            continue
        if want:
            titles.append(x)
            want = False
    return titles


def count_after(text, label):
    """'8,137 PEOPLE' or '8,138\\nPEOPLE' -> 8137. The LARGEST labelled count wins:
    a card band such as 'Needs you now 5 PEOPLE' also matches the shape, and the
    first draft read that card count as the people total (measured, walk #5)."""
    vals = [_num(m.group(1)) for m in re.finditer(r"([\d,]{1,9})\s*\n?\s*" + label + r"\b", text or "")]
    vals = [v for v in vals if v is not None]
    return max(vals) if vals else None


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
    "counts: each people count matches its own source (Hub = people-list API total; wiki tile = compiled People page)",
    "counts: organisations agree across the wiki front page and the Organisations page",
    "sources: the wiki source list has no duplicate source",
    "sources: no internal operation is listed as a source",
    "sources: the Doctor data sources tab agrees with /api/v1/sources",
    "sources: wiki Data freshness lists every source the box reports as working",
    "wiki: every table and box is at least 95% of the page width",
    "doctor: the Hub's own config read (as the app sends it) is accepted",
    "bursar: model calls recorded within 5% of Ollama's logged calls",
    "people: no row is named by an email address when a human-named row shares that address",
    "people: no service, organisation or subject-line sender is listed as a person",
    "people: the owner is not listed as a person, nor named in a you-keep-seeing card",
    "hub: the status pill never reads Status unavailable, on any route",
    "home/wiki: no gone-quiet card over 18 months, and no raw month count over 23",
    "customer text: no raw http(s) URL in customer copy",
    "wiki: every page linked from the nav was read (the text checks cover all of them)",
    "wiki: no date is set in the old monospace style, on any page",
    "people: no row is named by a handle, an id, a calendar address or digits",
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
    # Every nav-linked wiki page (walk #6: em dashes, raw keys and mono dates sat
    # on System sub-pages the front-page read never opened).
    crawl = (f.get("wiki") or {}).get("crawl") or {}
    texts += [("wiki page " + k, (v or {}).get("text") or "") for k, v in crawl.items()]
    # Text the wiki renders FROM the customer's data (a visited page's title),
    # recorded per page by CUSTOMER_TITLES_JS. Used only by the em dash check.
    cust_titles = {"wiki " + k: (v or {}).get("customer_titles") or [] for k, v in wiki.items()}
    cust_titles.update({"wiki page " + k: (v or {}).get("customer_titles") or [] for k, v in crawl.items()})
    # Hub screens too (walk #15): the marker was honoured on the wiki only, so a
    # contact's own LinkedIn title on Hub People counted as Ostler copy.
    cust_titles.update({"hub " + k: (v or {}).get("customer_titles") or [] for k, v in screens.items()})
    # Walk #16: a person's or organisation's NAME is contact-written by
    # definition (it comes from their card or their own messages), so a dash
    # inside it is the customer's data, not Ostler copy. Every name the people
    # API returned is exempt on the Hub People screen and on a person detail
    # screen, ONE occurrence per API row, so Ostler's own label beside it, or a
    # second copy of the same text, still counts.
    _people_names = [p.get("name") or "" for p in (f.get("people_api") or []) if p.get("name")]
    for k in screens:
        if k == "people" or k.startswith("person"):
            cust_titles["hub " + k] = list(cust_titles.get("hub " + k, [])) + _people_names
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
        # Wiki: each recorded customer title removes ONE occurrence of itself,
        # longest first, so a title cannot exempt a second copy of its text
        # and a dash in our own copy beside it still counts (walk #11).
        for title in sorted((x for x in cust_titles.get(where, []) if EM_DASH in x), key=len, reverse=True):
            t = t.replace(title, "", 1)
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
    # Titles come from each surface's own card markup when the collector read
    # it (app .fpc-card, wiki .pw-fcard); the text parse is the fallback. The
    # first draft took the first line after the category label, which in the
    # app is the privacy chip ("Private"), so every app title was the chip and
    # the two identical lists shared nothing (walk #6).
    a = f.get("needs_now_app") or f.get("needs_now_app_settled")
    if a is None and home:
        a = card_titles(_segment(home, "Needs you now", ["For you", "Getting set up"]))
    b = f.get("needs_now_wiki")
    if b is None and wfront:
        b = card_titles(_segment(wfront, "Needs you now", ["For you", "Getting set up"]))
    if not a or b is None:
        add(DECLARED[8], None, "NOT MEASURED: app={} wiki={}".format(bool(a), b is not None))
    else:
        na, nb = sorted(norm_title(x) for x in a), sorted(norm_title(x) for x in b)
        detail = "app has {} card(s), wiki has {}; {} in common".format(len(a), len(b), len(set(na) & set(nb)))
        if na == nb:
            add(DECLARED[8], True, detail)
        else:
            # Ruling 2026-10-04: a mismatch is tolerated ONLY when the feed is
            # newer than the wiki's last compile AND under 15 minutes old (the
            # #2633 recompile window). Every other mismatch FAILS, including one
            # where the times could not be read. The case is always named.
            fr = f.get("freshness") or {}
            fm, wm, now = fr.get("feed"), fr.get("wiki"), fr.get("now")
            if fm is None or wm is None or now is None:
                add(DECLARED[8], False, detail + "; FAIL: feed or wiki compile time unreadable, so no lag can be tolerated")
            elif fm > wm and now - fm <= 900:
                add(DECLARED[8], NA, detail + "; TOLERATED: the feed is {}s newer than the wiki compile and {}s old, "
                                              "inside the 15-minute recompile window".format(fm - wm, now - fm))
            elif fm <= wm:
                add(DECLARED[8], False, detail + "; FAIL: the wiki compiled {}s AFTER the feed, so it is not lag".format(wm - fm))
            else:
                add(DECLARED[8], False, detail + "; FAIL: the feed is newer than the wiki compile but {}s old, past "
                                                 "the 15-minute recompile window".format(now - fm))

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
        tile, listed = doctor_list_count(doc)
        if tile is None or listed is None:
            add(DECLARED[10], None, "NOT MEASURED: tile={} list={}".format(tile is not None, listed is not None))
        else:
            add(DECLARED[10], tile == listed, "tile says {}, list shows {}".format(tile, listed))

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

    # Ruling 2026-10-04 (#2546): each screen labels what it counts, so there is
    # no cross-equality. The Hub counts named people and must equal the
    # people-list API it renders; the wiki tile counts people with a page and
    # must equal the compiled People page. Each is checked against its own source.
    hub_n = count_after((screens.get("people") or {}).get("count_text")
                        or (screens.get("people") or {}).get("text"), "PEOPLE")
    api_n = f.get("people_api_total")
    if api_n is None and f.get("people_api") is not None:
        api_n = len(f["people_api"])
    tile_n = count_after(wfront, "PEOPLE")
    index_n = _num((re.search(r"([\d,]+) (?:contacts|people)\b",
                              (wiki.get("people") or {}).get("text") or "") or [None, None])[1])
    pairs = [("Hub vs people API", hub_n, api_n), ("wiki tile vs People page", tile_n, index_n)]
    measured_pairs = [(k, a, b) for k, a, b in pairs if a is not None and b is not None]
    if not measured_pairs:
        add(DECLARED[14], None, "NOT MEASURED: hub={} api={} tile={} index={}".format(hub_n, api_n, tile_n, index_n))
    else:
        bad = ["{} {} vs {}".format(k, a, b) for k, a, b in measured_pairs if a != b]
        unmeasured = [k for k, a, b in pairs if a is None or b is None]
        detail = "; ".join("{} {} vs {}".format(k, a, b) for k, a, b in measured_pairs)
        if f.get("people_read_gap_s") is not None:
            detail += "; Hub and API read {}s apart".format(f["people_read_gap_s"])
        if unmeasured:
            detail += "; not measured: " + ", ".join(unmeasured)
        add(DECLARED[14], (not bad) if not unmeasured else (False if bad else None), detail)
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
    oc, jr = bx.get("ollama_calls"), bx.get("journal_calls")
    if not oc:
        add(DECLARED[22], None if oc is None else NA, "NOT MEASURED: no Ollama call count" if oc is None else "Ollama logged no calls in the window")
    else:
        add(DECLARED[22], (jr or 0) >= 0.95 * oc,
            "{} recorded vs {} Ollama calls in {} min ({}%)".format(jr, oc, bx.get("window_min"), int(100 * (jr or 0) / oc)))

    # ---- walk #5 additions (all details are COUNTS or product copy; no person names) ----
    papi = f.get("people_api")
    if papi is None:
        add(DECLARED[23], None, "NOT MEASURED: the People list was not read from /api/v1/people")
        add(DECLARED[24], None, "NOT MEASURED: the People list was not read from /api/v1/people")
        add(DECLARED[31], None, "NOT MEASURED: the People list was not read from /api/v1/people")
    else:
        human_by_email = {}
        for r in papi:
            nm, em = (r.get("name") or "").strip(), (r.get("email") or "").strip().lower()
            if em and nm and "@" not in nm:
                human_by_email.setdefault(em, True)
        email_named = [r for r in papi if EMAIL.fullmatch((r.get("name") or "").strip())]
        shadowed = [r for r in email_named
                    if (r.get("name") or "").strip().lower() in human_by_email
                    or ((r.get("email") or "").strip().lower() in human_by_email
                        and (r.get("email") or "").strip().lower() != "")]
        add(DECLARED[23], not shadowed,
            "{} of {} People rows are named by an email address while a human-named row shares that address "
            "({} email-named rows in all; names withheld)".format(len(shadowed), len(papi), len(email_named)))
        kinds = {}
        for r in papi:
            k = service_sender(r.get("name"))
            if k:
                kinds[k] = kinds.get(k, 0) + 1
        add(DECLARED[24], not kinds,
            "{} of {} People rows look like services, organisations or subject lines: {} (names withheld)".format(
                sum(kinds.values()), len(papi), ", ".join("{} {}".format(v, k) for k, v in sorted(kinds.items()))))
        junk = {}
        for r in papi:
            k = junk_name(r.get("name"))
            if k:
                junk[k] = junk.get(k, 0) + 1
        add(DECLARED[31], not junk,
            "{} of {} People rows are named by something a customer cannot read as a name: {} (names withheld)".format(
                sum(junk.values()), len(papi), ", ".join("{} {}".format(v, k) for k, v in sorted(junk.items()))))

    selfd = set(f.get("self_digests") or [])
    if f.get("owner_source") in ("synthetic", "unknown-walk"):
        add(DECLARED[25], None, "NOT MEASURED: {} -- the configured owner is not known to be the person whose "
                                "data is on this box".format(
                                    "the walk installed a SYNTHETIC owner (no owner identity file on the driver)"
                                    if f.get("owner_source") == "synthetic" else
                                    "this walk box predates the owner marker, so its owner is unknown"))
    elif not selfd or papi is None:
        add(DECLARED[25], None, "NOT MEASURED: {}".format(
            "the configured owner identity could not be read from the box" if not selfd else "the People list was not read"))
    else:
        own_rows = [r for r in papi
                    if _digest(_norm_handle(r.get("email"))) in selfd
                    or _digest(_norm_handle(r.get("name"))) in selfd
                    or _digest(_norm_name(r.get("name"))) in selfd]
        texts = [(screens.get("home") or {}).get("text") or "", (wiki.get("front") or {}).get("text") or ""]
        cards, in_cards = 0, 0
        for t in texts:
            for m in re.finditer(r"keep seeing", t, re.I):
                cards += 1
                seg = t[max(0, m.start() - 200): m.start() + 400]
                hits = [h for h in EMAIL.findall(seg) + re.findall(r"\+?\d[\d ]{6,}\d", seg)
                        if _digest(_norm_handle(h)) in selfd]
                if hits or any(_digest(w) in selfd for w in _name_windows(seg)):
                    in_cards += 1
        add(DECLARED[25], not own_rows and not in_cards,
            "owner listed as {} People row(s); named in {} of {} you-keep-seeing card(s) (names withheld)".format(
                len(own_rows), in_cards, cards))

    pills = []
    for k, v in screens.items():
        if not isinstance(v, dict):
            continue
        if v.get("header") is not None:
            pills.append(("app " + k, v["header"]))
        if v.get("header_browser") is not None:
            pills.append(("browser " + k, v["header_browser"]))
    if not pills:
        add(DECLARED[26], None, "NOT MEASURED: no route's header was read")
    else:
        bad = sorted(k for k, h in pills if re.search(r"status unavailable", h or "", re.I))
        add(DECLARED[26], not bad, "{} of {} route reads show Status unavailable: {}".format(len(bad), len(pills), ", ".join(bad)))

    quiet_texts = [("hub home", (screens.get("home") or {}).get("text") or ""),
                   ("wiki front", (wiki.get("front") or {}).get("text") or "")]
    if not any(t for _, t in quiet_texts) and not measured:
        add(DECLARED[27], None, "NOT MEASURED: neither Home nor the wiki front page was read")
    else:
        old_cards, raw = 0, 0
        for where, t in quiet_texts:
            for m in GONE_QUIET.finditer(t):
                seg = t[m.start(): m.start() + 300]
                spans = [_months(n, u) for n, u in QUIET_SPAN.findall(seg)]
                if spans and max(spans) > 18:
                    old_cards += 1
        for where, t in measured:
            raw += sum(1 for n in RAW_MONTHS.findall(t) if int(n.replace(",", "")) > 23)
        add(DECLARED[27], not old_cards and not raw,
            "{} gone-quiet card(s) over 18 months; {} raw month count(s) over 23".format(old_cards, raw))

    # Only VISIBLE raw "http(s)://" text fails. The texts here are innerText,
    # so a link the app renders as its domain (oa, walk #6) is not counted,
    # and the calendar-title exemption is no longer needed: a title whose URL
    # still shows raw is exactly what this checks.
    if not measured:
        add(DECLARED[28], None, "NOT MEASURED: no screen text was collected")
    else:
        bad = ["{}: {}".format(w, len(URL.findall(t))) for w, t in measured if URL.search(t)]
        add(DECLARED[28], not bad, "raw URLs, by screen: " + "; ".join(bad))

    # ---- every nav-linked wiki page ----
    links = (f.get("wiki") or {}).get("nav_links")
    if links is None:
        add(DECLARED[29], None, "NOT MEASURED: the wiki nav was not read")
        add(DECLARED[30], None, "NOT MEASURED: the wiki nav was not read")
    else:
        unread = sorted(set(links) - set(crawl))
        add(DECLARED[29], bool(links) and not unread,
            "{} of {} nav-linked pages read{}".format(len(set(links) & set(crawl)), len(set(links)),
                                                     "; unread: " + ", ".join(unread[:6]) if unread else ""))
        mono = {k: v.get("mono_dates") or 0 for k, v in crawl.items()}
        for k, v in wiki.items():
            if v and v.get("mono_dates"):
                mono["section " + k] = v["mono_dates"]
        badm = sorted((k, n) for k, n in mono.items() if n)
        add(DECLARED[30], not badm, "{} page(s) with monospace dates: {}".format(
            len(badm), "; ".join("{} ({})".format(k, n) for k, n in badm[:8])))

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
# Card titles in the "Needs you now" band, read from each surface's own card
# markup: every card after the band heading and before the next band heading.
NEEDS_NOW_JS = r"""(arg) => {
  const [cardSel, titleSel] = arg;
  const band = e => { const t = (e.innerText || '').trim();
    return t.length < 40 && /^(needs you now|for you|getting set up|your world at a glance)\b/i.test(t); };
  const heads = [...document.querySelectorAll('*')].filter(band);
  const now = heads.find(h => /^needs you now/i.test(h.innerText.trim()));
  if (!now) return null;
  const F = Node.DOCUMENT_POSITION_FOLLOWING;
  const next = heads.find(h => !/^needs you now/i.test(h.innerText.trim()) && (now.compareDocumentPosition(h) & F));
  return [...document.querySelectorAll(cardSel)]
    .filter(c => (now.compareDocumentPosition(c) & F) && (!next || (c.compareDocumentPosition(next) & F)))
    .map(c => { const t = c.querySelector(titleSel); return t ? t.innerText.trim() : ''; })
    .filter(Boolean);
}"""

# Text the wiki shows that is the customer's data, never Ostler copy, so the
# judge removes each string once before counting em dashes. Two sources:
#
# 1. THE MARKER (cut #13). CM044 compiler/customer_text.py wraps every customer
#    value it prints (a bookmarked or visited page title, a calendar event, a
#    note title, a preference subject, a media title) in an element carrying
#    data-ostler-customer, and wraps only the value. Walk #12 failed because
#    the Trends "New discoveries" row printed a bookmark title as plain text
#    and the link rule below could not see it. Only the OUTERMOST marked
#    element counts (a nested one would exempt the same text twice), and a
#    marked element that is a heading or holds one is IGNORED: headings are
#    Ostler's page structure, so a marker there must not hide a dash.
# 2. THE LINK RULE (#2710, kept for a wiki older than the marker). An <a>
#    inside the article whose href is http(s) to a host other than the wiki's
#    own and other than Ostler's, whose only child is text, and which is not
#    already inside a marked element.
CUSTOMER_TITLES_JS = r"""() => {
  const root = document.querySelector('article') || document.body;
  const ours = /(^|\.)(ostler\.ai|creativemachines\.ai)$/i;
  const MARK = '[data-ostler-customer]', HEAD = 'h1,h2,h3,h4,h5,h6';
  const marked = [...root.querySelectorAll(MARK)].filter(e =>
      !(e.parentElement && e.parentElement.closest(MARK)) && !e.matches(HEAD) && !e.querySelector(HEAD));
  const links = [...root.querySelectorAll('a[href]')].filter(a => !a.closest(MARK)
      && /^https?:$/.test(a.protocol) && a.hostname && a.hostname !== location.hostname
      && !ours.test(a.hostname) && a.children.length === 0);
  return [...marked, ...links].map(e => e.innerText).filter(t => t && t.trim()); }"""

# Leaf elements set in a monospace face whose text is a date (the old mono
# styling the reskin removed). Counted per page; the text is not kept.
MONO_DATES_JS = r"""() => {
  const art = document.querySelector('article') || document.body;
  const date = /\b(\d{4}-\d{2}-\d{2}|\d{1,2} (jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*( \d{4})?|(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* \d{4})\b/i;
  return [...art.querySelectorAll('*')].filter(e => e.children.length === 0 && date.test(e.innerText || '')
    && /mono|courier|menlo|consolas/i.test(getComputedStyle(e).fontFamily)).length;
}"""

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


def collect(base, token, doctor_base, feed_path, out_dir, wiki_wait_s=180, self_handles=None):
    import urllib.request
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
            s["header"] = page.evaluate("() => { const h = document.querySelector('header'); return h ? h.innerText : null }")
            s["text"] = page.evaluate("() => { const m = document.querySelector('main'); return m ? m.innerText : '' }")
            # Customer-written text the Hub marks (data-ostler-customer, oa #487:
            # a contact's own job title on People). Same collector as the wiki.
            s["customer_titles"] = page.evaluate(CUSTOMER_TITLES_JS) or []
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
            if name == "home":
                f["needs_now_app"] = page.evaluate(NEEDS_NOW_JS, [".fpc-card", "h3,h4,[class*='title']"])
            if name == "people":
                # The Hub's count and the API total it renders are read BACK TO
                # BACK in this one step, nothing between them, so a person added
                # while the probe crawled the wiki cannot make two honest numbers
                # disagree (7869 vs 7870 on the walk box, Archie 2026-10-05).
                # The comparison stays exact: no tolerance.
                t0 = time.time()
                f["screens"]["people"]["count_text"] = page.evaluate(
                    "() => { const m = document.querySelector('main'); return m ? m.innerText : '' }")
                try:
                    preq = urllib.request.Request(base + "/api/v1/people", headers={"Authorization": "Bearer " + token})
                    with _local_urlopen(preq, timeout=60) as r:
                        body = json.load(r)
                    f["people_api"] = [{"name": p.get("name") or "", "email": p.get("email") or ""}
                                       for p in body.get("people") or []]
                    f["people_api_total"] = body.get("total", len(f["people_api"]))
                except Exception as exc:
                    f["people_api_error"] = str(exc)[:160]
                f["people_read_gap_s"] = round(time.time() - t0, 2)
                f["people_rows"] = page.evaluate("() => Array.from(document.querySelectorAll('[data-person-row]')).map(e => e.innerText)")
            if name == "doctor":
                tab = page.locator("button", has_text="Data sources")
                if tab.count():
                    tab.first.click()
                    time.sleep(5)
                    rows = page.evaluate("() => Array.from(document.querySelectorAll('main table tr')).map(tr => Array.from(tr.querySelectorAll('td')).map(td => td.innerText.trim()))")
                    f["screens"]["doctor_sources"] = {"rows": [[r[0], r[-1]] for r in rows if len(r) >= 2]}
                    page.screenshot(path=os.path.join(out_dir, "cr-doctor-sources.png"))

        # wiki, read THROUGH the app's own frame, exactly as hub_screens does it.
        # The pages above route the Doctor-port calls to the forwarded Doctor,
        # which is what Ostler.app does; with that routing, the app's hydration
        # gate (#2496) can hold the wiki frame back on a box still hydrating.
        # Record what the app-faithful page shows, then read the wiki from a
        # page set up like hub_screens (no Doctor routing), which renders the
        # frame. There is NO token-URL fallback any more (#2558): since oa #444
        # a ?token= navigation is refused, and a probe must never put the bearer
        # in a URL. No frame is a CANNOT-RUN for the wiki arms, never a guess.
        go("/wiki")
        f["wiki"]["app_view_frame"] = bool(next((x for x in page.frames if "/wiki/" in (x.url or "")), None))
        wpage = ctx.new_page()
        wpage.set_viewport_size({"width": 1440, "height": 944})   # frame = 1440 - 240 sidebar, the app width
        # Waits on this page use wpage.wait_for_timeout, never time.sleep: the sync
        # Playwright API only processes browser events (frame attach, route
        # handlers) while a Playwright call is running, so a time.sleep loop
        # reads a frames list that never updates. That, not hydration, is why
        # the in-app wiki frame was never found.
        # No catch-all route on this page: a WebKit route on every request breaks
        # the wiki iframe's 303 hand-off to /wiki/s/<session>/ (it is why the
        # frame was never found). Writes are still refused: only API calls are
        # routed, and a non-GET there is aborted.
        wpage.route("**/api/**", lambda route, request: route.abort()
                    if request.method not in ("GET", "HEAD", "OPTIONS") else route.continue_())
        wpage.on("request", lambda r: saw(r.url))
        wpage.on("websocket", lambda ws: saw(ws.url))
        wpage.goto(base + "/", wait_until="domcontentloaded", timeout=60000)
        wpage.wait_for_selector('a[href="/wiki"]', timeout=180000)
        # The same routes as a customer opening the Hub in a browser (#2514):
        # read each route's header, where the status pill lives.
        for path, name in HUB_ROUTES:
            try:
                lk = wpage.locator('a[href="%s"]' % path)
                if lk.count():
                    lk.first.click()
                wpage.wait_for_timeout(6000)
                f["screens"].setdefault(name, {})["header_browser"] = wpage.evaluate(
                    "() => { const h = document.querySelector('header'); return h ? h.innerText : null }")
            except Exception as exc:
                f["wiki"].setdefault("errors", []).append("browser header {}: {}".format(name, str(exc)[:120]))
        # The app's Home cards, read on this page too: the app-emulated page can
        # sit on the first-run Home (no cards) while the box is still hydrating.
        if feed_json is not None:
            try:
                wpage.evaluate("""feed => { window.__TAURI_INTERNALS__ = { invoke: async (cmd) => {
                    if (cmd === 'get_front_page') return {available: true, feed: feed};
                    if (cmd.startsWith('get_')) return null;
                    throw new Error('read-only probe refuses ' + cmd); }, transformCallback: () => 0 }; }""", feed_json)
                wpage.locator('a[href="/people"]').first.click()
                wpage.wait_for_timeout(3000)
                wpage.locator('a[href="/"]').first.click()
                wpage.wait_for_timeout(8000)
                f["needs_now_app_settled"] = wpage.evaluate(NEEDS_NOW_JS, [".fpc-card", "h3,h4,[class*='title']"])
            except Exception as exc:
                f["wiki"].setdefault("errors", []).append("settled home: {}".format(str(exc)[:120]))
        wpage.locator('a[href="/wiki"]').first.click()
        fr, t0 = None, time.time()
        try:
            wpage.wait_for_selector("iframe", timeout=wiki_wait_s * 1000)
        except Exception:
            pass
        while time.time() - t0 < wiki_wait_s:
            fr = next((x for x in wpage.frames if "/wiki/" in (x.url or "")), None)
            if fr:
                break
            wpage.wait_for_timeout(1000)
        if fr is None:
            f["wiki"]["error"] = "no wiki frame inside the app within {}s".format(wiki_wait_s)
        if fr is not None:
            fr.wait_for_load_state("load", timeout=60000)
            wbase = re.match(r"(.*/wiki/s/[^/]+/)", fr.url)
            wbase = wbase.group(1) if wbase else fr.url.split("?")[0]
            for name, rel in WIKI_SECTIONS.items():
                try:
                    fr.goto(wbase + rel, wait_until="load", timeout=60000)
                    fr.page.wait_for_timeout(2000)
                    pg = {"text": fr.evaluate("() => { const a = document.querySelector('article') || document.body; return a.innerText }"),
                          "boxes": fr.evaluate(WIDTH_JS) or [],
                          "customer_titles": fr.evaluate(CUSTOMER_TITLES_JS) or []}
                    if name == "front":
                        f["needs_now_wiki"] = fr.evaluate(NEEDS_NOW_JS, [".pw-fcard", "h3,h4,strong,[class*='title']"])
                        # The list directly under the heading, and only that list: the
                        # first draft took the heading's parent box, which also held a
                        # second copy of the same labels elsewhere on the page and read
                        # every source as listed twice.
                        pg["sources"] = fr.evaluate(r"""() => {
                          const lines = (document.querySelector('article') || document.body).innerText
                            .split('\n').map(s => s.trim()).filter(Boolean);
                          const at = lines.findIndex(l => /where your information is coming from/i.test(l));
                          if (at < 0) return null;
                          const st = /^(Up to date|Nothing found|Not started|Working|Failed)/i;
                          const out = []; let i = at + 1;
                          while (i < lines.length) {
                            if (lines[i].length <= 2) { i++; continue; }          // the status icon
                            if (i + 1 < lines.length && st.test(lines[i + 1])) { out.push([lines[i], lines[i + 1]]); i += 2; continue; }
                            break;                                                 // left the list
                          }
                          return out; }""")
                        # The section's own content, whatever its shape. It was a table
                        # (v1.0.106); CM044 now renders it as a .pwg-freshness-box list.
                        # The first draft only looked for a table, walked past the list
                        # into the next section, and reported every source missing
                        # (walk #5 finding 3). Parsed in Python by freshness_labels().
                        pg["freshness"] = freshness_labels(fr.evaluate(r"""() => {
                          const h = [...document.querySelectorAll('h2,h3')].find(e => /data freshness/i.test(e.innerText || ''));
                          if (!h) return null;
                          const t = h.nextElementSibling;
                          if (!t || /^H[1-4]$/.test(t.tagName)) return {kind: 'empty'};
                          const tb = t.tagName === 'TABLE' ? t : t.querySelector('table');
                          if (tb) return {kind: 'table', rows: Array.from(tb.querySelectorAll('tbody tr')).map(tr => tr.cells[0].innerText.trim())};
                          return {kind: 'list', text: t.innerText}; }"""))
                    pg["mono_dates"] = fr.evaluate(MONO_DATES_JS)
                    f["wiki"]["pages"][name] = pg
                    wpage.screenshot(path=os.path.join(out_dir, "cr-wiki-%s.png" % name))
                except Exception as exc:
                    f["wiki"].setdefault("errors", []).append("{}: {}".format(name, str(exc)[:160]))
            # Every page the 7 nav sections link to, through the same frame.
            try:
                fr.goto(wbase, wait_until="load", timeout=60000)
                fr.page.wait_for_timeout(1500)
                hrefs = fr.evaluate("""() => [...document.querySelectorAll('.md-nav a.md-nav__link, .md-tabs a')]
                    .map(a => a.href).filter(h => h && !h.includes('#'))""")
                rels = []
                for h in hrefs:
                    rel = h.split("/wiki/s/", 1)[-1].split("/", 1)[-1] if "/wiki/s/" in h else None
                    if rel is not None and rel not in rels:
                        rels.append(rel)
                f["wiki"]["nav_links"] = rels
                crawl = {}
                for rel in rels:
                    try:
                        fr.goto(wbase + rel, wait_until="load", timeout=60000)
                        fr.page.wait_for_timeout(1200)
                        crawl[rel or "(front)"] = {
                            "text": fr.evaluate("() => { const a = document.querySelector('article') || document.body; return a.innerText }"),
                            "mono_dates": fr.evaluate(MONO_DATES_JS),
                            "customer_titles": fr.evaluate(CUSTOMER_TITLES_JS) or []}
                    except Exception as exc:
                        f["wiki"].setdefault("errors", []).append("crawl {}: {}".format(rel, str(exc)[:120]))
                f["wiki"]["nav_links"] = [r or "(front)" for r in rels]
                f["wiki"]["crawl"] = crawl
            except Exception as exc:
                f["wiki"].setdefault("errors", []).append("crawl: {}".format(str(exc)[:160]))
        browser.close()

    # GETs the app makes, sent the way the app sends them (read-only)
    import urllib.request
    if self_handles:
        names, handles = [], []
        for x in self_handles:
            (handles if ("@" in x or re.search(r"\d{6,}", x)) else names).append(x)
        try:
            req = urllib.request.Request(base + "/api/identity", headers={"Authorization": "Bearer " + token})
            with _local_urlopen(req, timeout=20) as r:
                first = (json.load(r).get("user_first_name") or "").strip()
        except Exception:
            first = ""
        full = [_norm_name(n) for n in names if len(_norm_name(n).split()) >= 2]
        if first:
            full += [_norm_name(first + " " + n.split()[-1]) for n in full]
        f["self_digests"] = sorted({_digest(h) for h in (_norm_handle(x) for x in handles) if h}
                                   | {_digest(n) for n in full})
    if doctor_base:
        try:
            with _local_urlopen(doctor_base + "/api/v1/sources", timeout=20) as r:
                f["api"]["sources"] = [[s.get("source"), s.get("status")] for s in json.load(r).get("sources") or []]
        except Exception as exc:
            f["api"]["sources_error"] = str(exc)[:160]
        req = urllib.request.Request(doctor_base + "/api/v1/config", headers={
            "Authorization": "Bearer " + token, "Origin": "tauri://localhost", "Sec-Fetch-Site": "cross-site"})
        try:
            with _local_urlopen(req, timeout=20) as r:
                f["api"]["config_as_app"] = r.status
        except urllib.error.HTTPError as exc:
            f["api"]["config_as_app"] = exc.code
        except Exception as exc:
            f["api"]["config_error"] = str(exc)[:160]

        # CM051 walk-probe fix (v1.0.107, corrected walk #2): DECLARED[13]
        # ("no phone number appears on two rows") used to fail a shared
        # landline between two distinct real people exactly as hard as a
        # silent duplicate-contact-card defect, with no way to tell them
        # apart from the People page alone. Read the SAME duplicate-review
        # surface the customer's own Doctor "tidy your contacts" tab renders
        # -- /api/v1/contacts/diff (identity_resolver.tidy.TidyEngine,
        # read-only, writes nothing) -- and extract ONLY the bare digits of
        # any phone_match pair's number, discarding the surrounding evidence
        # text immediately: `details` holds a readable "Shared phone:
        # <number> (names agree)" string, which must never survive into the
        # walk artefact. A pair that shows up here (propose_merge OR review
        # -- both are customer-visible cards; review is also exactly what
        # CM051 #2604 routes a RULE-2-refused auto-merge into) is a number
        # the customer can already see is shared and can already act on,
        # which is not the same defect as a number nobody was ever told
        # about.
        #
        # THIS MUST GO THROUGH doctor_base, NOT base. Walk #1 of this fix
        # used `base` (the Hub app, :8000) and 404'd every time -- measured
        # on macmini16-walk: :8000 404s this path, :8090 (ical-server, the
        # actual handler) answers 200. doctor_base is the Doctor's own
        # FastAPI app (:8089, same as the /api/v1/sources and /api/v1/config
        # calls just above), which proxies /api/v1/contacts/diff through to
        # ical-server via DOCTOR_PROXY_PATHS (install.sh; CM051 walk #2 also
        # added this path to that list, since it was missing there too and
        # the Doctor UI itself could not have reached it either).
        try:
            req = urllib.request.Request(doctor_base + "/api/v1/contacts/diff", headers={
                "Authorization": "Bearer " + token})
            with _local_urlopen(req, timeout=180) as r:
                diff = json.load(r)
            # CM051 walk #3, item E: do NOT filter by evidence["strategy"].
            # consolidate_matches keeps only the HIGHEST-confidence match per
            # pair, so a pair sharing both an email and a phone is filed
            # under whichever strategy scored higher -- measured on a cold
            # install, 34 of 104 phone-matched pairs were "won" by a
            # different strategy. The pair was already merged or listed for
            # review either way; filtering on strategy=="phone*" here just
            # meant this probe could not see it. identity_resolver.tidy now
            # records every OTHER strategy that also matched the same pair
            # in the winning item's own details text, so scanning ALL
            # items' text for a phone-shaped substring -- regardless of
            # which strategy nominally won -- finds it. This is also more
            # robust to a future strategy rename than matching the name.
            reviewed = set()
            for item in diff.get("items") or []:
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
            "home": {"nav": "Home", "title": "Home", "header": "Home\nBusy", "text":
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
            "timeline": {"nav": "Timeline", "title": "Timeline", "header": "Timeline\nBusy",
                         "text": "Today\nEVENT\nOffsite \u2014 day one\n1 OCT\nEVENT\nCheck in example.com\n"},
        },
        "requests": [{"m": "GET", "u": "/api/status", "s": 200}],
        "bearer_in_url": 0,
        "feed": [{"kind": "interest", "action_kind": "strengthen", "has_interest_id": True},
                 {"kind": "signal", "action_kind": None, "has_interest_id": False}],
        "timeline_titles": ["WhatsApp with Jane Doe", "Lunch with John Doe", "Offsite \u2014 day one"],
        "timeline_rows": [{"kind": "message", "title": "WhatsApp with Jane Doe"},
                          {"kind": "meeting", "title": "Lunch with John Doe"},
                          {"kind": "event", "title": "Offsite \u2014 day one"},
                          {"kind": "event", "title": "Check in https://example.com/checkin"}],
        "people_rows": ["Jane Doe\n+44 7700 900001", "John Doe\n+" + "1 555 0100 222"],
        "duplicate_review_phones": [],
        "wiki": {"nav_links": ["System/Declining/", "System/New-discoveries/", "System/Monthly-volume/"],
                 "crawl": {"System/Declining/": {"text": "Declining\nTopics you have engaged with less this year.\nFilms 12\n", "mono_dates": 0},
                           "System/New-discoveries/": {"text": "New discoveries\nFirst seen in March.\n", "mono_dates": 0},
                           "System/Monthly-volume/": {"text": "Monthly volume\nMarch 120\nApril 98\n", "mono_dates": 0}},
                 "pages": {
            "front": {"text": "Your Front Page\nNeeds you now\n2\nDATES\n\nJane Doe's birthday is in five days\n\n"
                              "3\nPEOPLE\n"
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
        "box": {"ollama_calls": 1000, "journal_calls": 990, "window_min": 60},
        "people_api_total": 1000,
        "people_api": [{"name": "Jane Doe", "email": "jane.doe@example.com"},
                       {"name": "John Doe", "email": "john.doe@example.com"},
                       {"name": "riley@example.org", "email": "riley@example.org"}],
        "self_digests": [_digest(_norm_handle("owner@example.net")), _digest(_norm_name("John Smith"))],
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
    ("raw frontmatter fragment in a conversation summary (walk #16)",
     _txt(["wiki", "pages", "front", "text"], "Catch up\n--- title: Catch up with Alexandra\n")),
    ("raw frontmatter key block on a page (walk #16)",
     _txt(["wiki", "pages", "front", "text"], "Catch up\ndate: 2030-01-01\nsource: whatsapp\nAgreed the plan.\n")),
    ("internal provenance tag in customer text (walk #16)",
     _txt(["screens", "home", "text"], "Jane Doe moved to Acme Corp [pwg:src=whatsapp]\n")),
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
    ("wiki tile disagrees with its own People page (#2546)", _set(["wiki", "pages", "people", "text"], "600 contacts in the graph\n")),
    ("Hub count disagrees with its own people API (#2546)", _set(["people_api_total"], 990)),
    ("org counts differ (#2547)", _set(["wiki", "pages", "organisations", "text"], "60\nORGANISATIONS\n")),
    ("Mail listed twice (#2533)", _app(["wiki", "pages", "front", "sources"], ["Mail messages", "Nothing found to read yet"])),
    ("Privacy labelling as a source (#2533)", _app(["wiki", "pages", "front", "sources"], ["Privacy labelling", "Up to date"])),
    ("Doctor tab Working, box no_data (#2526)", _set(["api", "sources"], [["email", "no_data"], ["whatsapp", "ok"], ["contacts", "ok"]])),
    ("Data freshness lists 3 of N (#2551)", _set(["wiki", "pages", "front", "freshness"], ["Meetings"])),
    ("half-width table (#2551, #2548)", _app(["wiki", "pages", "front", "boxes"], {"what": "table", "label": "RDF Types", "w": 222, "aw": 912})),
    ("config 403 from the app (#2552)", _set(["api", "config_as_app"], 403)),
    ("Bursar records 62% of Ollama calls (#2472)", _set(["box", "journal_calls"], 620)),
    ("an email-named row shadowing a human-named row (walk #5 a)",
     _app(["people_api"], {"name": "jane.doe@example.com", "email": "jane.doe@example.com"})),
    ("hash-prefixed SMS sender as a person (walk #5 b)", _app(["people_api"], {"name": "#EXAMPLEBANK", "email": ""})),
    ("all-caps multiword sender as a person (walk #5 b)", _app(["people_api"], {"name": "EXAMPLE BANK ALERTS", "email": ""})),
    ("subject-line phrasing as a person (walk #5 b)", _app(["people_api"], {"name": "Your rewards update", "email": ""})),
    ("marketplace domain as a person (walk #5 b)", _app(["people_api"], {"name": "examplemart.com", "email": ""})),
    ("the owner listed in People by handle (walk #5 c)", _app(["people_api"], {"name": "O. Example", "email": "owner@example.net"})),
    ("the owner listed in People by name only (walk #5 c)", _app(["people_api"], {"name": "John  Smith", "email": ""})),
    ("the owner in a you-keep-seeing card (walk #5 c)",
     _txt(["screens", "home", "text"], "PEOPLE\nYou keep seeing owner@example.net\n")),
    ("Status unavailable on one route (walk #5 d)", _set(["screens", "timeline", "header"], "Timeline\nStatus unavailable")),
    ("Status unavailable on the browser-served Hub (walk #5 d)", _set(["screens", "home", "header_browser"], "Home\nStatus unavailable")),
    ("no contact for 59 months card (walk #5 e)", _txt(["screens", "home", "text"], "PEOPLE\nNo contact for 19 months.\n")),
    ("gone quiet for 26 months (walk #5 e)", _txt(["screens", "home", "text"], "You've gone quiet with Jane Doe\nIt's been 800 days\n")),
    ("a raw 31 months count (walk #5 e)", _txt(["wiki", "pages", "front", "text"], "last spoke 31 months ago\n")),
    ("a raw URL in Ostler copy (walk #5 f)", _txt(["screens", "home", "text"], "Read more at https://example.com/x\n")),
    ("an em dash on a System sub-page (walk #6 crawl)",
     _txt(["wiki", "crawl", "System/Declining/", "text"], "Films \u2014 down 40%\n")),
    ("a raw category key on a System sub-page (walk #6 crawl)",
     _txt(["wiki", "crawl", "System/New-discoveries/", "text"], "tv_show\t14\n")),
    ("an ISO date on a System sub-page (walk #6 crawl)",
     _txt(["wiki", "crawl", "System/Monthly-volume/", "text"], "since 2026-03-01\n")),
    ("a monospace date on a System sub-page (walk #6 crawl)",
     _set(["wiki", "crawl", "System/Monthly-volume/", "mono_dates"], 3)),
    ("a nav-linked page the crawl never read (walk #6 crawl)",
     _app(["wiki", "nav_links"], "System/Statistics/")),
    ("a calendar title whose URL still shows raw (walk #6 f)",
     _txt(["screens", "timeline", "text"], "EVENT\nCheck in https://example.com/checkin\n")),
    ("an organisation listed as a person (walk #16 console)",
     _app(["people_api"], {"name": "Example Holdings Ltd", "email": ""})),
    ("a username as a People name (walk #16 console)", _app(["people_api"], {"name": "jdoe1984", "email": ""})),
    ("a calendar address as a People name (walk #16 console)",
     _app(["people_api"], {"name": "abc123@group.calendar.google.com", "email": ""})),
    ("digits as a People name (walk #16 console)", _app(["people_api"], {"name": "001", "email": ""})),
]


# Each mutant must be caught by the assertion written for it, not incidentally by another.
MUTANT_TARGETS = dict(zip([n for n, _ in MUTANTS], [0, 1, 2, 2, 2, 1, 1, 1, 1, 2, 2, 2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 11, 12, 12, 13, 14, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 24, 24, 24, 25, 25, 25, 26, 26, 27, 27, 27, 28, 1, 2, 0, 30, 29, 28, 24, 31, 31, 31]))


def _proxy_bypass_self_test():
    """A dead HTTP_PROXY is set. A loopback call through _local_urlopen must
    still answer; a plain urlopen of the same URL must fail through the proxy
    (the control: it proves the fake proxy is really in effect); and a
    non-loopback URL must be refused rather than sent around the proxy."""
    import http.server
    import threading
    import urllib.request

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")

        def log_message(self, *a):
            pass
    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = "http://127.0.0.1:{}/".format(srv.server_address[1])
    keys = ("HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy")
    saved = {k: os.environ.get(k) for k in keys}
    try:
        for k in ("NO_PROXY", "no_proxy"):
            os.environ.pop(k, None)
        os.environ["HTTP_PROXY"] = os.environ["http_proxy"] = "http://127.0.0.1:9"
        control_failed = False
        try:
            urllib.request.urlopen(url, timeout=3).read()
        except Exception:
            control_failed = True
        try:
            body = _local_urlopen(url, timeout=3).read()
        except Exception as exc:
            body = ("ERR " + str(exc)).encode()
        refused_remote = False
        try:
            _local_urlopen("http://example.com/", timeout=3)
        except ValueError:
            refused_remote = True
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        srv.shutdown()
    return control_failed, body == b"ok", refused_remote


def self_test():
    import copy
    ctl, ok, refused = _proxy_bypass_self_test()
    if not ctl:
        print("SELF-TEST BROKEN: the fake proxy did not affect a plain urlopen, so the bypass arm proves nothing")
        return EX_FAIL
    if not ok or not refused:
        print("SELF-TEST FAIL: loopback call through a dead HTTP_PROXY ok={} non-loopback refused={}".format(ok, refused))
        return EX_FAIL
    print("  ok    a loopback call bypasses a dead HTTP_PROXY (control: a plain urlopen fails through it); a non-loopback URL is refused")
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

    # An @handle is customer data, so it must PASS the internal-values check;
    # the same token without the "@" is a stored key and must still FAIL.
    want_jargon = DECLARED[MUTANT_TARGETS["snake_case key on the front page (#2549)"]]
    handle = copy.deepcopy(_good())
    handle["wiki"]["pages"]["front"]["text"] += "Followed @ann_lee\n"
    got = [ok for n, ok, _ in judge(handle) if n == want_jargon]
    if got != [True]:
        missed.append("an @handle is flagged as an internal key ({!r}, want [True])".format(got))
    else:
        print("  ok    an @handle on a wiki page PASSES the internal-values check")
    bare = copy.deepcopy(_good())
    bare["wiki"]["pages"]["front"]["text"] += "Followed ann_lee\n"
    got = [ok for n, ok, _ in judge(bare) if n == want_jargon]
    if got != [False]:
        missed.append("a bare snake_case token is no longer flagged ({!r}, want [False])".format(got))
    else:
        print("  ok    the same token without the @ still FAILS")

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

    # The owner is the CONFIGURED identity. A walk that installed a synthetic
    # owner cannot measure the product: the arm must read CANNOT-RUN, never pass.
    synth = copy.deepcopy(_good())
    synth["owner_source"] = "synthetic"
    synth["people_api"].append({"name": "John Smith", "email": "owner@example.net"})
    got25 = [ok for n, ok, _ in judge(synth) if n == DECLARED[25]]
    configured = copy.deepcopy(synth)
    configured["owner_source"] = "configured"
    got25c = [ok for n, ok, _ in judge(configured) if n == DECLARED[25]]
    unknown = copy.deepcopy(synth)
    unknown["owner_source"] = "unknown-walk"
    if [ok for n, ok, _ in judge(unknown) if n == DECLARED[25]] != [None]:
        missed.append("owner arm: a walk box with no owner marker is not CANNOT-RUN")
    if got25 != [None] or got25c != [False]:
        missed.append("owner arm: synthetic owner gave {!r} (want [None]), configured owner gave {!r} (want [False])".format(got25, got25c))
    else:
        print("  ok    a synthetic walk owner is CANNOT-RUN; the configured owner in People FAILS")

    # Walk #6: "Needs you now" compared in each surface's REAL format. The app
    # card reads CATEGORY / privacy chip / title; the wiki card CATEGORY / title.
    app_text = ("From the Editor\nNeeds you now\n2\nDATES\nPrivate\nJane Doe\u2019s birthday is in five days\n"
                "PEOPLE\nPrivate\nYou\u2019ve gone quiet with John Doe\nFor you\n1\n")
    wiki_text = ("Your Front Page\nNeeds you now\n2\nDATES\n\nJane Doe's birthday is in five days\n\n"
                 "PEOPLE\nYou've gone quiet with John Doe\nFor you\n")
    same = copy.deepcopy(_good())
    same["screens"]["home"]["text"] = app_text
    same["wiki"]["pages"]["front"]["text"] = wiki_text + "1,000\nPEOPLE\n50\nORGANISATIONS\n"
    dom = copy.deepcopy(_good())
    dom["needs_now_app"] = ["Jane Doe\u2019s birthday is in five days", "You\u2019ve gone quiet with John Doe"]
    dom["needs_now_wiki"] = ["You've gone quiet with John Doe", "Jane Doe's birthday is in five days"]
    differ = copy.deepcopy(dom)
    differ["needs_now_wiki"] = ["You've gone quiet with John Doe", "Two records for Jane Doe?"]
    r8 = [[ok for n, ok, _ in judge(x) if n == DECLARED[8]] for x in (same, dom, differ)]
    # The lag ruling: tolerated only when the feed is newer than the compile and
    # under 15 minutes old; every other mismatch, and unreadable times, FAIL.
    lag_cases = [({"feed": 1000, "wiki": 900, "now": 1300}, NA),      # newer, 5 min old: tolerated
                 ({"feed": 1000, "wiki": 1001, "now": 1100}, False),  # wiki compiled after the feed
                 ({"feed": 1000, "wiki": 900, "now": 2000}, False),   # newer but 16+ min old
                 ({}, False)]                                         # times unreadable
    lag_got = []
    for fr_, want in lag_cases:
        x = copy.deepcopy(differ); x["freshness"] = fr_
        lag_got.append(([ok for n, ok, _ in judge(x) if n == DECLARED[8]] or [None])[0] == want)
    if not all(lag_got):
        missed.append("Needs you now lag ruling misapplied: {}".format(lag_got))
    else:
        print("  ok    a mismatch is tolerated only when the feed is newer than the compile and under 15 minutes old; "
              "wiki-after-feed, a stale feed and unreadable times FAIL")
    if r8 != [[True], [True], [False]]:
        missed.append("Needs you now: chip-format text {} / DOM titles {} / a different card {} (want True, True, False)".format(*r8))
    else:
        print("  ok    Needs you now: the same cards in app and wiki formats PASS (chip skipped, quotes normalised); a different card FAILS")
    # Walk #6: the Doctor list in its current shape.
    new_doc = ("CONNECTED SOURCES\n3\nBringing in your data\nTHIS DEVICE\nNot paired\nCONNECTED SOURCES\nAll\n"
               "Apple Notes\nImported\nCalendar\nImported\niMessage\nStreaming\nWHAT'S RUNNING\nGateway\nRunning\n")
    good_doc = copy.deepcopy(_good()); good_doc["screens"]["doctor"]["text"] = new_doc
    short_doc = copy.deepcopy(_good()); short_doc["screens"]["doctor"]["text"] = new_doc.replace("CONNECTED SOURCES\n3", "CONNECTED SOURCES\n14")
    r10 = [[ok for n, ok, _ in judge(x) if n == DECLARED[10]] for x in (good_doc, short_doc)]
    if r10 != [[True], [False]]:
        missed.append("Doctor list in the current shape: matching {} / 14 vs 3 {} (want True, False)".format(*r10))
    else:
        print("  ok    the Doctor's current list shape is read: tile 3 = list 3 PASSES, tile 14 vs list 3 FAILS")

    # The Hub count judged is the one read back to back with the API total.
    b2b = copy.deepcopy(_good())
    b2b["screens"]["people"]["text"] = "YOUR NETWORK\nPeople\n999 PEOPLE\n"        # an earlier, stale read
    b2b["screens"]["people"]["count_text"] = "YOUR NETWORK\nPeople\n1,000 PEOPLE\n"  # read beside the API
    b2b_off = copy.deepcopy(b2b)
    b2b_off["screens"]["people"]["count_text"] = "YOUR NETWORK\nPeople\n999 PEOPLE\n"
    r14 = [[ok for n, ok, _ in judge(x) if n == DECLARED[14]] for x in (b2b, b2b_off)]
    if r14 != [[True], [False]]:
        missed.append("people count: back-to-back read {} / still differing by one {} (want True, False)".format(*r14))
    else:
        print("  ok    the Hub count read beside the API total is the one judged; still 1 apart FAILS (no tolerance)")

    # Ruling 2026-10-04 (#2546): the Hub and the wiki may count different things;
    # different totals that each match their own source must PASS.
    labelled = copy.deepcopy(_good())
    labelled["wiki"]["pages"]["front"]["text"] = labelled["wiki"]["pages"]["front"]["text"].replace("1,000\nPEOPLE", "900\nPEOPLE")
    labelled["wiki"]["pages"]["people"]["text"] = "People\n900 people with a page.\n"
    got14 = [ok for n, ok, _ in judge(labelled) if n == DECLARED[14]]
    if got14 != [True]:
        missed.append("a Hub total and a wiki total that each match their own source still fail ({!r})".format(got14))
    else:
        print("  ok    Hub 1,000 and wiki 900, each matching its own source, PASS (no cross-equality)")

    # Data freshness is read from the list shape as well as the table shape
    # (walk #5 finding 3: a table-only reader reported all 9 sources missing).
    list_shape = {"kind": "list", "text": "\u25a1\nMessages\nNothing found to read yet \u00b7 2 hours ago\n"
                                          "\u2713\nMail messages\nUp to date \u00b7 3 hours ago\n"
                                          "\u2713\nAddress book\nUp to date \u00b7 3 hours ago\n"}
    table_shape = {"kind": "table", "rows": ["Meetings", "Contact"]}
    got_l, got_t = freshness_labels(list_shape), freshness_labels(table_shape)
    if got_l != ["Messages", "Mail messages", "Address book"] or got_t != ["Meetings", "Contact"] \
            or freshness_labels(None) is not None or freshness_labels({"kind": "empty"}) != []:
        missed.append("freshness_labels misreads a shape: list={!r} table={!r}".format(got_l, got_t))
    else:
        print("  ok    Data freshness is read from the list shape and the table shape; absent is NOT MEASURED")
    listed = copy.deepcopy(_good())
    listed["wiki"]["pages"]["front"]["freshness"] = freshness_labels(
        {"kind": "list", "text": "\u2713\nMail\nUp to date\n\u2713\nWhatsApp\nUp to date\n\u2713\nContacts\nUp to date\n"})
    got19 = [ok for n, ok, _ in judge(listed) if n == DECLARED[19]]
    if got19 != [True]:
        missed.append("a list-shaped freshness section naming every working source still fails ({!r})".format(got19))
    else:
        print("  ok    a list-shaped freshness section naming every working source PASSES")

    # Walk #11 (cut #12): the 3 em dashes on People/timeline and activity were
    # all inside Safari page TITLES, which are the customer's data, not Ostler
    # copy. The crawl records the text of each such link (CUSTOMER_TITLES_JS)
    # and the judge removes exactly those strings, once each, before counting.
    # Synthetic titles only.
    title = "Harbour trains \u2014 a short history"
    browsed = copy.deepcopy(_good())
    browsed["wiki"]["nav_links"].append("People/Example-Person/timeline/")
    browsed["wiki"]["crawl"]["People/Example-Person/timeline/"] = {
        "text": "Timeline\nBrowsing history\n12 Mar \u2013 " + title + "\n", "mono_dates": 0,
        "customer_titles": [title]}
    got1 = [(ok, d) for n, ok, d in judge(browsed) if n == DECLARED[1]]
    if [ok for ok, _ in got1] != [True]:
        missed.append("an em dash inside a customer's browsing title still fails ({!r})".format(got1))
    else:
        print("  ok    an em dash inside a customer's browsing-page title PASSES (customer data, not Ostler copy)")
    for label, text in (("template copy on the same page", "Pages you visited \u2014 this week\n"),
                        ("a heading", "Harbour trains \u2014 recent\n")):
        mut = copy.deepcopy(browsed)
        mut["wiki"]["crawl"]["People/Example-Person/timeline/"]["text"] += text
        got = [ok for n, ok, _ in judge(mut) if n == DECLARED[1]]
        if got != [False]:
            missed.append("an em dash in {} beside an exempt title is hidden ({!r})".format(label, got))
        else:
            print("  ok    an em dash in {} beside an exempt title still FAILS".format(label))
    # Walk #16: an em dash inside a person's NAME on Hub People is the
    # contact's own data and PASSES; our own label beside it still FAILS.
    named = copy.deepcopy(_good())
    dashed = "Jane Doe \u2014 Acme Corp"
    named["people_api"].append({"name": dashed, "email": ""})
    named["people_api_total"] = named.get("people_api_total", 0) + 1
    named["screens"]["people"]["text"] += dashed + "\n"
    gotn = [ok for n, ok, _ in judge(named) if n == DECLARED[1]]
    if gotn != [True]:
        missed.append("an em dash inside a person's name on Hub People still fails ({!r})".format(gotn))
    else:
        print("  ok    an em dash inside a person's name on Hub People PASSES (contact-written, not Ostler copy)")
    # Walk #16 customer eyes: real names that look unusual must PASS the junk
    # and organisation predicates, or the check fails real people.
    for real in ("\U0001d479\U0001d48a\U0001d484\U0001d48c\U0001d49a Doe", "Mary-Jane O'Neil", "Henry 8th",
                 "\u674e\u5c0f\u9f8d", "J. R. R. Doe", "jane doe"):
        if junk_name(real) or service_sender(real):
            missed.append("a real name is flagged as junk or an organisation: {!r}".format(real))
        else:
            print("  ok    a real name passes the People name checks: {!r}".format(real))
    for label, text in (("our own label beside it", "Recently added \u2014 this week\n"),
                        ("a second copy of the same name", dashed + "\n")):
        mut = copy.deepcopy(named)
        mut["screens"]["people"]["text"] += text
        got = [ok for n, ok, _ in judge(mut) if n == DECLARED[1]]
        if got != [False]:
            missed.append("an em dash in {} on Hub People is hidden by the name exemption ({!r})".format(label, got))
        else:
            print("  ok    an em dash in {} on Hub People still FAILS".format(label))
    twice = copy.deepcopy(browsed)
    twice["wiki"]["crawl"]["People/Example-Person/timeline/"]["text"] += title + "\n"
    got = [ok for n, ok, _ in judge(twice) if n == DECLARED[1]]
    if got != [False]:
        missed.append("one recorded title exempts two copies of its text ({!r})".format(got))
    else:
        print("  ok    one recorded title exempts one occurrence only; a second copy of the same text FAILS")

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
            handles = []
            if a.get("--self-handles-file"):
                try:
                    # one entry per line: handles (comma-separated allowed) and the owner's full name
                    handles = []
                    for line in open(a["--self-handles-file"]).read().splitlines():
                        line = line.strip()
                        if not line:
                            continue
                        handles += [h.strip() for h in line.split(",") if h.strip()] if ("@" in line or re.search(r"\d{6,}", line)) else [line]
                except Exception:
                    handles = []
            facts = collect(a["--base"], token, a.get("--doctor-base"), a.get("--front-page-json"), a["--out"],
                            self_handles=handles)
            if a.get("--owner-source"):
                facts["owner_source"] = a["--owner-source"]
            if a.get("--freshness-file"):
                fresh = {}
                try:
                    for line in open(a["--freshness-file"]).read().splitlines():
                        k, _, v = line.partition(" ")
                        if k in ("feed", "wiki", "now") and v.strip().isdigit():
                            fresh[k] = int(v.strip())
                except Exception:
                    fresh = {}
                facts["freshness"] = fresh
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
