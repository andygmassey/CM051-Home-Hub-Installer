"""Data model for the hygiene verdict overlay (MEMORY_HYGIENE_SPEC.md 2.2/2.3).

The load-bearing design decision: **source triples are immutable once
written.** Every hygiene decision is a ``HygieneVerdict`` in a separate,
recomputable, reversible overlay (the ``<urn:pwg:hygiene>`` named
graph). Un-retiring a fact is deleting its verdict row; a sticky undo is
a ``user_override=True`` verdict, which the automated pass must never
clobber. Only GDPR "delete forever" (an existing, separate path) ever
destroys source triples -- nothing in this package does.

Facts with no verdict are ``active`` with full weight: absence of
hygiene never hides a fact.
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime
from typing import List, Optional

from contact_syncer.privacy_model import LEVEL_L3, normalise_level
from ostler_hygiene.source_trust import resolve_source_trust

STATUS_ACTIVE = "active"
STATUS_SUPERSEDED = "superseded"
STATUS_ARCHIVED = "archived"
STATUS_DELETED = "deleted"          # reserved for the GDPR path; never set here

# Machine reasons written to pwg:verdictReason (the audit log).
REASON_RECENCY = "superseded_by_recency"
REASON_AUTHORITY = "superseded_by_authority"
REASON_DECAY = "archived_low_weight_decay"      # Phase 2, spec 3.3
REASON_EXPIRED = "archived_expired"             # Phase 2, validTo honoured

# Privacy: L3 fact TEXT must never leave the graph via hygiene surfaces
# (flags artifact, logs). Verdicts themselves carry only URIs + numbers,
# never fact text, so the verdict overlay is L3-safe by construction.
L3_REDACTED = "[redacted: private (L3)]"

def _privacy_class(level: Optional[str]) -> str:
    """Classify one privacy stamp: ``"safe"`` | ``"l3"`` | ``"unknown"``.

    Emptiness is a genuine three-way distinction the redaction join
    needs: an untagged fact must be able to INHERIT its person node's
    affirmative level (see ``FactRecord.is_l3``), so a missing/empty
    stamp classifies as ``"unknown"`` (no signal), NOT as L3.

    Any *non-empty* value is run through the single canonical vocabulary
    authority -- ``contact_syncer.privacy_model.normalise_level`` (F8:
    one shared L3 contract, import-only, never a local copy). That
    function maps L0/L1/L2 through and fails everything else -- ``"L3"``,
    typos and garbage alike -- closed to L3, so a typo can never publish.
    """
    v = (level or "").strip()
    if not v:
        return "unknown"
    return "l3" if normalise_level(v) == LEVEL_L3 else "safe"

# uuid5 namespace for verdict URIs: verdict identity is a pure function of
# the fact URI, so re-running the pass addresses the same verdict row
# (idempotent by construction, spec section 4).
_VERDICT_NS = uuid.uuid5(uuid.NAMESPACE_URL, "urn:pwg:hygiene:verdict")


def verdict_uri(fact_uri: str) -> str:
    """Deterministic verdict URI for a fact URI."""
    return f"urn:pwg:hygiene:verdict/{uuid.uuid5(_VERDICT_NS, fact_uri)}"


@dataclass(frozen=True)
class FactRecord:
    """A source fact, normalised across both namespaces.

    CM041 ``pwg:PersonFact`` (https://pwg.dev/ontology#) supplies
    factText/factSource/factDomain/authoritative/createdAt/validFrom/
    validTo. CM048 ``urn:pwg:Fact`` supplies text/domain/candidate and
    carries NO timestamp and NO source predicate today -- such facts are
    recency-incomparable and can only ever be flagged, never
    auto-superseded (fail-safe by construction; the write-time
    ``pwg:observedAt`` predicate is the CM048-side half of spec 2.3).
    """
    uri: str
    person_uri: str
    text: str
    source: Optional[str] = None            # factSource / implied channel
    domain: Optional[str] = None            # factDomain
    authoritative: bool = False
    confidence: Optional[str] = None        # CM048 "stated" | "inferred"
    candidate: bool = False                 # CM048 Foundry candidate flag
    created_at: Optional[datetime] = None
    valid_from: Optional[datetime] = None
    valid_to: Optional[datetime] = None
    observed_at: Optional[datetime] = None  # source predicate where present
    privacy_level: Optional[str] = None     # fact-level stamp, where present
    # AUDIT_3 CRITICAL: in the real graph L3 lives on the pwg:Person NODE
    # (contact_syncer/syncer.py, linkedin_connections.py, owner_node.py),
    # while the mining writers cap fact-level stamps at L2 and CM048
    # forbids L3 on facts entirely. The owning person's level is joined
    # by the facts query and carried here; ``is_l3`` takes the most
    # restrictive of the two.
    person_privacy_level: Optional[str] = None
    # Phase 2: explicit corroboration count where a writer supplies it.
    # When None it is derived from the CM048 Foundry candidate lifecycle
    # (see weight.corroboration_count).
    corroboration_count: Optional[int] = None
    # Phase 2 reinforcement hook (spec 3.3): a later corroborating
    # mention refreshes the decay clock without touching the (immutable)
    # source observedAt.
    last_corroborated_at: Optional[datetime] = None

    @property
    def source_trust(self) -> float:
        return resolve_source_trust(
            self.source, confidence=self.confidence,
            authoritative=self.authoritative,
        )

    @property
    def is_l3(self) -> bool:
        """Redaction decision, fail-CLOSED (AUDIT_3 CRITICAL + MEDIUM).

        A fact is treated as L3 -- and its text redacted from every
        hygiene surface -- unless there is affirmative evidence it is
        safe. Concretely:

        - any L3 (or unparseable) stamp on the fact OR its person node
          -> L3 (most restrictive wins; a typo can never publish);
        - no parseable stamp anywhere (the ~85% un-backfilled legacy
          population, contact_syncer/backfill_privacy.py) -> L3;
        - otherwise (at least one affirmative L0/L1/L2 stamp and no L3
          anywhere) -> not L3. An untagged fact inherits its person
          node's declared level, which is exactly what the backfill
          would stamp.

        Meetings carry no privacyLevel triple and facts carry no
        meeting-link predicate in the real graph, so there is no
        source-meeting level to join; untagged derivation paths are
        covered by the unknown->L3 default above.
        """
        classes = {
            _privacy_class(self.privacy_level),
            _privacy_class(self.person_privacy_level),
        }
        if "l3" in classes:
            return True
        return "safe" not in classes


def redacted_text(fact: "FactRecord") -> str:
    """Fact text safe for hygiene surfaces: L3 bodies are redacted."""
    return L3_REDACTED if fact.is_l3 else fact.text


def derive_observed_at(fact: FactRecord) -> Optional[datetime]:
    """Best-known observation time for a fact (spec 2.3 backfill).

    ``COALESCE(observedAt, validFrom, createdAt)``. Returns None when the
    fact carries no timestamp at all (legacy CM048 facts): such a fact is
    treated as recency-incomparable and never auto-superseded on recency
    grounds -- it can lose only to an authoritative winner, otherwise the
    conflict is flagged for the human.
    """
    return fact.observed_at or fact.valid_from or fact.created_at


@dataclass
class HygieneVerdict:
    """One verdict per fact the pass has an opinion on (spec 2.2).

    Mirrors the ``pwg:HygieneVerdict`` node shape. ``user_override=True``
    marks a verdict a USER action set (forget / keep / resolve); the
    automated pass treats those as immovable.
    """
    fact_uri: str
    status: str = STATUS_ACTIVE
    superseded_by: Optional[str] = None     # fact URI, iff status=superseded
    source_trust: Optional[float] = None
    observed_at: Optional[datetime] = None  # backfilled best-known time
    reason: Optional[str] = None            # machine reason, audit log
    verdict_at: Optional[datetime] = None
    run_id: Optional[str] = None
    user_override: bool = False
    # Phase 2 (spec 2.2 / 3.3 / 3.4): the derived weight fields.
    recency_weight: Optional[float] = None      # pwg:recencyWeight
    effective_weight: Optional[float] = None    # pwg:effectiveWeight
    corroboration_count: Optional[int] = None   # pwg:corroborationCount

    @property
    def uri(self) -> str:
        return verdict_uri(self.fact_uri)


@dataclass
class ContradictionFlag:
    """An unresolved conflict, surfaced for the human -- never auto-applied.

    This is the proposal artifact: it feeds the wiki's existing
    ``contradictions.md`` surface and, when ``foundational`` is True, the
    (Phase 2) fortnightly clarification queue. Phase 1 only DETECTS and
    EMITS these; nothing acts on them automatically.
    """
    person_uri: str
    attribute: str                  # e.g. "employer" or "negation:vegetarian"
    fact_uris: List[str] = field(default_factory=list)
    fact_texts: List[str] = field(default_factory=list)
    values: List[str] = field(default_factory=list)
    foundational: bool = False
    clarification_queue: bool = False   # foundational + ambiguous only
    classifier: str = "rule"            # "rule" | "rule_default_nonfoundational"
    reason: str = "ambiguous"           # why it was flagged, not auto-resolved


@dataclass
class HygieneConfig:
    """Tunables (spec 3.1 step 4, 3.3, 3.4). Deterministic; clock
    injected by caller."""
    # Auto-retire on recency only when the winner is strictly newer by
    # MORE than this many days AND its source trust is not lower.
    min_supersede_age_gap_days: int = 30
    # --- Phase 2: decay half-lives (spec 3.3 domain table) ---
    default_half_life_days: float = 365.0
    preference_half_life_days: float = 540.0    # matches CM059 recency_decay
    situational_half_life_days: float = 30.0
    recency_floor: float = 0.35                 # decay never below this
    # --- Phase 2: effective weight + archival (spec 3.3 / 3.4) ---
    archive_threshold: float = 0.15
    corroboration_boost_scale: float = 0.3      # 1 + log1p(extra) * scale
    corroboration_boost_cap: float = 1.6        # CM059 cross-source cap


@dataclass
class HygieneResult:
    """Output of one pure pass: verdicts to upsert + flags to surface."""
    verdicts: List[HygieneVerdict] = field(default_factory=list)
    flags: List[ContradictionFlag] = field(default_factory=list)


# Domains on Andy's evergreen/foundational list (spec 3.2 rule tier):
# family, work (current employer), home/residence, health/dietary,
# identity (name). CM048 domain vocabulary is free-ish text, so cover the
# obvious synonyms; anything else is non-foundational by rule default
# (the v1.1 MVP has no LLM tier, so classification stays rule-only).
#
# AUDIT_3 MEDIUM: this set must include the vocabulary the real writers
# actually emit, not just the reader's idea of it. The CM041 writers
# emit factDomain values of only {calendar, relationship, social}
# (ical-server.py hardcodes "relationship" for family facts) and leave
# employer/career facts with no domain at all -- hence "relationship"
# (+ partner/spouse/employer synonyms) below, and the text-level
# evergreen matching in decay.is_evergreen for untagged facts.
FOUNDATIONAL_DOMAINS = frozenset({
    "family", "relationship", "relationships", "partner", "spouse",
    "work", "employment", "employer", "career",
    "home", "residence", "location",
    "health", "dietary", "diet", "medical",
    "identity", "name",
})

# Attribute keys from the vendored detector map straight onto that list:
# residence -> home, employer -> work, nationality -> identity.
FOUNDATIONAL_ATTRIBUTES = frozenset({"residence", "employer", "nationality"})


def is_foundational(attribute: str, facts: List[FactRecord]) -> bool:
    """Rule-tier foundational classifier (spec 3.2 step 3, rule tier only).

    Attribute conflicts from the detector's single-valued patterns are
    foundational by construction (residence/employer/nationality are all
    on the evergreen list). Negation conflicts are foundational iff any
    involved fact's domain is on the list. Ambiguous -> False (flag-only,
    never a clarification conversation) -- conservative, nobody gets
    nagged on a guess.
    """
    if attribute in FOUNDATIONAL_ATTRIBUTES:
        return True
    for f in facts:
        if (f.domain or "").strip().lower() in FOUNDATIONAL_DOMAINS:
            return True
    return False
