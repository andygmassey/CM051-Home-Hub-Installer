"""Inner circle: who matters to the owner, with evidence, edits and a not-sure bucket.

Pure core. No store, no network, no Contacts or Photos read. The per-source
adapters fill ``PersonSignals``; the store keeps ``Overrides`` and the edit log.

Output contract (``CircleResult``) is what the Hub and iOS read:
  - ``tier``: family | key_colleague | close_friend | not_sure | None
  - ``in_circle``: bool
  - ``evidence``: customer-worded lines with counts. Never scores or ranks.
  - ``needs_confirmation``: ask the owner once rather than assert
  - ``source``: owner_pin | owner_remove | contacts_label | computed | excluded | none

Internal only: a closeness score (0..100) used for the threshold and the
top-N cap. It is never returned.

Score (from specs/INNER_CIRCLE_SPEC.md, with one recorded deviation):
  freq 35, regularity 20, reciprocity 15, warmth 15, recency 10, meetings-or-
  close-friend 5. Unknown terms are dropped and the rest rescaled; confidence
  is the known weight over 100. Deviation: reciprocity is min/max balance, not
  sent/(sent+received), so a one-way sender does not score as close.

Guardrails: exclusions (minor, deceased, do-not-suggest) beat everything.
Owner removal beats owner pin and label. Owner pins are in regardless of score
and do not count against the cap. Manager is set only by owner confirmation.
"""
from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass, field
from typing import Optional, Sequence

FLAG_ENV = "OSTLER_INNER_CIRCLE"
SCHEMA = "inner_circle.v1"
TIERS = ("family", "key_colleague", "close_friend")
# Tiers the provider can return. Owner pins use TIERS; these are computed only.
OUTPUT_TIERS = TIERS + ("not_sure", "wider", "business_sender")
PRIVATE_LEVEL = "L3"
FAMILY_LABELS = frozenset({"spouse", "partner", "child", "parent", "sibling"})
COLLEAGUE_LABELS = frozenset({"manager", "boss", "colleague", "assistant"})

WEIGHTS = {"freq": 35, "regularity": 20, "reciprocity": 15,
           "warmth": 15, "recency": 10, "meet_or_cf": 5}

REASON_TEXTS = frozenset({
    "you message most months",
    "you have met several times this year",
    "you are on your close friends list",
    "you added them",
})

EVIDENCE_TEXTS = {
    "contacts": "in your Contacts as your {label}",
    "photos": "in {n} of your photos",
    "months": "you message most months",
    "meetings": "you have met {n} times this year",
    "close_friends": "you are on your close friends list",
    "work_domain": "shares your work email domain",
    "pinned": "you added them",
}

CIRCLE_SIZE = 12
MIN_SCORE = 55.0
MIN_CONF = 0.6
NOT_SURE_CONF = 0.4


def enabled(env: Optional[dict] = None) -> bool:
    """Default off. Only the literal "1" turns the circle on."""
    e = os.environ if env is None else env
    return e.get(FLAG_ENV, "0") == "1"


@dataclass(frozen=True)
class PersonSignals:
    person_id: str
    sent_365: Optional[int] = None
    recv_365: Optional[int] = None
    active_months_12: Optional[int] = None
    last_contact_days: Optional[float] = None
    warmth: Optional[float] = None
    meetings_12m: Optional[int] = None
    close_friend: Optional[bool] = None
    contacts_label: Optional[str] = None
    work_domain: Optional[bool] = None
    photo_count: Optional[int] = None
    minor: bool = False
    deceased: bool = False
    do_not_suggest: bool = False
    # Privacy level from the store. "L3" is private: excluded, no details.
    privacy_level: Optional[str] = None
    # True when the sender ID is a business or alphanumeric brand (CM048 #134).
    # Not a person: its own tier, hidden by default in the Hub.
    business_sender: bool = False

    def has_any_signal(self) -> bool:
        if self.business_sender:
            return True
        return any(v is not None for k, v in self.__dict__.items()
                   if k not in ("person_id", "minor", "deceased", "do_not_suggest",
                                "privacy_level", "business_sender"))


@dataclass(frozen=True)
class Overrides:
    pinned: dict = field(default_factory=dict)          # person_id -> tier
    removed: frozenset = frozenset()
    manager_ids: frozenset = frozenset()


