"""The Editor (CM059) - Phase 0 interest-profile compiler.

Read-only: compiles what the PWG already knows about the user's tastes into a
weighted, evidence-backed, correctable interest profile. No external calls, no
scouts. See SPEC_phase0_interest_profile.md.
"""

__all__ = [
    "interest_profile",
    "corrections",
    "emit_artefact",
    "frontpage",
    "render_frontpage",
    "emit_frontpage",
]
