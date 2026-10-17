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
  date_range  true: the gold answer is a span of dates, so a natural range
            ("24-31 October", "4 to 5 November") counts as naming both of its
            endpoints. Opt-in per question, never global.
  gold      a known-good answer; used ONLY by the self-tests

GRADER REVISION 2 (v1.0.108, disclosed in the PR that relocked CHECKSUM.lock).
Revision 1 is kept byte-for-byte as grading_legacy.py so one run can be graded
under both (compare_graders.py). The two changes, both of which make the test
EASIER and are therefore listed rather than buried:
  1. date ranges, for questions that opt in with date_range (events-04, events-07);
  2. extra refusal phrases, honoured for kind == "absent" ONLY.
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


# REVISION 2: further ways to say "this is not in your data". Honoured ONLY when
# the question's kind is "absent" (see is_refusal): on a fact question a
# refusal is never a pass, whatever it says. Every phrase is a substring of the
# normalised answer.
ABSENT_ONLY_REFUSAL_MARKERS = (
    "i don't see", "i do not see",
    "no mention", "not mentioned",
    "nothing in",
    "didn't find", "did not find",
)

_MONTHS = ("january|february|march|april|may|june|july|august|september|october|"
           "november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec")
_SEP = r"(?:-|to|until|till|through|thru|and)"
_DAY = r"(\d{1,2})(?:st|nd|rd|th)?"
# "24-31 october", "24th to the 31st of october", "4 to 5 nov"
_RANGE_DAY_FIRST = re.compile(
    r"(?<![a-z0-9])" + _DAY + r"\s*" + _SEP + r"\s*(?:the\s+)?" + _DAY +
    r"\s+(?:of\s+)?(" + _MONTHS + r")(?![a-z0-9])")
# "october 24-31", "oct 24 to 31"
_RANGE_MONTH_FIRST = re.compile(
    r"(?<![a-z0-9])(" + _MONTHS + r")\s+" + _DAY + r"\s*" + _SEP + r"\s*(?:the\s+)?" + _DAY +
    r"(?![a-z0-9])")


def is_refusal(norm_text, kind):
    """True when the normalised answer declines to answer. ONLY an "absent"
    question can accept a refusal; every other kind returns False, so a fact
    question can never be passed by "I don't know" however it is worded."""
    if kind != "absent":
        return False
    if any(m in norm_text for m in REFUSAL_MARKERS):
        return True
    return any(m in norm_text for m in ABSENT_ONLY_REFUSAL_MARKERS)


def expand_date_ranges(norm_text):
    """Append the endpoints a date range names, in both spellings, so the
    ordinary alias matching sees them: "24-31 october" -> "24 october 31
    october october 24 october 31". Only called for date_range questions."""
    extra = []
    for m in _RANGE_DAY_FIRST.finditer(norm_text):
        d1, d2, mon = m.group(1), m.group(2), m.group(3)
        extra += ["%d %s" % (int(d1), mon), "%d %s" % (int(d2), mon),
                  "%s %d" % (mon, int(d1)), "%s %d" % (mon, int(d2))]
    for m in _RANGE_MONTH_FIRST.finditer(norm_text):
        mon, d1, d2 = m.group(1), m.group(2), m.group(3)
        extra += ["%d %s" % (int(d1), mon), "%d %s" % (int(d2), mon),
                  "%s %d" % (mon, int(d1)), "%s %d" % (mon, int(d2))]
    return norm_text + (" " + " ".join(extra) if extra else "")


def classify_part(q, context_text):
    """Which part of the score a question belongs to, from the CONTEXT.md the
    run actually injected: "context" when every required fact is already in it
    (the model only has to read), "retrieval" when at least one is not (the
    graph or the conversation store has to supply it). An "absent" question is
    "context": a refusal needs nothing retrieved. Pure function of its inputs."""
    if q.get("kind") == "absent":
        return "context"
    n = normalise(context_text)
    for group in q.get("require", []):
        if not any(_present(a, n) for a in group):
            return "retrieval"
    return "context"


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
        if not is_refusal(n, q["kind"]):
            return 0.0, "no_refusal"
        rx = q.get("forbid_regex")
        if rx and re.search(rx, n):
            return 0.0, "fabricated"
        return 1.0, "ok"
    groups = q["require"]
    if q.get("date_range"):
        n = expand_date_ranges(n)
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
