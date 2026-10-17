"""Deterministic graders for the owner-knowledge score.

This file is part of the IMMUTABLE CHECK: its sha256 is folded into the
checksum that owner_score.sh prints and verifies on every run. Changing it
changes the checksum, so a tuning loop cannot quietly make the test easier.

No LLM judge anywhere. A question is graded by exact facts with accepted
aliases, required entities and forbidden (wrong-person) traps, all matched on
normalised word boundaries. Stdlib only.

Question schema (one JSON object per line):
  id        unique string, e.g. "work-01"
  category  one of CATEGORIES
  question  text sent to the assistant
  kind      "fact"   every group in `require` must match
            "absent" the answer is NOT in the owner's data: the assistant must
                     say it does not know, and must not invent a figure
  require   list of groups; a group is a list of accepted aliases, and a group
            matches when ANY alias is present (so each group is one required
            fact or entity)
  none_of   aliases that must NOT appear (wrong-person / wrong-fact traps)
  forbid_regex  (absent only) a regex that must not match, e.g. a fabricated number
  partial   true: score is matched_groups/len(require) instead of all-or-nothing
  gold      a known-good answer; used ONLY by the self-tests
"""
import re
import unicodedata

CATEGORIES = ["work", "family", "tastes", "routines", "people", "events", "todos", "conversations"]

# An answer longer than this cannot be a direct answer to one question. It is
# also the shotgun guard: pasting every fact you know must not score.
MAX_ANSWER_CHARS = 1500

# A refusal is recognised by these phrases only (normalised, so curly quotes
# and case do not matter). Fixed here, not in the question files.
REFUSAL_MARKERS = (
    "don't have", "do not have", "doesn't include", "does not include",
    "no record", "not recorded", "don't know", "do not know", "can't find",
    "cannot find", "couldn't find", "could not find", "not sure",
    "no information", "isn't in", "is not in", "not something i",
    "nothing about", "unable to find", "not available", "i have no",
)


def normalise(text):
    t = unicodedata.normalize("NFKC", text or "").lower()
    t = (t.replace("’", "'").replace("‘", "'")
          .replace("“", '"').replace("”", '"')
          .replace("\u2013", "-").replace("\u2014", "-").replace("\u2011", "-"))
    t = re.sub(r"[*_`#>]", "", t)
    # "3,850" and "3 850" are the same figure.
    t = re.sub(r"(?<=\d)[,  ](?=\d{3}\b)", "", t)
    return re.sub(r"\s+", " ", t).strip()


def _present(alias, norm_text):
    a = normalise(alias)
    if not a:
        return False
    return re.search(r"(?<![a-z0-9])" + re.escape(a) + r"(?![a-z0-9])", norm_text) is not None


def grade(q, answer):
    """Return (score 0..1, reason). Pure function of (question, answer)."""
    if answer is None or not answer.strip():
        return 0.0, "blank"
    if len(answer) > MAX_ANSWER_CHARS:
        return 0.0, "too_long"
    n = normalise(answer)
    for bad in q.get("none_of", []):
        if _present(bad, n):
            return 0.0, "trap:" + bad
    if q["kind"] == "absent":
        if not any(m in n for m in REFUSAL_MARKERS):
            return 0.0, "no_refusal"
        rx = q.get("forbid_regex")
        if rx and re.search(rx, n):
            return 0.0, "fabricated"
        return 1.0, "ok"
    groups = q["require"]
    hit = sum(1 for g in groups if any(_present(a, n) for a in g))
    if hit == len(groups):
        return 1.0, "ok"
    if q.get("partial") and hit:
        return hit / float(len(groups)), "partial"
    return 0.0, "missing"


def score_set(questions, answers):
    """answers: {id: text}. Returns (overall, per_category, per_question)."""
    per_q = {}
    cat = {}
    for q in questions:
        s, why = grade(q, answers.get(q["id"]))
        per_q[q["id"]] = (s, why)
        c = cat.setdefault(q["category"], [0.0, 0])
        c[0] += s
        c[1] += 1
    total = sum(v[0] for v in cat.values())
    n = sum(v[1] for v in cat.values())
    overall = total / n if n else 0.0
    return overall, {k: v[0] / v[1] for k, v in cat.items()}, per_q
