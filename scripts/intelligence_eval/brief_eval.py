"""Brief usefulness: replay N past mornings, score the picks against what happened next.

A builder gets, for morning d, ONLY as_of_view() rows of items visible at d
(except the deliberately bad control, which reads the whole store, which is
the failure it exists to show). It returns picks: {id, version, guess}.
The scorer then looks up ground truth the builder never saw.

Metric definitions (denominator in brackets):
  acted_precision   picks the owner acted on within 2 days after the brief  [picks]
  acted_recall      acted-on items visible that morning that were picked    [acted-visible items]
  handled_shown     picks already closed before the brief                   [picks]
  stale_fact        picks citing a superseded wording                        [picks]
  guess_as_fact     inference items picked without guess=true               [picks]
  duplicate         picks on a person already picked that morning             [picks]
  phantom           picks whose id is not a real item                       [picks]
"""
import json
import re
import urllib.request

import world as W

PICK_CAP = 3
METRICS = ("acted_precision", "acted_recall", "handled_shown", "stale_fact",
           "guess_as_fact", "duplicate", "phantom")
HIGHER_IS_BETTER = {"acted_precision", "acted_recall"}


# ---------- builders ----------

def build_good(world, d):
    """Hand-written policy over as-of data. A control for what a careful human would pick."""
    rows = [W.as_of_view(i, d) for i in world["items"] if W.visible_at(i, d)]
    today = W.day_str(d)

    def score(r):
        s = 0
        if r["kind"] == "meeting" and r["due"] == today:
            s += 5
        if r["kind"] == "promise" and r["due"] and r["due"] <= W.day_str(d + 3):
            s += 4
        if r["kind"] == "reply_owed" and r["goals"]:
            s += 3
        if r["kind"] == "birthday" and r["due"] and r["due"] <= W.day_str(d + 2):
            s += 2
        if r["kind"] == "inference":
            s -= 1
        if not r["goals"]:
            s -= 2
        return s

    picks, seen = [], set()
    for r in sorted(rows, key=lambda r: (-score(r), r["id"])):
        if r["person"] in seen or score(r) <= 0:
            continue
        seen.add(r["person"])
        picks.append({"id": r["id"], "version": r["version"],
                      "guess": r["kind"] == "inference"})
        if len(picks) == PICK_CAP:
            break
    return picks


def build_bad(world, d):
    """Deliberately bad: fixed four sections, reads the WHOLE store, first wording only,
    an inference is listed as a fact. Each failure below is a named defect the metrics must catch."""
    universe = [i for i in world["items"] if i["created"] <= d]
    sections = ("meeting", "promise", "reply_owed", "inference")
    picks = []
    for kind in sections:
        for i in universe:
            if i["kind"] == kind:
                picks.append({"id": i["id"], "version": 0, "guess": False})
                break
    return picks


def _model_prompt(rows):
    payload = json.dumps(rows, ensure_ascii=False)
    return (
        "You write the owner's morning brief. From the candidate items below pick the "
        "at most %d the owner most needs to act on today. Only use the items given. "
        "An item whose text says it is inferred must be marked guess true. "
        "Reply with JSON only, shaped {\"picks\": [{\"id\": \"...\", \"guess\": false}]}.\n\n"
        "ITEMS:\n%s" % (PICK_CAP, payload))


def chat(url, model, prompt, timeout=240):
    body = json.dumps({"model": model, "stream": False, "think": False,
                       "messages": [{"role": "user", "content": prompt}],
                       "options": {"temperature": 0, "seed": 1, "num_predict": 300}}).encode()
    req = urllib.request.Request(url.rstrip("/") + "/api/chat", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())["message"]["content"]


def parse_picks(reply, valid_ids):
    """Return (picks, phantom_count). Unparseable reply = no picks, never a crash."""
    m = re.search(r"\{.*\}", reply, re.S)
    if not m:
        return [], 0
    try:
        raw = json.loads(m.group(0)).get("picks", [])
    except (ValueError, AttributeError):
        return [], 0
    picks, phantom = [], 0
    for p in raw[:PICK_CAP]:
        if not isinstance(p, dict):
            continue
        pid = str(p.get("id", ""))
        if pid not in valid_ids:
            phantom += 1
            picks.append({"id": pid, "version": -1, "guess": bool(p.get("guess"))})
            continue
        picks.append({"id": pid, "version": None, "guess": bool(p.get("guess"))})
    return picks, phantom


