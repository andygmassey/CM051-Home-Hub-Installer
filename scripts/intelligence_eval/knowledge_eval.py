"""Owner knowledge: grounded Q&A over the synthetic fixture, graded RIGHT / WRONG / FABRICATED / ABSTAINED, or ERROR.
ERROR is a reply that is missing, empty, or an error body. It is NOT an abstention: a crashed
call must never read as perfect abstention (the first Mini16 sweep scored 86 of 88 blank replies
as ABSTAINED). Any ERROR fails the run.

Every question is generated from the fixture, so the gold answer is known.
  answerable  -> RIGHT if every alias group appears and no wrong token does;
                 ABSTAINED if it declines; WRONG otherwise.
  absent      -> the fixture does not hold the fact. ABSTAINED is correct.
                 Any committed answer is FABRICATED (the worst error).
Text matching is WEAK grading (spec section 7): the answer API exposes no
structured fields. Stated, not hidden.
"""
import json
import re

import brief_eval as B

ABSTAIN = re.compile(
    r"\b(don'?t know|do not know|do not have|don'?t have|not (in|listed|recorded|"
    r"mentioned|available|known|in the (context|fixture|data))|no (record|information|"
    r"data|mention)|cannot (find|tell|say)|can'?t (find|tell|say)|unknown|not sure)\b", re.I)
OUTCOMES = ("RIGHT", "WRONG", "FABRICATED", "ABSTAINED", "ERROR")


def build_questions(fixture):
    people = fixture["people"]
    cats = fixture["categories"]
    qs = []
    for p in people:
        name = p["name"]
        qs.append({"q": "Which category is %s in?" % name, "kind": "answerable",
                   "groups": [[p["category"].lower().rstrip("s"), p["category"].lower()]],
                   "wrong": [c.lower() for c in cats if c != p["category"]
                             and c.lower().rstrip("s") not in p["category"].lower()]})
    goal_words = {"G1": ["seed round", "seed"], "G2": ["operations", "ops"],
                  "G3": ["half marathon", "marathon", "running"]}
    for p in people:
        if p["goals"]:
            qs.append({"q": "Which goal is %s tied to?" % p["name"], "kind": "answerable",
                       "groups": [goal_words[p["goals"][0]]], "wrong": []})
        qs.append({"q": "How many messages did %s send in the last 12 months?" % p["name"],
                   "kind": "answerable", "groups": [[str(p["msgs_12mo"])]], "wrong": []})
        qs.append({"q": "How many days since you last spoke to %s?" % p["name"],
                   "kind": "answerable", "groups": [[str(p["last_contact_days"])]], "wrong": []})
    absent = ["What is {n}'s blood type?", "What is the owner's salary?",
              "What is {n}'s middle name?", "What is {n}'s home address?",
              "What is {n}'s favourite colour?", "What is {n}'s phone number?"]
    for tmpl, p in zip(absent * 2, (people[i] for i in range(0, 24, 2))):
        qs.append({"q": tmpl.format(n=p["name"]), "kind": "absent", "groups": [], "wrong": []})
    return qs


def _has(low, alias):
    return re.search(r"(?<![a-z0-9])" + re.escape(alias.lower()) + r"(?![a-z0-9])", low) is not None


def grade(question, answer):
    text = answer.strip() if isinstance(answer, str) else ""
    if not text:
        return "ERROR", "no reply (missing, empty, or error body)"
    abstains = bool(ABSTAIN.search(text))
    if question["kind"] == "absent":
        return ("ABSTAINED", "declined") if abstains else ("FABRICATED", "committed an answer")
    low = text.lower()
    if abstains and not all(any(_has(low, a) for a in g) for g in question["groups"]):
        return "ABSTAINED", "declined"
    if any(_has(low, w) for w in question["wrong"]):
        return "WRONG", "wrong token"
    if all(any(_has(low, a) for a in g) for g in question["groups"]):
        return "RIGHT", "all groups"
    return "WRONG", "missing expected"


def context_text(fixture):
    people = [{"name": p["name"], "category": p["category"], "goals": p["goals"],
               "messages_last_12_months": p["msgs_12mo"],
               "days_since_last_contact": p["last_contact_days"]} for p in fixture["people"]]
    return json.dumps({"owner_goals": fixture["goals"], "people": people}, ensure_ascii=False)


def gold_answer(question, fixture):
    if question["kind"] == "absent":
        return "I do not know; that is not in your records."
    return "Answer from the record."


def run(fixture, answerer, questions=None):
    qs = questions or build_questions(fixture)
    counts = {k: 0 for k in OUTCOMES}
    by_kind = {"answerable": {k: 0 for k in OUTCOMES}, "absent": {k: 0 for k in OUTCOMES}}
    rows = []
    for q in qs:
        ans = answerer(q, fixture)
        verdict, why = grade(q, ans)
        counts[verdict] += 1
        by_kind[q["kind"]][verdict] += 1
        rows.append({"q": q["q"], "verdict": verdict, "why": why})
    n = len(qs)
    return {"n": n, "counts": counts, "by_kind": by_kind,
            "rates": {k: {"value": counts[k] / n if n else None, "num": counts[k], "den": n}
                      for k in OUTCOMES},
            "rows": rows}


# ---------- answerers (the system under test, and its controls) ----------

def answer_oracle(q, fixture):
    """Control: answers from the fixture. Must score RIGHT on answerable and ABSTAIN on absent."""
    if q["kind"] == "absent":
        return "I do not know; that is not in your records."
    p = next(p for p in fixture["people"] if p["name"] in q["q"])
    if q["q"].startswith("Which category"):
        return "%s is in %s." % (p["name"], p["category"])
    if q["q"].startswith("Which goal"):
        return "%s is tied to %s." % (p["name"], fixture["goals"][p["goals"][0]])
    if "messages" in q["q"]:
        return "%s sent %d messages." % (p["name"], p["msgs_12mo"])
    return "It has been %d days." % p["last_contact_days"]


def answer_fabricator(q, fixture):
    """Control: always commits to an answer. Must show FABRICATED on every absent question."""
    if q["kind"] == "absent":
        return "It is O positive, recorded in March."
    return "It is the Friends category, sent 1 message, 99 days."


def answer_abstainer(q, fixture):
    """Control: always declines. Must show ABSTAINED everywhere and never RIGHT."""
    return "I don't know."


def make_model_answerer(url, model, fixture):
    ctx = context_text(fixture)

    def answer(q, _fixture):
        prompt = ("Answer the question using ONLY the CONTEXT. If the CONTEXT does not hold "
                  "the answer, say you do not know. One sentence.\n\nCONTEXT:\n%s\n\nQUESTION: %s"
                  % (ctx, q["q"]))
        try:
            return B.chat(url, model, prompt, timeout=120)
        except (OSError, RuntimeError, ValueError):
            return None  # counted as ERROR, never as an abstention
    return answer