@dataclass(frozen=True)
class Membership:
    person_id: str
    tier: Optional[str]
    in_circle: bool
    source: str
    privacy_level: Optional[str]
    confidence: float
    type_confidence: float
    needs_confirmation: bool
    is_manager: bool
    reasons: tuple
    evidence: tuple


@dataclass(frozen=True)
class CircleResult:
    status: str                      # ok | no_data
    members: tuple


def closeness_score(p: PersonSignals, p90_msgs: float) -> tuple:
    """Return (score 0..100, confidence 0..1). Unknown terms are dropped."""
    terms = {}
    if p.sent_365 is not None and p.recv_365 is not None:
        msgs = p.sent_365 + p.recv_365
        denom = math.log1p(max(p90_msgs, 1))
        terms["freq"] = min(1.0, math.log1p(msgs) / denom) if denom > 0 else 0.0
        if msgs > 0:
            lo, hi = sorted((p.sent_365, p.recv_365))
            terms["reciprocity"] = lo / hi if hi > 0 else 0.0
    if p.active_months_12 is not None:
        terms["regularity"] = min(1.0, max(0, p.active_months_12) / 12.0)
    if p.warmth is not None:
        terms["warmth"] = min(1.0, max(0.0, p.warmth))
    if p.last_contact_days is not None:
        d = p.last_contact_days
        terms["recency"] = 1.0 if d <= 30 else (0.0 if d >= 365 else (365 - d) / 335.0)
    if p.close_friend:
        terms["meet_or_cf"] = 1.0
    elif p.meetings_12m is not None:
        terms["meet_or_cf"] = min(1.0, p.meetings_12m / 4.0)
    if not terms:
        return 0.0, 0.0
    known_w = sum(WEIGHTS[k] for k in terms)
    score = 100.0 * sum(WEIGHTS[k] * v for k, v in terms.items()) / known_w
    return score, known_w / 100.0


def _p90(values: Sequence[int]) -> float:
    if not values:
        return 1.0
    s = sorted(values)
    idx = min(len(s) - 1, math.ceil(0.9 * len(s)) - 1)
    return float(max(1, s[idx]))


def _evidence(p: PersonSignals) -> tuple:
    out = []
    if p.contacts_label:
        out.append(EVIDENCE_TEXTS["contacts"].format(label=p.contacts_label))
    if p.photo_count:
        out.append(EVIDENCE_TEXTS["photos"].format(n=p.photo_count))
    if p.active_months_12 is not None and p.active_months_12 >= 9:
        out.append(EVIDENCE_TEXTS["months"])
    if p.meetings_12m is not None and p.meetings_12m >= 3:
        out.append(EVIDENCE_TEXTS["meetings"].format(n=p.meetings_12m))
    if p.close_friend:
        out.append(EVIDENCE_TEXTS["close_friends"])
    if p.work_domain:
        out.append(EVIDENCE_TEXTS["work_domain"])
    return tuple(out)


def _reasons(evidence: tuple, pinned: bool) -> tuple:
    if pinned:
        return (EVIDENCE_TEXTS["pinned"],)
    picks = []
    for line in evidence:
        if line == EVIDENCE_TEXTS["months"]:
            picks.append(line)
        elif line.startswith("you have met"):
            picks.append("you have met several times this year")
        elif line == EVIDENCE_TEXTS["close_friends"]:
            picks.append(line)
    return tuple(picks[:3])


def _member(p, *, tier, in_circle, source, conf, type_conf, needs, is_mgr=False,
            pinned=False, silent=False) -> Membership:
    ev = () if silent else _evidence(p)
    return Membership(
        person_id=p.person_id, tier=tier, in_circle=in_circle, source=source,
        privacy_level=p.privacy_level,
        confidence=round(conf, 4), type_confidence=round(type_conf, 4),
        needs_confirmation=needs, is_manager=is_mgr,
        reasons=_reasons(ev, pinned), evidence=ev,
    )


