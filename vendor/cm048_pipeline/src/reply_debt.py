"""Reply-debt detector  -  "remember what I owe a reply on".

Relationship *decay* (last-contact / DORMANT badges) already exists across
CM041 + CM044: it tells you who you have not spoken to in a while. This module
is the missing twin  -  reply *debt*: threads where the LAST message is INBOUND
(from the other person, not the owner) and has gone unanswered past a
threshold. Decay is "we have drifted apart"; debt is "the ball is in my court
and I have dropped it".

Design
------

The detector is deliberately source-agnostic. It operates over a normalised
``Thread`` (an ordered list of ``Message`` objects, each with a direction and a
timestamp) and knows nothing about iMessage / WhatsApp / email / meetings. The
per-source adapters (``adapters`` below) do the messy work of turning a store
on disk  -  or a live chat.db  -  into ``Thread`` objects, and that is where the
owner-handle / ``is_from_me`` knowledge lives.

Why a normalised core rather than reading the conversation store directly:
the CM048 conversation bundle on disk collapses a thread to a single
``transcript`` blob with speaker labels and does NOT preserve per-message
``is_from_me`` direction (verified 2026-06-20). The only places with reliable,
ordered, per-message direction are (a) the live iMessage chat.db that the
assistant daemon already reads (``is_from_me`` +
``OSTLER_IMESSAGE_SELF_HANDLES``) and (b) email-thread sidecars. So the core
takes direction as an input contract and the adapters supply it. That keeps the
scoring logic unit-testable without any live data and lets each source feed it
the best direction signal it has.

Privacy
-------

A reply-debt item inherits the privacy level of the thread it came from. ``L3``
threads are dropped entirely before any text is surfaced  -  we never render the
snippet of a private conversation. ``L2``/``L1`` items render but the snippet is
run through the caller's sanitiser (the wiki wing applies ``pii_sanitise`` at
render time; this module just carries the raw snippet + level and lets the
surface decide). ``L0`` is unredacted (synthetic / explicit opt-in).

Scoring
-------

Each owed reply gets a numeric ``score`` so the surfaces can rank "you owe a
reply to N people" most-pressing-first. The score blends:

  * relationship strength   -  a stronger relationship makes an unanswered
    message more pressing (you do not want to leave your sister on read);
  * recency / age           -  fresher debts are more actionable, but very old
    debts also bubble up as "you never replied to this";
  * expects-a-reply         -  a question / request weighs more than an FYI;
  * group-chat penalty      -  group banter does not create a personal reply
    obligation, so 1:1 threads dominate.

Nothing here talks to the network or the filesystem. The adapters do.
"""
from __future__ import annotations

import logging
import math
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Iterable, Optional

log = logging.getLogger(__name__)


# Default: a message left unanswered for at least this many hours counts as
# debt. Below this, you are simply mid-conversation. Tunable per surface.
DEFAULT_THRESHOLD_HOURS = 6.0

# Below this score a debt is too weak to surface (acquaintance FYI, very old).
DEFAULT_MIN_SCORE = 0.15


# ---------------------------------------------------------------------------
# Normalised input model (what an adapter must produce)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Message:
    """One message in a thread, already direction-resolved by the adapter.

    ``is_from_owner`` is the load-bearing field: True when the owner ("me")
    sent it, False when the other party did. The adapter is responsible for
    computing this from ``is_from_me`` (iMessage chat.db) or the participant
    ``role`` ("user" / "other") or the email From-header vs the owner's known
    addresses.
    """

    sender: str  # display name or handle, for the snippet attribution
    text: str
    timestamp: datetime
    is_from_owner: bool


@dataclass(frozen=True)
class Thread:
    """A normalised conversation thread the detector can reason over.

    ``person_uri`` is the canonical CM041 person URI for the 1:1 counterpart,
    when the adapter could resolve it (so the surface can deep-link to the
    person page and read relationship strength). ``None`` for group chats or
    unresolved handles.
    """

    thread_id: str
    channel: str  # "imessage" | "whatsapp" | "email" | "meeting" | ...
    messages: tuple[Message, ...]
    privacy_level: str = "L2"
    is_group: bool = False
    counterpart_name: str = ""
    person_uri: Optional[str] = None
    # 0.0..1.0 relationship strength for the counterpart, if the adapter
    # could fetch it from CM041. None => unknown (treated as a neutral mid
    # weight so an unscored-but-real person is not buried).
    relationship_strength: Optional[float] = None


