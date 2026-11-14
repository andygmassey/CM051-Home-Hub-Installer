"""Replay world for the brief eval (SYNTHETIC only).

Builds a 30-day timeline from the owner_synthetic_v1 fixture. Every item has
a creation day, an optional close day (the owner handled it outside the
brief), an optional acted day (the owner acted on it after the brief), and
optional supersession (the fact changed). Ground truth fields (acted_day,
closed_day, is_inference) are visible to the SCORER only; builders receive
the as-of view from visible_at().

Deterministic: the same seed and fixture give a byte-identical world.
"""
import datetime
import random

BASE = datetime.date(2026, 10, 16)
REPLAY_DAYS = 30
WINDOW_AFTER_ACT = 2  # an acted day in [d, d+2] counts as acted on brief d
MAX_AGE_DAYS = 14
GOAL_PEOPLE = ("P01", "P02", "P03", "P04")
DELIVERABLES = {"G1": "data room", "G2": "job spec", "G3": "training plan"}


def day_str(d):
    return (BASE + datetime.timedelta(days=d)).isoformat()


def build_world(fixture, seed=20261115):
    rng = random.Random(seed)
    items = []

    def add(**kw):
        kw["id"] = "it-%03d" % (len(items) + 1)
        kw.setdefault("due", None)
        kw.setdefault("acted_day", None)
        kw.setdefault("closed_day", None)
        kw.setdefault("superseded_day", None)
        kw.setdefault("is_inference", False)
        kw.setdefault("versions", [kw["text"]])
        items.append(kw)

    for p in fixture["people"]:
        pid, first = p["id"], p["name"].split()[0]
        cat, goals = p["category"], list(p["goals"])
        if pid in GOAL_PEOPLE:
            pact = 0.7
        elif pid == "P05":          # decoy: huge volume, no goal, rarely acted on
            pact = 0.05
        elif pid == "P06":
            pact = 0.6
        else:
            pact = 0.3
        n_reply = 2 if pid in GOAL_PEOPLE + ("P05", "P06") else 1
        for k in range(n_reply):
            c = rng.randint(0, REPLAY_DAYS - 1)
            acted = c + rng.randint(0, 3) if rng.random() < pact else None
            closed = acted
            if acted is None and rng.random() < 0.2:
                closed = c + rng.randint(0, 2)   # handled outside the brief
            add(kind="reply_owed", person=pid, category=cat, goals=goals,
                entity="thread:%s" % pid, created=c, closed_day=closed,
                acted_day=acted,
                text="%s is waiting for a reply (message %d)" % (first, k + 1))

        if pid in GOAL_PEOPLE:
            c = rng.randint(0, REPLAY_DAYS - 1)
            due = c + rng.randint(3, 10)
            acted = due - rng.randint(0, 2) if rng.random() < 0.6 else None
            deliv = DELIVERABLES.get(goals[0], "update") if goals else "update"
            add(kind="promise", person=pid, category=cat, goals=goals,
                entity="promise:%s" % pid, created=c, due=due, acted_day=acted,
                text="You promised %s the %s by %s" % (first, deliv, day_str(due)))

            m = rng.randint(1, REPLAY_DAYS - 1)
            acted = m if rng.random() < 0.85 else None
            # a meeting moved the day before, for Eli always and for the rest one time in four
            sup = m - 1 if (m >= 2 and (pid == "P02" or rng.random() < 0.25)) else None
            v0 = "Coffee with %s at 11:00 on %s" % (first, day_str(m))
            v1 = "Coffee with %s at 13:30 on %s" % (first, day_str(m))
            add(kind="meeting", person=pid, category=cat, goals=goals,
                entity="meeting:%s:%d" % (pid, m), created=max(0, m - 3),
                due=m, acted_day=acted, superseded_day=sup,
                versions=[v0, v1] if sup is not None else [v0],
                text=v0)

        if pid not in GOAL_PEOPLE and pid != "P05":
            b = rng.randint(1, REPLAY_DAYS - 1)
            acted = b - 1 if (rng.random() < 0.4 and b >= 2) else None
            add(kind="birthday", person=pid, category=cat, goals=goals,
                entity="birthday:%s" % pid, created=max(0, b - 5), due=b,
                acted_day=acted,
                text="Birthday: %s on %s" % (p["name"], day_str(b)))

    eli = next(p for p in fixture["people"] if p["id"] == "P02")
    for k in range(3):
        c = rng.randint(0, REPLAY_DAYS - 1)
        d = rng.randint(c, REPLAY_DAYS - 1)
        acted = d if rng.random() < 0.3 else None
        add(kind="inference", person="P02", category=eli["category"],
            goals=list(eli["goals"]), entity="infer:P02:%d" % k, created=c,
            due=d, acted_day=acted, is_inference=True,
            text="Eli may be free on %s (inferred from a calendar gap)" % day_str(d))

    for it in items:
        it["created"] = int(it["created"])
    return {"seed": seed, "replay_days": REPLAY_DAYS, "items": items,
            "fixture_owner": fixture["owner"]["name"]}


def visible_at(item, d):
    """What a brief built at 09:00 on day d may legitimately see."""
    if item["created"] > d or d - item["created"] > MAX_AGE_DAYS:
        return False
    return item["closed_day"] is None or item["closed_day"] >= d


def current_version(item, d):
    """Index of the wording that is true on day d."""
    sup = item["superseded_day"]
    return 1 if (sup is not None and d >= sup and len(item["versions"]) > 1) else 0


def acted_in_window(item, d):
    a = item["acted_day"]
    return a is not None and d <= a <= d + WINDOW_AFTER_ACT


def as_of_view(item, d):
    """The only fields a builder may use for item on morning d."""
    v = current_version(item, d)
    return {"id": item["id"], "kind": item["kind"], "person": item["person"],
            "category": item["category"], "goals": item["goals"],
            "entity": item["entity"], "created": day_str(item["created"]),
            "due": day_str(item["due"]) if item["due"] is not None else None,
            "version": v, "text": item["versions"][v]}
