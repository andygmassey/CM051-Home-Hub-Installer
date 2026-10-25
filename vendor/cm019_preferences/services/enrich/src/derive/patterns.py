"""Pattern derivers: trend, say-vs-do contradiction, time-of-day context.

Ported and reworked from CM019 #413 (the derive-general branch, chunks 7-9) onto the
all-of-life engine (#422). Three differences from #413, each on purpose:

- ANNOTATE ONLY. #413 emitted companion nodes; a companion shares the base node's
  URI (the URI is a hash of dimension and value), so it overwrote the base node in
  the graph. These derivers set optional fields on the base node and emit nothing.
- NEVER FLIP POLARITY. A contradiction is recorded as a marker. The node's
  strength and sign are left exactly as the aggregator scored them.
- ONE HALF-LIFE. The trend window is read from the shared recency module
  (services/common/recency.py: the hygiene 540d table). Nothing here defines a
  decay constant. If that module is not importable (a tree older than the
  half-life work) the trend degrades to the fixed window below and says so in
  ``RECENCY_SOURCE``.

WHAT THE DATA CAN SUPPORT (ingest contract audit, 2026-10-22). A stored point is
one (source, subject) with its LATEST event time and a count; there is no event
history. So trend and time-of-day are computed over the POPULATION OF DISTINCT
POINTS per value (at least three, each a different item), not over events:
trend is how many distinct points were last active in the recent window versus
the prior one, as a share of the dimension; time-of-day is the spread of the
points' last-event times. Neither can see repeat plays inside one point. A
source whose points are stamped with the import day is detected and left out.
Where no event time exists (twitter likes, reddit votes, csv) the points are
undated and contribute nothing: no trend is invented.

Every deriver sees only EvidenceItem and DerivedPreference, so it is
domain-agnostic. Nothing here quotes a message: reasons carry counts, not text.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timedelta, timezone, tzinfo
from typing import Callable, Dict, List, Optional, Sequence, Tuple

from .model import DerivedPreference, EvidenceItem, normalize_value
from .sensitive import derived_value_is_sensitive, is_abstention_value, is_sensitive

try:  # the shared half-life source (services/common/recency.py)
    import recency as _recency
    RECENCY_SOURCE = "recency"
except ImportError:  # pragma: no cover - exercised by a test via monkeypatch
    _recency = None
    RECENCY_SOURCE = "fixed-window"

# Only used when the shared recency module is absent. It is a comparison window,
# not a decay constant.
_FALLBACK_WINDOW_DAYS = 365.0

# Trend: the recent window must differ from the prior one by this share of the
# larger, and there must be this many dated observations across both.
TREND_RELATIVE_CHANGE = 0.35
TREND_MIN_OBSERVATIONS = 3

# Contradiction: behaviour needs this many signals and a lean of at least this
# size before it can contradict a statement.
CONTRA_MIN_BEHAVIOURAL = 3
CONTRA_MIN_LEAN = 0.10

# Context: a value is tied to a time only when most of its evidence sits there.
CONTEXT_MIN_ITEMS = 4
CONTEXT_CONCENTRATION = 0.6

STATED = "stated"

HalfLifeFn = Callable[[str], Optional[float]]


def _aware(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is not None and dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def _groups(items: Sequence[EvidenceItem]) -> Dict[Tuple[str, str], List[EvidenceItem]]:
    out: Dict[Tuple[str, str], List[EvidenceItem]] = defaultdict(list)
    seen = set()
    for it in items:
        key = (it.dimension, normalize_value(it.value), it.preference_id)
        if key in seen:  # same dedupe the Aggregator applies
            continue
        seen.add(key)
        out[(it.dimension, normalize_value(it.value))].append(it)
    return out


# A source whose dated points mostly share ONE calendar day was stamped with the
# import day, not the event day (measured: safari_bookmarks and imessage until
# CM051 #3123). Their times say when the owner imported, so they must not feed a
# trend or a time-of-day. Detected from the data, not a hard-coded source list.
IMPORT_STAMP_MIN_POINTS = 20
IMPORT_STAMP_DAY_SHARE = 0.6


def import_stamped_sources(items: Sequence[EvidenceItem]) -> set:
    by_src: Dict[str, List[datetime]] = defaultdict(list)
    for it in items:
        if it.observed_at is not None and it.source:
            by_src[it.source].append(_aware(it.observed_at))
    bad = set()
    for src, times in by_src.items():
        if len(times) < IMPORT_STAMP_MIN_POINTS:
            continue
        days: Dict = defaultdict(int)
        for t in times:
            days[t.date()] += 1
        if max(days.values()) / len(times) >= IMPORT_STAMP_DAY_SHARE:
            bad.add(src)
    return bad


def _event_timed(items: Sequence[EvidenceItem]) -> List[EvidenceItem]:
    """Evidence whose time is plausibly an event time (see above)."""
    bad = import_stamped_sources(items)
    return [i for i in items if i.source not in bad] if bad else list(items)


def _by_key(nodes: Sequence[DerivedPreference]) -> Dict[Tuple[str, str], DerivedPreference]:
    return {(n.dimension, normalize_value(n.subject)): n for n in nodes}


def half_life_resolver(dimensions: Sequence = ()) -> HalfLifeFn:
    """dimension -> half-life days (None = never decays), from the shared source.

    Per-dimension overrides come from the DimensionConfig rows
    (``half_life_days`` / ``evergreen``) when the config carries them.
    """
    cfg = {d.dimension: d for d in dimensions}

    def resolve(dimension: str) -> Optional[float]:
        if _recency is None:
            return _FALLBACK_WINDOW_DAYS
        row = cfg.get(dimension)
        return _recency.resolve_half_life(
            dimension,
            getattr(row, "half_life_days", None),
            bool(getattr(row, "evergreen", False)),
        )

    return resolve


# --- Trend ------------------------------------------------------------------

class TrendDeriver:
    """Rising or fading, per (dimension, value), from real event timestamps.

    Two equal windows, each one half-life long: RECENT (now back one half-life)
    and PRIOR (the half-life before that). Evidence older than two half-lives is
    ignored here (the aggregator already discounts it).

    The comparison is of SHARE, not volume. A value's signed evidence mass in a
    window is divided by the dimension's total dated evidence in that window, so
    "rising" means gaining ground among its peers. Raw volume would call every
    site "rising" the moment the owner's browsing history grew, and every film
    "rising" after a busy month; measured on a real box before this normalisation,
    most nodes read rising. A dimension with no evidence in either window has no
    baseline and yields no trend. The share is taken along the node's own
    direction, so a deepening dislike is "rising" and a dislike that stopped being
    voiced is "falling".

    Not recency-weighted within the windows: weighting both by age puts the recent
    one ahead by construction.
    """

    method = "trend"

    def __init__(self, half_life_for: Optional[HalfLifeFn] = None):
        self._half_life_for = half_life_for or half_life_resolver()

    def derive(self, items, nodes, now=None) -> None:
        now = _aware(now) or datetime.now(timezone.utc)
        base = _by_key(nodes)
        groups = _groups(_event_timed(items))

        def window_of(it, window):
            at = _aware(it.observed_at)
            if at is None:
                return None
            age = max(now - at, timedelta(0))
            if age <= window:
                return "recent"
            if age <= 2 * window:
                return "prior"
            return None

        # Dimension totals per window, over the SAME deduped evidence.
        totals: Dict[str, Dict[str, int]] = defaultdict(lambda: {"recent": 0, "prior": 0})
        for (dim, _v), members in groups.items():
            hl = self._half_life_for(dim)
            if hl is None:
                continue
            for m in members:
                w = window_of(m, timedelta(days=hl))
                if w:
                    totals[dim][w] += 1

        for key, members in groups.items():
            node = base.get(key)
            if node is None:
                continue
            hl = self._half_life_for(node.dimension)
            if hl is None:  # evergreen: a diet does not trend
                continue
            window = timedelta(days=hl)
            mass = {"recent": 0.0, "prior": 0.0}
            seen = 0
            for m in members:
                w = window_of(m, window)
                if w:
                    mass[w] += m.item_strength
                    seen += 1
            if seen < TREND_MIN_OBSERVATIONS:
                continue
            t = totals[node.dimension]
            if t["recent"] == 0 or t["prior"] == 0:
                continue  # no baseline in the dimension: cannot say rising or fading
            overall = mass["recent"] + mass["prior"]
            if overall == 0:
                continue
            sign = 1.0 if overall > 0 else -1.0
            r = mass["recent"] * sign / t["recent"]
            p = mass["prior"] * sign / t["prior"]
            scale = max(abs(r), abs(p))
            if scale == 0:
                continue
            rel = (r - p) / scale
            node.trend = (
                "rising" if rel >= TREND_RELATIVE_CHANGE
                else "falling" if rel <= -TREND_RELATIVE_CHANGE
                else "stable"
            )


# --- Say vs do --------------------------------------------------------------

class ContradictionDeriver:
    """The owner SAID one thing and the behaviour SHOWS the other.

    Stated evidence (polarity_source "stated", the owner's own words) against
    behavioural evidence on the same (dimension, value). The node keeps the sign
    the aggregator gave it. What is added is a marker:

        contradiction = {"winner": "stated"|"behaviour", "suppress": True,
                         "reason": "<counts only>"}

    NEVER derived for a sensitive value or an abstention value (alcohol, pork,
    meat): "you said you quit, but you keep buying beer" is a health or
    religion inference, so no marker is computed, written or served for it.
    Those keys are counted in ``withheld_sensitive``.

    The winner is always the side that says DISLIKE. A dislike that behaviour
    contradicts may be a gift, a habit or someone else's order, and suggesting a
    thing the owner said they hate costs more than missing one they might like, so
    the dislike side wins for surfacing and ``suppress`` is set. The marker never
    changes strength, and never quotes a message.
    """

    method = "contradiction"

    def __init__(self, min_behavioural: int = CONTRA_MIN_BEHAVIOURAL,
                 min_lean: float = CONTRA_MIN_LEAN):
        self.min_behavioural = min_behavioural
        self.min_lean = min_lean
        self.withheld_sensitive = 0

    def derive(self, items, nodes, now=None) -> None:
        base = _by_key(nodes)
        self.withheld_sensitive = 0
        for key, members in _groups(items).items():
            node = base.get(key)
            if node is None:
                continue
            if (derived_value_is_sensitive(node.dimension, node.subject)
                    or is_abstention_value(node.subject)
                    or any(is_abstention_value(m.value) or is_sensitive(m.value) for m in members)):
                if any(m.polarity_source == STATED for m in members):
                    self.withheld_sensitive += 1
                continue
            stated = [m for m in members if m.polarity_source == STATED]
            behav = [m for m in members if m.polarity_source != STATED]
            if not stated or len(behav) < self.min_behavioural:
                continue
            s_mean = sum(m.item_strength for m in stated) / len(stated)
            b_mean = sum(m.item_strength for m in behav) / len(behav)
            if abs(s_mean) < self.min_lean or abs(b_mean) < self.min_lean:
                continue
            if (s_mean > 0) == (b_mean > 0):
                continue  # they agree
            if s_mean < 0:
                winner = "stated"
                reason = (
                    f"stated dislike ({len(stated)} statement"
                    f"{'s' if len(stated) != 1 else ''}) against {len(behav)} "
                    f"behavioural signals tending positive; the dislike wins for "
                    f"suggestions"
                )
            else:
                winner = "behaviour"
                reason = (
                    f"stated like ({len(stated)} statement"
                    f"{'s' if len(stated) != 1 else ''}) against {len(behav)} "
                    f"behavioural signals tending negative; the behavioural dislike "
                    f"wins for suggestions"
                )
            node.contradiction = {"winner": winner, "suppress": True, "reason": reason}
            node.is_contested = True


# --- Time of day ------------------------------------------------------------

def _date_only(dt: datetime) -> bool:
    """An event stamped exactly midnight (in its own offset) is a date with no time."""
    return dt.timetz().replace(tzinfo=None) == datetime.min.time()


def _tod_bucket(hour: int) -> str:
    if 5 <= hour < 12:
        return "morning"
    if 12 <= hour < 17:
        return "afternoon"
    if 17 <= hour < 22:
        return "evening"
    return "night"


class ContextDeriver:
    """When a preference is expressed: morning, afternoon, evening, night, weekend.

    A label is set only when at least ``concentration`` of the value's dated
    evidence sits in it (a negative control: evenly spread evidence gets none).
    Times are read in the owner's local zone. An event stamped exactly midnight UTC
    is a date with no time, so it is left out of the time-of-day count (it would
    read as "night") and counts toward weekend on its OWN calendar date: it is
    never shifted into the owner's zone (Monday 00:00Z is Sunday evening in New
    York, which made five date-only Mondays read as "weekend"). No season, no mood.
    """

    method = "context"

    def __init__(self, min_items: int = CONTEXT_MIN_ITEMS,
                 concentration: float = CONTEXT_CONCENTRATION,
                 tz: Optional[tzinfo] = None):
        self.min_items = min_items
        self.concentration = concentration
        self.tz = tz

    def _local(self, dt: datetime) -> datetime:
        return _aware(dt).astimezone(self.tz)

    def _weekday(self, dt: datetime) -> int:
        a = _aware(dt)
        if _date_only(a):
            return a.weekday()   # date-only: its own calendar date, never shifted
        return self._local(a).weekday()

    def derive(self, items, nodes, now=None) -> None:
        base = _by_key(nodes)
        for key, members in _groups(_event_timed(items)).items():
            node = base.get(key)
            if node is None:
                continue
            dated = [m for m in members if m.observed_at is not None]
            labels: List[str] = []

            timed = [m for m in dated if not _date_only(_aware(m.observed_at))]
            if len(timed) >= self.min_items:
                counts: Dict[str, int] = defaultdict(int)
                for m in timed:
                    counts[_tod_bucket(self._local(m.observed_at).hour)] += 1
                top, n = max(counts.items(), key=lambda kv: (kv[1], kv[0]))
                if n / len(timed) >= self.concentration:
                    labels.append(top)

            if len(dated) >= self.min_items:
                wk = sum(1 for m in dated if self._weekday(m.observed_at) >= 5)
                if wk / len(dated) >= self.concentration:
                    labels.append("weekend")

            if labels:
                node.context = labels


def default_derivers(dimensions: Sequence = (), tz: Optional[tzinfo] = None) -> list:
    """The registered set, in run order. Trend and context read the shared
    half-life via ``dimensions``; contradiction needs nothing."""
    return [
        TrendDeriver(half_life_resolver(dimensions)),
        ContradictionDeriver(),
        ContextDeriver(tz=tz),
    ]