@dataclass(frozen=True)
class ReplyDebt:
    """One surfaced "you owe a reply" item, ranked by ``score``."""

    thread_id: str
    channel: str
    person_name: str
    person_uri: Optional[str]
    snippet: str
    waiting_since: datetime
    waiting_hours: float
    expects_reply: bool
    is_group: bool
    privacy_level: str
    relationship_strength: Optional[float]
    score: float

    @property
    def waiting_human(self) -> str:
        """A compact "how long it's been waiting" label."""
        h = self.waiting_hours
        if h < 1:
            return "under an hour"
        if h < 24:
            n = int(round(h))
            return f"{n} hour{'s' if n != 1 else ''}"
        days = h / 24.0
        if days < 14:
            n = int(round(days))
            return f"{n} day{'s' if n != 1 else ''}"
        if days < 60:
            n = int(round(days / 7.0))
            return f"{n} week{'s' if n != 1 else ''}"
        n = int(round(days / 30.0))
        return f"{n} month{'s' if n != 1 else ''}"

    def to_dict(self) -> dict:
        return {
            "thread_id": self.thread_id,
            "channel": self.channel,
            "person_name": self.person_name,
            "person_uri": self.person_uri,
            "snippet": self.snippet,
            "waiting_since": self.waiting_since.isoformat(),
            "waiting_hours": round(self.waiting_hours, 2),
            "waiting_human": self.waiting_human,
            "expects_reply": self.expects_reply,
            "is_group": self.is_group,
            "privacy_level": self.privacy_level,
            "relationship_strength": self.relationship_strength,
            "score": round(self.score, 4),
        }


# ---------------------------------------------------------------------------
# Heuristics
# ---------------------------------------------------------------------------


# Things that signal the other person is waiting on YOU specifically. Question
# marks, explicit asks, and decision-forcing phrasing. Deliberately
# conservative: a false negative (miss an owed reply) is cheaper than nagging
# about an FYI that needed no answer.
_REQUEST_PATTERNS = (
    r"\?",  # any question mark
    r"\bcan you\b",
    r"\bcould you\b",
    r"\bwould you\b",
    r"\bwill you\b",
    r"\bdo you\b",
    r"\bare you\b",
    r"\blet me know\b",
    r"\blmk\b",
    r"\bwhat (?:do you|time|about)\b",
    r"\bwhen (?:are|is|can|do|will)\b",
    r"\bwhere (?:are|is|can|do|will)\b",
    r"\bhow (?:are|is|about|do)\b",
    r"\bwhich\b",
    r"\bthoughts\?*\b",
    r"\bplease (?:can|could|let|send|reply|confirm|advise)\b",
    r"\bget back to me\b",
    r"\bwaiting (?:on|for|to hear)\b",
    r"\bany (?:update|news|chance|thoughts)\b",
    r"\byou free\b",
    r"\byou around\b",
    r"\bsound good\b",
    r"\bwork for you\b",
    r"\bconfirm\b",
    r"\brsvp\b",
)

# Pure-FYI / sign-off phrasing that, when it is the WHOLE message, suggests no
# reply is expected. Used only as a tie-breaker; presence of a request pattern
# always wins.
_FYI_ONLY = re.compile(
    r"^(?:thanks|thank you|cheers|ok|okay|cool|great|got it|noted|"
    r"sounds good|will do|see you|bye|night|fyi|np|no worries|"
    r"ttyl|talk later)[\s!.,)]*$",
    re.IGNORECASE,
)

_REQUEST_RE = re.compile("|".join(_REQUEST_PATTERNS), re.IGNORECASE)


def expects_reply(text: str) -> bool:
    """Does this inbound message look like it expects a reply?

    True for questions / requests / decision-forcing phrasing. False for bare
    acknowledgements and sign-offs. Conservative by design: when in doubt for a
    substantive message we lean towards True (people under-reply more than they
    over-reply), but a short pure-FYI message is treated as not expecting one.
    """
    t = (text or "").strip()
    if not t:
        return False
    if _REQUEST_RE.search(t):
        return True
    # A short, pure acknowledgement / sign-off: no reply expected.
    if _FYI_ONLY.match(t):
        return False
    # A substantive non-question statement: treat longer messages as soft
    # "expects a reply" (e.g. "I've sent over the proposal, my number is ...")
    # but very short statements as FYI.
    words = len(t.split())
    return words >= 6


