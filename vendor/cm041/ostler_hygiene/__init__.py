"""Memory hygiene / graceful forgetting -- Phases 1 + 2.

Deterministic engine over the PWG fact store implementing the Phase 1
and Phase 2 slices of ``CM061/design/MEMORY_HYGIENE_SPEC.md``:

- **Phase 0 substrate:** the ``HygieneVerdict`` overlay model (spec 2.1/2.2),
  ``observedAt`` backfill for legacy facts (spec 2.3), and the shared
  canonical ``SOURCE_TRUST`` table (spec 2.5).
- **Phase 1 = MVP:** supersession (spec 3.1) and contradiction
  detect-and-flag (spec 3.2, flag only).
- **Phase 2:** decay/staleness weighting with the domain half-life
  table and Andy's evergreen no-decay list (spec 3.3), the
  effective-weight product ``trust * recency * corroboration`` (spec
  3.4), and reversible archival tombstones for expired or
  low-weight single-mention noise (spec 3.3). Deferred to later
  phases: consolidation (3.5), the clarification scheduler (3.6c),
  voice session-position confidence (3.7), CM019 preference verdicts
  (2.4).

Design invariants (per OSTLER_MEMORY_AGENCY_ARCHITECTURE.md section 8):

1. Deterministic-first, **no LLM anywhere in this package** (Andy's
   2026-07-12 ruling: no LLM in the v1.1 MVPs at all). The foundational
   classifier is rule-tier only; ambiguous domains default to
   non-foundational (flag-only, never queued for a clarification
   conversation) so nobody is nagged on a guess.
2. Local-first: talks only to the local Oxigraph; no cloud routes.
3. Source triples are IMMUTABLE. Every hygiene decision is a verdict in
   the separate named graph ``<urn:pwg:hygiene>``; un-forgetting is
   deleting a verdict row. Nothing in this package ever deletes or
   rewrites a source fact triple.
4. Fail-safe: absence of a verdict always means active + full weight; a
   broken pass degrades to today's (append-only) behaviour.
"""
from __future__ import annotations

from ostler_hygiene.model import (  # noqa: F401
    ContradictionFlag,
    FactRecord,
    HygieneConfig,
    HygieneVerdict,
    STATUS_ACTIVE,
    STATUS_ARCHIVED,
    STATUS_SUPERSEDED,
    derive_observed_at,
    verdict_uri,
)
from ostler_hygiene.decay import recency_weight  # noqa: F401
from ostler_hygiene.source_trust import resolve_source_trust  # noqa: F401
from ostler_hygiene.supersede import run_hygiene_pass  # noqa: F401
from ostler_hygiene.weight import (  # noqa: F401
    corroboration_boost,
    corroboration_count,
    run_full_pass,
    score_fact,
)