def compute(people: Sequence[PersonSignals], overrides: Overrides, *,
            top_n: int = CIRCLE_SIZE, min_score: float = MIN_SCORE,
            min_conf: float = MIN_CONF, p90_msgs: Optional[float] = None) -> CircleResult:
    if not any(p.has_any_signal() for p in people):
        return CircleResult(status="no_data", members=())

    if p90_msgs is None:
        p90_msgs = _p90([p.sent_365 + p.recv_365 for p in people
                         if p.sent_365 is not None and p.recv_365 is not None])

    out = {}
    candidates = []   # (score, person) for computed members
    for p in people:
        if p.minor or p.deceased or p.do_not_suggest or p.privacy_level == PRIVATE_LEVEL:
            out[p.person_id] = _member(p, tier=None, in_circle=False, source="excluded",
                                       conf=0.0, type_conf=0.0, needs=False, silent=True)
            continue
        if p.business_sender:
            out[p.person_id] = _member(p, tier="business_sender", in_circle=False,
                                       source="business_sender", conf=1.0, type_conf=1.0,
                                       needs=False, silent=True)
            continue
        if p.person_id in overrides.removed:
            out[p.person_id] = _member(p, tier=None, in_circle=False, source="owner_remove",
                                       conf=1.0, type_conf=1.0, needs=False)
            continue
        if p.person_id in overrides.pinned:
            tier = overrides.pinned[p.person_id]
            out[p.person_id] = _member(p, tier=tier, in_circle=True, source="owner_pin",
                                       conf=1.0, type_conf=1.0, needs=False,
                                       is_mgr=p.person_id in overrides.manager_ids,
                                       pinned=True)
            continue
        if p.contacts_label in FAMILY_LABELS:
            if p.work_domain:
                out[p.person_id] = _member(p, tier="not_sure", in_circle=False,
                                           source="contacts_label", conf=0.5,
                                           type_conf=0.5, needs=True)
            else:
                out[p.person_id] = _member(p, tier="family", in_circle=True,
                                           source="contacts_label", conf=1.0,
                                           type_conf=1.0, needs=False)
            continue
        if p.contacts_label in COLLEAGUE_LABELS:
            out[p.person_id] = _member(p, tier="key_colleague", in_circle=True,
                                       source="contacts_label", conf=1.0,
                                       type_conf=1.0, needs=False,
                                       is_mgr=p.person_id in overrides.manager_ids)
            continue
        score, conf = closeness_score(p, p90_msgs)
        if conf >= min_conf and score >= min_score:
            candidates.append((score, p))
        elif conf >= NOT_SURE_CONF and score >= min_score:
            out[p.person_id] = _member(p, tier="not_sure", in_circle=False,
                                       source="computed", conf=conf, type_conf=conf,
                                       needs=True)
        else:
            out[p.person_id] = _member(p, tier=None, in_circle=False, source="none",
                                       conf=conf, type_conf=conf, needs=False)

    candidates.sort(key=lambda sp: (-sp[0], sp[1].person_id))
    for i, (score, p) in enumerate(candidates):
        _, conf = closeness_score(p, p90_msgs)
        if i < top_n and not _evidence(p):
            out[p.person_id] = _member(p, tier="not_sure", in_circle=False,
                                       source="computed", conf=conf, type_conf=conf,
                                       needs=True)
        elif i < top_n:
            is_mgr = p.person_id in overrides.manager_ids
            if p.work_domain:
                out[p.person_id] = _member(p, tier="key_colleague", in_circle=True,
                                           source="computed", conf=conf, type_conf=0.7,
                                           needs=not is_mgr, is_mgr=is_mgr)
            else:
                out[p.person_id] = _member(p, tier="close_friend", in_circle=True,
                                           source="computed", conf=conf, type_conf=0.8,
                                           needs=False)
        else:
            # Clears the score and confidence bar but outside the cap: Wider.
            out[p.person_id] = _member(p, tier="wider", in_circle=False, source="computed",
                                       conf=conf, type_conf=conf, needs=False)

    members = tuple(out[p.person_id] for p in people)
    return CircleResult(status="ok", members=members)


def apply_edit(overrides: Overrides, log: list, *, person_id: str, action: str,
               tier: Optional[str] = None, at: str) -> tuple:
    """Apply one owner edit. Returns (new Overrides, new log). Edits are final."""
    pinned = dict(overrides.pinned)
    removed = set(overrides.removed)
    if action in ("set_tier", "add"):
        t = tier or "close_friend"
        if t not in TIERS:
            raise ValueError(f"unknown tier: {t!r}")
        pinned[person_id] = t
        removed.discard(person_id)
    elif action == "remove":
        pinned.pop(person_id, None)
        removed.add(person_id)
    else:
        raise ValueError(f"unknown action: {action!r}")
    new = Overrides(pinned=pinned, removed=frozenset(removed),
                    manager_ids=overrides.manager_ids)
    entry = {"person_id": person_id, "action": action, "tier": tier,
             "source": "owner_set", "at": at}
    return new, list(log) + [entry]