def _ensure_aware(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def _recency_weight(hours_waiting: float) -> float:
    """Map age-of-debt to a 0..1 weight.

    Fresh debts (hours) are highly actionable. There is a sweet spot around a
    day or two. Very old debts decay but never to zero  -  a months-old unanswered
    message from someone important should still surface as "you never got back
    to them", just below this week's debts.
    """
    days = max(hours_waiting, 0.0) / 24.0
    if days <= 2.0:
        # ramp up over the first couple of days as it becomes "owed"
        return 0.6 + 0.4 * min(days / 2.0, 1.0)
    # gentle exponential decay with a floor
    return max(0.25, math.exp(-(days - 2.0) / 30.0))


def _strength_weight(strength: Optional[float]) -> float:
    """Relationship strength -> 0..1 weight. Unknown => neutral 0.5."""
    if strength is None:
        return 0.5
    return max(0.0, min(1.0, strength))


def score_debt(
    *,
    relationship_strength: Optional[float],
    hours_waiting: float,
    expects: bool,
    is_group: bool,
) -> float:
    """Blend the signals into a single rankable score in roughly 0..1.

    Weighting rationale (see module docstring):
      * relationship strength is the dominant term  -  leaving someone close on
        read is the thing the user most wants flagged;
      * recency shapes it  -  this week's debts above last month's;
      * expects-a-reply is a strong multiplier  -  an FYI barely registers;
      * group chats are heavily penalised  -  banter is not a personal debt.
    """
    rel = _strength_weight(relationship_strength)
    rec = _recency_weight(hours_waiting)
    # expects-a-reply is a multiplier, not an additive term: an FYI from even a
    # close contact should not nag.
    expect_mult = 1.0 if expects else 0.25
    group_mult = 0.2 if is_group else 1.0

    base = (0.6 * rel) + (0.4 * rec)
    return base * expect_mult * group_mult


# ---------------------------------------------------------------------------
# Detector
# ---------------------------------------------------------------------------


def _snippet(text: str, limit: int = 160) -> str:
    t = " ".join((text or "").split())
    if len(t) <= limit:
        return t
    return t[: limit - 1].rstrip() + "…"


def detect_thread(
    thread: Thread,
    *,
    now: Optional[datetime] = None,
    threshold_hours: float = DEFAULT_THRESHOLD_HOURS,
) -> Optional[ReplyDebt]:
    """Return a ReplyDebt if this thread's LAST message is an unanswered
    inbound message past the threshold, else None.

    Rules, in order:
      1. L3 threads are dropped  -  never surface private conversation text.
      2. Empty threads are skipped.
      3. The last message must be INBOUND (``is_from_owner is False``). If the
         owner sent the last message, the ball is in the other court  -  no debt.
      4. The gap between that inbound message and ``now`` must exceed the
         threshold (below it you are simply mid-conversation).
    """
    if thread.privacy_level == "L3":
        return None
    if not thread.messages:
        return None

    now = _ensure_aware(now or datetime.now(timezone.utc))
    last = thread.messages[-1]

    # Owner sent the last message => ball is in the other person's court.
    if last.is_from_owner:
        return None

    waiting_since = _ensure_aware(last.timestamp)
    hours = (now - waiting_since).total_seconds() / 3600.0
    if hours < threshold_hours:
        return None  # still mid-conversation

    expects = expects_reply(last.text)
    score = score_debt(
        relationship_strength=thread.relationship_strength,
        hours_waiting=hours,
        expects=expects,
        is_group=thread.is_group,
    )

    person = thread.counterpart_name or last.sender or "Unknown"
    return ReplyDebt(
        thread_id=thread.thread_id,
        channel=thread.channel,
        person_name=person,
        person_uri=thread.person_uri,
        snippet=_snippet(last.text),
        waiting_since=waiting_since,
        waiting_hours=hours,
        expects_reply=expects,
        is_group=thread.is_group,
        privacy_level=thread.privacy_level,
        relationship_strength=thread.relationship_strength,
        score=score,
    )


def detect(
    threads: Iterable[Thread],
    *,
    now: Optional[datetime] = None,
    threshold_hours: float = DEFAULT_THRESHOLD_HOURS,
    min_score: float = DEFAULT_MIN_SCORE,
    include_group: bool = False,
) -> list[ReplyDebt]:
    """Detect reply debts across many threads, ranked most-pressing first.

    ``include_group`` defaults False: group chats are excluded entirely (we do
    not nag about group banter). When True they are included but heavily
    penalised by the group multiplier so they sort below 1:1 debts.
    ``min_score`` drops weak debts (acquaintance FYIs, very old low-strength).
    """
    out: list[ReplyDebt] = []
    for thread in threads:
        if thread.is_group and not include_group:
            continue
        debt = detect_thread(thread, now=now, threshold_hours=threshold_hours)
        if debt is None:
            continue
        if debt.score < min_score:
            continue
        out.append(debt)
    out.sort(key=lambda d: d.score, reverse=True)
    return out


# ---------------------------------------------------------------------------
# Daily-brief surface (text block the brief generator can embed)
# ---------------------------------------------------------------------------


def render_brief_block(debts: list[ReplyDebt], *, limit: int = 5) -> str:
    """Render a compact "you owe a reply" block for the daily brief.

    Plain text, no markdown headings (the brief composes its own). Group debts
    and L3 are already excluded upstream. The snippet is NOT included for L2 in
    the brief (the brief is read aloud / glanceable and may be shoulder-surfed)
     -  only who + how long. The wiki wing is the place that shows the snippet
    behind the privacy gate.
    """
    if not debts:
        return "No replies owed  -  you're all caught up."

    top = debts[:limit]
    n = len(debts)
    head = (
        f"You owe a reply to {n} "
        f"{'person' if n == 1 else 'people'}:"
    )
    lines = [head]
    for d in top:
        chan = d.channel.replace("imessage", "iMessage").replace(
            "whatsapp", "WhatsApp"
        )
        lines.append(
            f"  - {d.person_name} ({chan})  -  waiting {d.waiting_human}"
        )
    if n > limit:
        lines.append(f"  - …and {n - limit} more")
    return "\n".join(lines)


__all__ = [
    "Message",
    "Thread",
    "ReplyDebt",
    "expects_reply",
    "score_debt",
    "detect_thread",
    "detect",
    "render_brief_block",
    "DEFAULT_THRESHOLD_HOURS",
    "DEFAULT_MIN_SCORE",
]
