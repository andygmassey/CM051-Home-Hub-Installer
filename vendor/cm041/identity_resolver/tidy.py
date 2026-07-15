"""Tidy Contacts - analysis engine for the customer-facing "tidy your contacts" feature.

Task #588. Builds a deterministic, serialisable "tidy report" over the People
graph that a Doctor UI can render. It REUSES the existing identity resolver
(``batch_resolver``) for duplicate detection + merge, and layers two further
contact-hygiene passes on top:

    1. Duplicate / mergeable clusters  -> PROPOSED merges (never auto-applied)
    2. Low-quality contacts            -> bare phone / email handle, no real name
    3. Incomplete contacts             -> obvious fields recoverable from the graph

Design principles
-----------------
* CONTACT MERGING IS DESTRUCTIVE. This module only ever PROPOSES merges. The
  apply path (:func:`apply_proposal`) acts on a SINGLE proposal the caller has
  explicitly accepted, re-validates it against live detection, re-applies the
  resolver's LinkedIn-conflict guard, and then delegates to the existing
  ``BatchResolver`` merge (which backs up affected triples, picks a canonical
  node, and marks the discard as ``mergedInto`` rather than hard-deleting it).
* DETERMINISTIC. The detection functions operate on the in-memory
  ``Dict[str, PersonRecord]`` the resolver already builds, sort their output by
  stable keys, and emit plain JSON-able dicts. No clocks, no randomness in the
  report body.
* British English; hyphens not em-dashes in any customer-facing string.

The analysis functions are pure (graph in -> report out) so they can be unit
tested without a live Oxigraph / Qdrant.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

from identity_resolver.batch_resolver import (
    DEFAULT_CONFIG,
    BatchResolver,
    DuplicateMatch,
    PersonRecord,
    _normalise_name,
    consolidate_matches,
    detect_email_matches,
    detect_exact_name_matches,
    detect_fuzzy_name_matches,
    detect_name_subset_matches,
    detect_phone_matches,
    pick_canonical,
)

# ── Item type constants ──────────────────────────────────────────────────────

ITEM_MERGE_DUPLICATE = "merge_duplicate"
ITEM_LOW_QUALITY = "low_quality"
ITEM_INCOMPLETE = "incomplete"

# Suggested-action verbs the Doctor UI keys off.
ACTION_PROPOSE_MERGE = "propose_merge"
ACTION_REVIEW = "review"          # weaker duplicate signal - surface, do not pre-tick
ACTION_ENRICH = "enrich"          # fill a recoverable field
ACTION_NAME_OR_DELETE = "name_or_delete"  # bare handle: ask the user to name or remove

# ── Low-quality detection ────────────────────────────────────────────────────

# A display name that is really just the contact's phone number or email handle
# rather than a human name. Cross-references the known ~85%-named / ~14%-bare
# split in the founder graph: these are the ~14% that arrived from a chat
# channel (iMessage / WhatsApp) with no Contacts entry, so the "name" is the
# raw identifier.
_PHONE_LIKE = re.compile(r"^[\s+()\-.0-9]{6,}$")
_EMAIL_LIKE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
# A raw WhatsApp JID left as a display name when the chat sender had no
# Contacts entry: "<number>@s.whatsapp.net", "<number>@lid" (linked-id /
# privacy handle), group "<id>-<ts>@g.us", older "<number>@c.us". The "@lid"
# form has no dot after the "@" so it slips _EMAIL_LIKE; catch all of them
# explicitly (#664: 534 such names on the founder graph). Match the JID suffix
# anywhere at the end so "[number]@s.whatsapp.net" is covered.
_WHATSAPP_JID = re.compile(
    r"@(?:s\.whatsapp\.net|lid|c\.us|g\.us)$", re.IGNORECASE
)


def _looks_like_phone(name: str) -> bool:
    return bool(_PHONE_LIKE.match(name.strip()))


def _looks_like_email(name: str) -> bool:
    return bool(_EMAIL_LIKE.match(name.strip()))


def _looks_like_whatsapp_jid(name: str) -> bool:
    return bool(_WHATSAPP_JID.search(name.strip()))


def _email_local_part(email: str) -> str:
    return email.split("@", 1)[0] if "@" in email else email


def _is_bare_handle(person: PersonRecord) -> Tuple[bool, str]:
    """Return ``(is_bare, reason)``.

    A contact is a "bare handle" when its display name carries no human name -
    it is either empty, a phone number, an email address, or the local-part of
    one of its own emails (e.g. "jsmith" for jsmith@corp.test).
    """
    name = (person.display_name or "").strip()

    # Structured name present -> not a bare handle, regardless of display name.
    if person.given_name or person.family_name:
        return False, ""

    if not name:
        return True, "no display name"

    if _looks_like_phone(name):
        return True, "display name is a bare phone number"

    # Check WhatsApp JIDs before the generic email rule: "@s.whatsapp.net"
    # would otherwise be reported as an email address, and "@lid" slips the
    # email rule entirely (no dotted domain).
    if _looks_like_whatsapp_jid(name):
        return True, "display name is a WhatsApp ID"

    if _looks_like_email(name):
        return True, "display name is a bare email address"

    norm = _normalise_name(name)
    # Single-token name that is also one of the contact's email local-parts is
    # an auto-generated handle (e.g. WhatsApp / email import fallback).
    if " " not in norm:
        for email in person.emails:
            if norm == _normalise_name(_email_local_part(email)):
                return True, "display name is an email handle"

    return False, ""


def detect_low_quality(
    persons: Dict[str, PersonRecord], config: Dict[str, Any]
) -> List["TidyItem"]:
    """Strategy: flag contacts whose only identity is a bare handle.

    These are surfaced for the user to NAME or DELETE - never auto-deleted.
    """
    items: List[TidyItem] = []
    for uri in sorted(persons):
        p = persons[uri]
        is_bare, reason = _is_bare_handle(p)
        if not is_bare:
            continue

        identifiers = sorted(p.phones) + sorted(p.emails)
        evidence = {
            "display_name": p.display_name,
            "reason": reason,
            "identifiers": identifiers,
            "has_structured_name": bool(p.given_name or p.family_name),
        }
        items.append(TidyItem(
            item_type=ITEM_LOW_QUALITY,
            person_refs=[uri],
            evidence=evidence,
            suggested_action=ACTION_NAME_OR_DELETE,
            confidence=0.9,
            summary=f"Contact has no real name ({reason})",
        ))
    return items


# ── Incomplete-contact detection ─────────────────────────────────────────────

def _recover_split_name(p: PersonRecord) -> Optional[Dict[str, str]]:
    """If the display name clearly splits into given + family but the structured
    fields are missing, propose them. Only fires for an unambiguous two-token
    name to avoid mangling mononyms / multi-part surnames."""
    if p.given_name or p.family_name:
        return None
    name = (p.display_name or "").strip()
    if not name or _looks_like_phone(name) or _looks_like_email(name):
        return None
    parts = name.split()
    if len(parts) != 2:
        return None
    return {"given_name": parts[0], "family_name": parts[1]}


def detect_incomplete(
    persons: Dict[str, PersonRecord], config: Dict[str, Any]
) -> List["TidyItem"]:
    """Strategy: flag contacts missing obvious fields recoverable from the graph.

    Currently recovers:
      * given_name / family_name from an unambiguous two-token display name.

    Each item proposes a concrete ``enrich`` patch the Doctor UI can apply via a
    plain ``update_person`` call (NOT a merge - non-destructive).
    """
    items: List[TidyItem] = []
    for uri in sorted(persons):
        p = persons[uri]

        # Skip bare handles - they are handled by the low-quality pass, and a
        # phone-number "name" must not be split into given/family.
        is_bare, _ = _is_bare_handle(p)
        if is_bare:
            continue

        patch = _recover_split_name(p)
        if patch:
            items.append(TidyItem(
                item_type=ITEM_INCOMPLETE,
                person_refs=[uri],
                evidence={
                    "display_name": p.display_name,
                    "missing": ["given_name", "family_name"],
                    "recovered_from": "display_name",
                    "proposed": patch,
                },
                suggested_action=ACTION_ENRICH,
                confidence=0.7,
                summary="Missing structured name; recoverable from display name",
            ))
    return items


# ── Report item / report containers ──────────────────────────────────────────

@dataclass
class TidyItem:
    """One actionable finding in the tidy report.

    Serialises to the schema the Doctor UI renders:
        {item_type, person_refs, evidence, suggested_action, confidence, summary}
    """

    item_type: str
    person_refs: List[str]
    evidence: Dict[str, Any]
    suggested_action: str
    confidence: float
    summary: str = ""
    # Populated for merge items so the apply path can re-validate without
    # re-deriving canonical selection from scratch.
    keep_uri: Optional[str] = None
    discard_uri: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        d: Dict[str, Any] = {
            "item_type": self.item_type,
            "person_refs": list(self.person_refs),
            "evidence": self.evidence,
            "suggested_action": self.suggested_action,
            "confidence": round(self.confidence, 4),
            "summary": self.summary,
        }
        if self.keep_uri is not None:
            d["keep_uri"] = self.keep_uri
        if self.discard_uri is not None:
            d["discard_uri"] = self.discard_uri
        return d


@dataclass
class TidyReport:
    """Full tidy report. ``to_dict`` is JSON-serialisable."""

    items: List[TidyItem] = field(default_factory=list)
    total_persons: int = 0

    def counts(self) -> Dict[str, int]:
        out: Dict[str, int] = {
            ITEM_MERGE_DUPLICATE: 0,
            ITEM_LOW_QUALITY: 0,
            ITEM_INCOMPLETE: 0,
        }
        for it in self.items:
            out[it.item_type] = out.get(it.item_type, 0) + 1
        return out

    def to_dict(self) -> Dict[str, Any]:
        return {
            "schema_version": 1,
            "total_persons": self.total_persons,
            "counts": self.counts(),
            "items": [it.to_dict() for it in self.items],
        }


# ── Duplicate-cluster -> proposed-merge items ────────────────────────────────

def _duplicate_items(
    persons: Dict[str, PersonRecord], config: Dict[str, Any]
) -> List[TidyItem]:
    """Run the resolver's duplicate detection and turn every candidate pair into
    a PROPOSED merge item.

    Unlike ``BatchResolver.detect`` (which would auto-merge the >=0.8 bucket),
    the tidy engine never auto-applies: the high-confidence bucket becomes
    ``propose_merge`` (pre-ticked-eligible in the UI) and the review bucket
    becomes ``review`` (surfaced, not pre-ticked). Both still require an
    explicit accept before any graph write.
    """
    all_matches: List[DuplicateMatch] = []
    all_matches.extend(detect_exact_name_matches(persons, config))
    all_matches.extend(detect_email_matches(persons, config))
    all_matches.extend(detect_phone_matches(persons, config))
    all_matches.extend(detect_fuzzy_name_matches(persons, config))
    all_matches.extend(detect_name_subset_matches(persons, config))

    auto, review = consolidate_matches(all_matches, config)

    items: List[TidyItem] = []
    for bucket, action in ((auto, ACTION_PROPOSE_MERGE), (review, ACTION_REVIEW)):
        for m in bucket:
            keep, discard = pick_canonical(persons, m.uri_a, m.uri_b)
            evidence = {
                "strategy": m.strategy,
                "details": m.details,
                "name_a": persons[m.uri_a].display_name,
                "name_b": persons[m.uri_b].display_name,
                "keep_name": persons[keep].display_name,
                "discard_name": persons[discard].display_name,
            }
            items.append(TidyItem(
                item_type=ITEM_MERGE_DUPLICATE,
                person_refs=[m.uri_a, m.uri_b],
                evidence=evidence,
                suggested_action=action,
                confidence=m.confidence,
                summary=(
                    f"Possible duplicate: {persons[m.uri_a].display_name!r} / "
                    f"{persons[m.uri_b].display_name!r} ({m.strategy})"
                ),
                keep_uri=keep,
                discard_uri=discard,
            ))

    # Deterministic ordering: highest confidence first, then by URI pair.
    items.sort(key=lambda it: (-it.confidence, it.person_refs[0], it.person_refs[1]))
    return items


# ── Public engine ────────────────────────────────────────────────────────────

class TidyEngine:
    """Builds a tidy report and applies accepted proposals via the resolver.

    The engine owns a ``BatchResolver`` so the apply path reuses the existing,
    safety-checked merge (backup + canonical pick + ``mergedInto`` marking +
    Qdrant point cleanup). No new merge logic is introduced here.
    """

    def __init__(
        self,
        oxigraph_url: str = "http://localhost:7878",
        qdrant_url: str = "http://localhost:6333",
        qdrant_collection: str = "people",
        config: Optional[Dict[str, Any]] = None,
    ):
        self.config = {**DEFAULT_CONFIG, **(config or {})}
        self.resolver = BatchResolver(
            oxigraph_url=oxigraph_url,
            qdrant_url=qdrant_url,
            qdrant_collection=qdrant_collection,
            config=self.config,
        )

    # -- report --------------------------------------------------------------

    def build_report(
        self, persons: Optional[Dict[str, PersonRecord]] = None
    ) -> TidyReport:
        """Build the full tidy report.

        If ``persons`` is supplied (tests / callers that already loaded the
        graph) it is used directly; otherwise the graph is fetched from
        Oxigraph via the resolver.
        """
        if persons is None:
            from identity_resolver.batch_resolver import _fetch_all_persons

            persons = _fetch_all_persons(
                self.resolver.oxigraph_url, self.resolver._client, self.config
            )

        items: List[TidyItem] = []
        items.extend(_duplicate_items(persons, self.config))
        items.extend(detect_low_quality(persons, self.config))
        items.extend(detect_incomplete(persons, self.config))

        return TidyReport(items=items, total_persons=len(persons))

    # -- apply ---------------------------------------------------------------

    def apply_proposal(
        self,
        keep_uri: str,
        discard_uri: str,
        *,
        revalidate: bool = True,
        backup_dir: str = "./backups",
    ) -> Dict[str, Any]:
        """Apply a single ACCEPTED merge proposal.

        This is the ONLY graph-writing path. It:
          1. (optionally) re-runs duplicate detection on the live graph and
             confirms the two URIs are still a detected duplicate pair - guards
             against a stale proposal whose underlying data changed.
          2. re-applies the resolver's LinkedIn-conflict hard blocker.
          3. delegates the merge to ``BatchResolver`` (backup + Oxigraph +
             Qdrant), preserving its existing safety rules. The discard node is
             marked ``mergedInto`` - never hard-deleted.

        Returns a result dict ``{applied: bool, keep_uri, discard_uri, reason}``.
        Rejecting a proposal is a no-op for the caller (simply never call this),
        so there is deliberately no ``reject`` method that touches the graph.
        """
        from identity_resolver.batch_resolver import (
            MergeAction,
            ResolverReport,
            _fetch_all_persons,
        )

        persons = _fetch_all_persons(
            self.resolver.oxigraph_url, self.resolver._client, self.config
        )

        if keep_uri not in persons or discard_uri not in persons:
            return {
                "applied": False,
                "keep_uri": keep_uri,
                "discard_uri": discard_uri,
                "reason": "one or both persons no longer exist (already merged?)",
            }

        # LinkedIn hard blocker (mirrors resolver.detect_* guards): two distinct
        # LinkedIn profiles are never the same person.
        a, b = persons[keep_uri], persons[discard_uri]
        if a.linkedin_urls and b.linkedin_urls and not (a.linkedin_urls & b.linkedin_urls):
            return {
                "applied": False,
                "keep_uri": keep_uri,
                "discard_uri": discard_uri,
                "reason": "blocked: persons have different LinkedIn URLs",
            }

        if revalidate:
            live_items = _duplicate_items(persons, self.config)
            still_dup = any(
                set(it.person_refs) == {keep_uri, discard_uri}
                for it in live_items
            )
            if not still_dup:
                return {
                    "applied": False,
                    "keep_uri": keep_uri,
                    "discard_uri": discard_uri,
                    "reason": "proposal no longer a detected duplicate on live graph",
                }

        # Delegate to the existing, safety-checked merge (backs up first).
        action = MergeAction(
            keep_uri=keep_uri,
            keep_name=persons[keep_uri].display_name,
            discard_uri=discard_uri,
            discard_name=persons[discard_uri].display_name,
            confidence=1.0,
            strategy="tidy_accepted",
            details="merge accepted via tidy contacts",
        )
        report = ResolverReport(auto_merges=[action])
        self.resolver.execute(report, backup_dir=backup_dir)

        return {
            "applied": True,
            "keep_uri": keep_uri,
            "discard_uri": discard_uri,
            "reason": "merged",
        }

    def close(self) -> None:
        self.resolver.close()