def _snapshot_inputs():
    """The synthetic cast and its owner overrides, pinned by the iOS side."""
    cast = [
        PersonSignals("c01", contacts_label="spouse", photo_count=400),
        PersonSignals("c02", contacts_label="child", photo_count=120),
        PersonSignals("c03", sent_365=130, recv_365=120, active_months_12=11,
                      last_contact_days=2, warmth=0.8, meetings_12m=5,
                      photo_count=12),
        PersonSignals("c04", sent_365=90, recv_365=80, active_months_12=9,
                      last_contact_days=6, warmth=0.6, work_domain=True,
                      meetings_12m=6),
        PersonSignals("c05", contacts_label="spouse", work_domain=True),
        PersonSignals("c06", sent_365=1, recv_365=1, active_months_12=1,
                      last_contact_days=300),
        PersonSignals("c07", sent_365=300, recv_365=300, last_contact_days=1),
        PersonSignals("c08", sent_365=60, recv_365=55, active_months_12=8,
                      last_contact_days=20, close_friend=True),
        PersonSignals("c09", minor=True, contacts_label="child"),
        PersonSignals("c10", sent_365=200, recv_365=10, active_months_12=12,
                      last_contact_days=3, warmth=0.5),
        PersonSignals("c11", sent_365=300, recv_365=300, active_months_12=12,
                      last_contact_days=1, privacy_level="L3"),
        PersonSignals("c12", business_sender=True),
    ]
    ov = Overrides(pinned={"c06": "key_colleague"}, removed=frozenset({"c08"}),
                   manager_ids=frozenset({"c04"}))
    return cast, ov


def _contract_from_result(res) -> dict:
    rows = []
    for m in sorted(res.members, key=lambda x: x.person_id):
        rows.append({
            "person_id": m.person_id, "tier": m.tier, "in_circle": m.in_circle,
            "source": m.source, "privacy_level": m.privacy_level,
            "needs_confirmation": m.needs_confirmation,
            "is_manager": m.is_manager, "reasons": list(m.reasons),
            "evidence": list(m.evidence),
        })
    return {"schema": SCHEMA, "status": res.status, "members": rows}


def contract_snapshot() -> dict:
    """Deterministic synthetic cast and its output, pinned by the iOS side."""
    cast, ov = _snapshot_inputs()
    return _contract_from_result(compute(cast, ov, p90_msgs=400))


_SIGNAL_FIELDS = frozenset(PersonSignals.__dataclass_fields__)


def compute_from_payload(payload: dict) -> dict:
    """Run the provider on a payload from the Hub: {"people": [...], "overrides": {...}}.

    Unknown signal fields are dropped. An owner pin to a tier outside TIERS is
    dropped, not trusted. A payload with no people is no_data, never an empty ok.
    """
    people = []
    for row in payload.get("people") or []:
        if not isinstance(row, dict) or "person_id" not in row:
            continue
        people.append(PersonSignals(**{k: v for k, v in row.items() if k in _SIGNAL_FIELDS}))
    ov = payload.get("overrides") or {}
    pinned = {pid: t for pid, t in (ov.get("pinned") or {}).items() if t in TIERS}
    overrides = Overrides(pinned=pinned,
                          removed=frozenset(ov.get("removed") or []),
                          manager_ids=frozenset(ov.get("managers") or []))
    p90 = payload.get("p90_msgs")  # optional: the Hub may pin the cohort's p90
    return _contract_from_result(compute(people, overrides,
                                         p90_msgs=float(p90) if p90 is not None else None))


if __name__ == "__main__":
    import sys
    if len(sys.argv) == 2 and sys.argv[1] == "--compute":
        # Hub entry point: payload on stdin, contract on stdout.
        print(json.dumps(compute_from_payload(json.loads(sys.stdin.read())), sort_keys=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--write-contract":
        with open(sys.argv[2], "w", encoding="utf-8") as fh:
            json.dump(contract_snapshot(), fh, indent=2, sort_keys=True)
            fh.write("\n")
    else:
        print(json.dumps(contract_snapshot(), indent=2, sort_keys=True))
