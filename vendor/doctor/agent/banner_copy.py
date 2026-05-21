"""Customer-facing copy for Doctor diagnostic-rule banners.

Per PRODUCTISATION_CHECKLIST.md Rule 0.9 (locked 2026-05-19):
every customer-facing string lives in an extractable catalogue
from day one. v1.0 ships English-only; v1.2 lifts these to a
proper i18n catalogue (gettext or similar) without touching call
sites. Until then, treat this module as the source-of-truth for
every string a Doctor banner shows the customer.

Each banner entry is a function (taking any state-dependent
parameters and returning a dict) or a plain dict constant. The
call sites in diagnostic_rules.py reference these by name; never
inline the strings.

Conventions:
- British English throughout.
- No em-dashes (project brand rule).
- Apple-Restraint voice: observational, not punitive.
- No exclamation marks in banner titles or details.
- Title <= 60 chars (a soft target, not enforced).
- Fix-command strings are technical and stay verbatim across
  languages; they are paths and shell commands, not prose.

This module is imported by ``diagnostic_rules.py``. Adding a new
banner: define the strings here, expose a constant or factory,
and import-and-reference from the rule.
"""

from __future__ import annotations

from typing import Optional


# ── #259 Empty-Mail nudge banner ──────────────────────────────────────


EMPTY_MAIL_NUDGE = {
    "title": "Ostler is not finding any email yet",
    "detail": (
        "When the installer ran, Apple Mail had not pulled any "
        "messages. If you use Apple Mail, open it and add at "
        "least one account. Ostler will start ingesting on the "
        "next hourly tick."
    ),
    "fix": "Open Mail.app, add an account, then run the rescan",
    "fix_command": "~/.ostler/bin/ostler-rescan-mail",
}


# ── #260 Mail backfill progress banner ────────────────────────────────


def backfill_progress(month: str) -> dict:
    """Build the backfill progress banner content.

    Args:
        month: A human-friendly month label like "March 2022",
            already formatted by ``_format_backfill_month`` in the
            rule body.

    Returns:
        Dict with ``title`` and ``detail`` keys ready to merge into
        the finding payload. The rule body adds severity, category,
        fix, fix_command, and risk.
    """
    return {
        "title": "Mail is still being processed",
        "detail": (
            f"Ostler is working backwards through your Apple Mail "
            f"history. The oldest message imported so far is from "
            f"{month}. Every hour, the import reaches a little "
            f"further back. New messages from today are already "
            f"arriving."
        ),
    }
