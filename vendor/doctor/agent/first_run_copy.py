"""Customer-facing copy for the Doctor first-run setup wizard.

Per PRODUCTISATION_CHECKLIST.md Rule 0.9 (locked 2026-05-19):
every customer-facing string lives in an extractable catalogue
from day one. v1.0 ships English-only; v1.2 lifts these to a
proper i18n catalogue (gettext or similar) without touching call
sites. Until then, treat this module as the source-of-truth for
every string the Doctor first-run wizard shows the customer.

The first-run wizard is the second customer touchpoint after the
security setup wizard (whose strings live in
``ostler_security/wizard_copy.py``). It walks through four steps:

1. Docker Desktop check.
2. Ostler services (Qdrant, Oxigraph, Redis-compatible cache).
3. Ollama + embedding model.
4. Ready to import.

Conventions:
- British English throughout.
- No em-dashes (project brand rule).
- Apple-Restraint voice: observational, not punitive.
- Step titles are short noun phrases.
- ``action`` text reads as a verb-led instruction the user can
  scan in two seconds.
- HTML chunks (the rendered ``<!DOCTYPE html>`` template) are
  stored as a single opaque block; markup is preserved verbatim
  for the rendered output to stay byte-identical.

This module is imported by ``first_run.py``. Adding a new wizard
string: define the constant here, import it, and reference from
the call site; never inline strings in the wizard body.
"""

from __future__ import annotations


# ── Step 1: Docker Desktop ───────────────────────────────────────────


STEP1_TITLE = "Docker Desktop"
STEP1_DETAIL_NOT_RUNNING = "Docker is not running"
STEP1_DETAIL_RUNNING_FMT = "Docker {version}"
STEP1_ACTION_NOT_RUNNING = (
    "Open Docker Desktop from your Applications folder. "
    "It takes about 30 seconds to start."
)
STEP1_ACTION_COMMAND_NOT_RUNNING = "open -a Docker"


# ── Step 2: Ostler services ──────────────────────────────────────────


STEP2_TITLE = "Ostler services"
STEP2_DETAIL_COMPLETE = (
    "Qdrant, Oxigraph, and Redis-compatible cache are running"
)
STEP2_DETAIL_PARTIAL_FMT = "Missing: {missing}"
STEP2_DETAIL_NO_CONTAINERS = "No Ostler containers found"
STEP2_DETAIL_WAITING_DOCKER = "Waiting for Docker"
STEP2_ACTION_START_PARTIAL = "Start all services"
STEP2_ACTION_START_NEEDED = "Start Ostler services"
STEP2_ACTION_BLOCKED = "Complete step 1 first"
STEP2_ACTION_COMMAND = "cd ~/.ostler && docker compose up -d"


# ── Step 3: Ollama + embedding model ─────────────────────────────────


STEP3_TITLE = "Ollama + embedding model"
STEP3_DETAIL_COMPLETE_FMT = "Ollama {version} with nomic-embed-text"
STEP3_DETAIL_PARTIAL_FMT = (
    "Ollama {version} running but missing embedding model"
)
STEP3_DETAIL_NEEDED = "Ollama is not running"
STEP3_ACTION_PULL_EMBED = "Pull the embedding model (274 MB download)"
STEP3_ACTION_COMMAND_PULL_EMBED = "ollama pull nomic-embed-text"
STEP3_ACTION_INSTALL = "Install Ollama (auto-starts on boot)"
STEP3_ACTION_COMMAND_INSTALL = "brew install --cask ollama"


# ── Step 4: Ready to import ──────────────────────────────────────────


STEP4_TITLE = "Ready to import"
STEP4_DETAIL_COMPLETE = (
    "All services healthy. You can import your GDPR exports now."
)
STEP4_DETAIL_WAITING_FMT = "Waiting for: {missing}"
STEP4_DETAIL_WAITING_EMBED = "Waiting for embedding model"
STEP4_ACTION_RUN_IMPORT = "Run the import"
STEP4_ACTION_COMMAND_IMPORT = (
    "ostler-import ~/gdpr-exports/ --verbose"
)
STEP4_ACTION_BLOCKED = "Complete the steps above first"


# ── Wizard chrome ────────────────────────────────────────────────────


WIZARD_TITLE_TAG = "Ostler Doctor &ndash; Setup Wizard"
WIZARD_HEADING = "&#128736; Welcome to Ostler"
WIZARD_SUBTITLE = (
    "Ostler Doctor is checking your setup. Follow the steps below."
)
WIZARD_REFRESH_LABEL = "&#8635; Refresh status"
WIZARD_STEP_PREFIX = "Step"
WIZARD_CLICK_TO_COPY = "Click to copy"
WIZARD_DONE_HEADING = "You are ready to import."
WIZARD_DONE_BODY = (
    "All systems go. Run the import command above to bring in "
    "your GDPR exports."
)