def build_model(url, model):
    def build(world, d):
        rows = [W.as_of_view(i, d) for i in world["items"] if W.visible_at(i, d)]
        valid = {r["id"] for r in rows}
        reply = chat(url, model, _model_prompt(rows))
        picks, _ = parse_picks(reply, valid)
        by = {r["id"]: r for r in rows}
        for p in picks:
            if p["version"] is None:
                p["version"] = by[p["id"]]["version"]
        return picks
    return build


def build_phantom(world, d):
    """Control for the phantom metric: the good policy plus one invented item id."""
    return build_good(world, d) + [{"id": "it-9%02d" % d, "version": 0, "guess": False}]


BUILDERS = {"good": build_good, "bad": build_bad, "phantom": build_phantom}


# ---------- scoring ----------

def score_day(world, d, picks):
    by = {i["id"]: i for i in world["items"]}
    visible_acted = [i for i in world["items"]
                     if W.visible_at(i, d) and W.acted_in_window(i, d)]
    c = {k: 0 for k in ("picks", "acted", "handled", "stale", "gaf", "inference_picks",
                        "dup", "phantom", "acted_visible", "acted_visible_picked")}
    seen_entities = set()
    picked_ids = set()
    for p in picks:
        c["picks"] += 1
        it = by.get(p["id"])
        if it is None:
            c["phantom"] += 1
            continue
        picked_ids.add(it["id"])
        if W.acted_in_window(it, d):
            c["acted"] += 1
        if it["closed_day"] is not None and it["closed_day"] < d:
            c["handled"] += 1
        if p["version"] < W.current_version(it, d):
            c["stale"] += 1
        if it["is_inference"]:
            c["inference_picks"] += 1
            if not p["guess"]:
                c["gaf"] += 1
        if it["person"] in seen_entities:
            c["dup"] += 1
        seen_entities.add(it["person"])
    c["acted_visible"] = len(visible_acted)
    c["acted_visible_picked"] = sum(1 for i in visible_acted if i["id"] in picked_ids)
    return c


def aggregate(world, build, days):
    tot = {k: 0 for k in ("picks", "acted", "handled", "stale", "gaf", "inference_picks",
                          "dup", "phantom", "acted_visible", "acted_visible_picked")}
    per_day = []
    for d in range(days):
        picks = build(world, d)
        c = score_day(world, d, picks)
        per_day.append(len(picks))
        for k in tot:
            tot[k] += c[k]
    return tot, per_day


def rates(tot, per_day):
    n = tot["picks"]
    def r(num, den):
        return {"value": (num / den) if den else None, "num": num, "den": den}
    return {
        "acted_precision": r(tot["acted"], n),
        "acted_recall": r(tot["acted_visible_picked"], tot["acted_visible"]),
        "handled_shown": r(tot["handled"], n),
        "stale_fact": r(tot["stale"], n),
        "guess_as_fact": r(tot["gaf"], n),
        "duplicate": r(tot["dup"], n),
        "phantom": r(tot["phantom"], n),
        "picks_per_day": {"value": (sum(per_day) / len(per_day)) if per_day else None,
                          "den": len(per_day)},
    }


def run_brief(world, which, days, builder=None):
    build = builder or BUILDERS[which]
    tot, per_day = aggregate(world, build, days)
    return rates(tot, per_day), tot


def mutant_scorer_never_acted(world, build, days):
    """Mutation: the scorer never counts an acted pick. Precision must go to 0 for every
    builder; the self-test asserts the good/bad gap collapses (proving the metric reads)."""
    tot, per_day = aggregate(world, build, days)
    tot["acted"] = 0
    tot["acted_visible_picked"] = 0
    return rates(tot, per_day)
