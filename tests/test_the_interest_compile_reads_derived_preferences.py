#!/usr/bin/env python3
"""The daily brief's interest read includes derived preferences (smart-prefs).

#3096 put derived preferences into CONTEXT.md; the interest compile (vendored
CM059 interest_profile.fetch_preferences) read only the literal Like/Dislike
rows from the default graph, so the Front Page and the news/film scouts that
rank against its profile never saw one. This drives the REAL fetch_preferences
-> compile_profile -> frontpage.build_frontpage chain over a fake Oxigraph that
serves derived nodes ONLY to a query that names the derived graph. Synthetic
data only. Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""
import io
import os
import sys
from contextlib import redirect_stderr
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "vendor", "cm059_editor"))
try:
    from compiler import frontpage, interest_profile as ip
except Exception as exc:
    print("CANNOT-RUN: {}".format(exc))
    sys.exit(2)

FAILS = []
DERIVED_GRAPH = "https://schema.ostler.ai/derived/graph/preferences"
NOW = datetime(2026, 10, 22, tzinfo=timezone.utc)


def check(name, cond, detail=""):
    print(("  ok    " if cond else "  FAIL  ") + name + (("  -- " + detail) if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


def literal(i):
    return {"subject": "Synthetic Show %d" % i, "category": "movie_tv",
            "strength": "0.5", "source": "facebook",
            "observed": "2026-09-01T00:00:00Z", "created": "", "plevel": ""}


def derived(label, strength, conf="0.9"):
    return {"subject": label, "strength": strength, "confidence": conf,
            "derivedAt": "2026-10-20T00:00:00Z"}


def make_fake(derived_rows, literal_rows, derived_fails=False):
    seen = []

    def fake(url, query, timeout=30.0):
        seen.append(query)
        if "DerivedPreference" in query:
            if DERIVED_GRAPH not in query:
                return []          # the default graph never holds derived nodes
            if derived_fails:
                raise RuntimeError("store timeout")
            return list(derived_rows)
        if "LikePreference" in query:
            return list(literal_rows)
        return []
    return fake, seen


def run(derived_rows, literal_rows, derived_fails=False):
    fake, seen = make_fake(derived_rows, literal_rows, derived_fails)
    orig = ip._sparql_select
    ip._sparql_select = fake
    err = io.StringIO()
    try:
        with redirect_stderr(err):
            raws = ip.fetch_preferences("http://stub")
    finally:
        ip._sparql_select = orig
    profile = ip.compile_profile(raws, now=NOW)
    feed = frontpage.build_frontpage(profile)
    return raws, profile, feed, err.getvalue(), seen


def card_titles(feed):
    return " || ".join(c.get("title", "") + " " + c.get("body", "") for c in feed.get("cards", []))


# 1. a derived preference changes what the brief selects. 30 literal likes
#    already fill every card slot; a strong derived one must still be chosen.
lits = [literal(i) for i in range(30)]
raws, profile, feed, err, seen = run([derived("synthetic noir thrillers", "0.95")], lits)
check("derived preference is carded", "synthetic noir thrillers" in card_titles(feed),
      card_titles(feed)[:200])
# the control: without the derived row the same page has no such card
_, _, feed0, _, _ = run([], lits)
check("control: absent derived row, no such card", "synthetic noir thrillers" not in card_titles(feed0))
check("the query names the derived graph", any(DERIVED_GRAPH in q for q in seen))

# 2. existing caps hold
cards = [c for c in feed.get("cards", []) if c.get("interest_id")]
check("cards stay within MAX_INTEREST_CARDS", len(cards) <= frontpage.MAX_INTEREST_CARDS,
      str(len(cards)))
many = [derived("synthetic taste %d" % k, "0.9") for k in range(12)]
raws2, _, _, _, seen2 = run(many, [])
n_derived = sum(1 for r in raws2 if r.get("source") == "inferred")
check("at most 4 derived rows are read", n_derived == 4, str(n_derived))
check("the derived query is LIMITed", any("LIMIT 4" in q for q in seen2 if "DerivedPreference" in q))

# 3. a negative derived preference is a dislike, never a card
_, prof3, feed3, _, _ = run([derived("synthetic slapstick", "-0.8")], [literal(1)])
check("negative derived is a dislike", any(d["subject"] == "synthetic slapstick" for d in prof3["dislikes"]))
check("negative derived is never carded", "synthetic slapstick" not in card_titles(feed3))

# 4. derived is local-only: never externally queryable (L2)
d_int = [i for b in profile["domains"] for i in b["interests"] if i["subject"] == "synthetic noir thrillers"]
check("derived rows carry the conservative category",
      all(r["category"] == "inferred_interest" for r in raws if r.get("source") == "inferred"))
check("derived interest is L2, not scout-queryable", d_int and d_int[0]["privacy"] == "L2",
      str(d_int[:1]))

# 5. a failed derived read keeps the literal rows and says so on stderr
raws5, _, _, err5, _ = run([], [literal(1)], derived_fails=True)
check("failed derived read keeps literal rows", len(raws5) == 1)
check("failed derived read is reported, not silent", "derived-preference read failed" in err5, err5)

print("FAIL: {}".format(len(FAILS)) if FAILS else "PASS")
sys.exit(1 if FAILS else 0)
