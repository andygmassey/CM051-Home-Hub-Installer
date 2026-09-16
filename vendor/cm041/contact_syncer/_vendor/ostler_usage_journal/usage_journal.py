"""Local-model usage journal writer for the "What your Mac did" panel.

The daemon shows the customer a monthly breakdown of the work their machine
did, split by *purpose*: ingesting, enriching, answering, noticing. The
``answering`` row is written by the Rust daemon itself. Everything else
happens in short-lived Python processes in other repos, which cannot reach
the daemon's ``tokio::task_local``. So the contract between them is a file:

    <workspace_dir>/state/costs.jsonl

One JSON object per line, append-only. The reader is
``zeroclaw-config/src/cost/tracker.rs``; the record shape is
``zeroclaw-config/src/cost/types.rs::CostRecord``. The full contract is
``HR015/launch/USAGE_JOURNAL_CONTRACT.md``.

**The hard rule: MEASURED, NEVER ESTIMATED.** If the runtime does not hand
you a token count, write no record. Do not estimate from character length,
do not divide by four, do not carry forward the last figure. This number is
shown to a paying customer beside a price comparison. A missing record is a
gap somebody can close; a guessed record is a fact that cannot be
distinguished from a real one once it is in the file.

Real counts come only from Ollama's ``prompt_eval_count`` / ``eval_count``,
on ``/api/embed``, ``/api/generate`` and ``/api/chat``. NOT the legacy
``/api/embeddings``, which returns the vector alone.

Invariants enforced here, mirroring :mod:`ostler_fda.settling_progress`:
 * An unknown purpose is a **programming error** and raises ``ValueError``.
   The Rust side REJECTS an unknown purpose string rather than coercing it,
   so ``"enrichment"`` (a plausible typo for ``"enriching"``) would make the
   whole line unparseable and silently shrink the customer's totals.
 * An I/O failure is an **environment problem** and is swallowed with a
   ``logger.warning``. Usage accounting must never abort the work it
   measures.

No PII is written: model name, token counts, timestamp and a run label.
``session_id`` identifies the RUN, never the person.
"""
from __future__ import annotations

import json
import logging
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


# ── The five valid purpose strings ────────────────────────────────────────────
#
# Exact match required by `zeroclaw-config/src/cost/types.rs::Purpose`, which
# is `#[serde(rename_all = "snake_case")]` over a closed enum. Serde REJECTS
# an unknown variant, so a typo does not degrade to `unattributed` -- it makes
# the entire record unparseable and the reader counts it as an unreadable line.
PURPOSES = frozenset({
    "ingesting",      # reading a source in for the first time
    "enriching",      # turning raw material into facts, summaries, pages
    "answering",      # work done because a person asked
    "noticing",       # work the assistant chose to do unprompted
    "unattributed",   # the serde default; the producer genuinely does not know
})


def _expand(raw: str) -> Path:
    """Expand a leading ``~`` the way the daemon's ``expand_tilde_path`` does."""
    return Path(os.path.expanduser(raw.strip()))


def _default_config_dir() -> Path:
    """``$HOME/.ostler``, matching the daemon's ``default_config_dir()``.

    The daemon prefers the ``HOME`` env var over the passwd database, so we
    do the same: a process launched with a different HOME must resolve to the
    same tree the daemon is reading.
    """
    home = os.environ.get("HOME", "").strip()
    if home:
        return Path(home) / ".ostler"
    return Path.home() / ".ostler"


def _config_dir_from_marker(default_config_dir: Path) -> Optional[Path]:
    """Read ``active_workspace.toml``, mirroring ``load_persisted_workspace_dirs``.

    A malformed or empty marker is ignored (the daemon logs and falls
    through), and a relative ``config_dir`` is resolved against the default
    config dir, exactly as the Rust does.
    """
    marker = default_config_dir / "active_workspace.toml"
    try:
        contents = marker.read_text(encoding="utf-8")
    except OSError:
        return None

    raw = ""
    for line in contents.splitlines():
        line = line.strip()
        if not line.startswith("config_dir"):
            continue
        _, _, value = line.partition("=")
        raw = value.strip().strip('"').strip("'").strip()
        break

    if not raw:
        return None

    parsed = _expand(raw)
    return parsed if parsed.is_absolute() else default_config_dir / parsed


def _workspace_for(workspace_env: Path) -> Path:
    """Port of ``schema.rs::resolve_config_dir_for_workspace``, workspace half.

    The installer sets ``ZEROCLAW_WORKSPACE=$OSTLER_DIR/assistant-config``,
    which is a CONFIG dir, not a workspace -- so the daemon appends
    ``workspace`` when it finds a ``config.toml`` beside it. Getting this
    branch wrong writes the journal to a directory nothing reads, which is
    indistinguishable from a producer that was never wired.
    """
    if (workspace_env / "config.toml").exists():
        return workspace_env / "workspace"

    legacy = workspace_env.parent / ".zeroclaw"
    if (legacy / "config.toml").exists():
        return workspace_env
    if workspace_env.name == "workspace":
        return workspace_env

    return workspace_env / "workspace"


def resolve_journal_path() -> Path:
    """Resolve ``<workspace_dir>/state/costs.jsonl`` the way the daemon does.

    Precedence, mirroring ``schema.rs::resolve_runtime_config_dirs``:
      1. ``ZEROCLAW_CONFIG_DIR``            -> ``<dir>/workspace``
      2. ``OSTLER_WORKSPACE`` / ``ZEROCLAW_WORKSPACE`` -> :func:`_workspace_for`
      3. ``~/.ostler/active_workspace.toml`` marker -> ``<config_dir>/workspace``
      4. default                            -> ``~/.ostler/workspace``

    Resolved PER CALL, never at import. A producer that caches this at import
    time and a daemon that resolves it at boot can disagree after an env
    change, and the disagreement is silent on both sides.

    Deliberately NOT keyed on ``OSTLER_HOME``: that name carries two meanings
    in this product (task #325) and neither of them is this one.
    """
    config_dir_env = os.environ.get("ZEROCLAW_CONFIG_DIR", "").strip()
    if config_dir_env:
        return _expand(config_dir_env) / "workspace" / "state" / "costs.jsonl"

    workspace_env = (
        os.environ.get("OSTLER_WORKSPACE", "").strip()
        or os.environ.get("ZEROCLAW_WORKSPACE", "").strip()
    )
    if workspace_env:
        return _workspace_for(_expand(workspace_env)) / "state" / "costs.jsonl"

    default_config_dir = _default_config_dir()
    from_marker = _config_dir_from_marker(default_config_dir)
    if from_marker is not None:
        return from_marker / "workspace" / "state" / "costs.jsonl"

    return default_config_dir / "workspace" / "state" / "costs.jsonl"


def record_usage(
    model: str,
    input_tokens: Optional[int],
    output_tokens: Optional[int],
    purpose: str,
    session_id: str,
    *,
    journal_path: Optional[Path] = None,
) -> bool:
    """Append one MEASURED local-model usage record. Returns True if written.

    ``input_tokens`` / ``output_tokens`` come straight from the runtime.
    Pass ``None`` for a count the runtime did not report -- it is treated as
    zero for the total but does NOT on its own suppress the record, so a
    pure-embedding call (which reports prompt tokens and no output tokens) is
    still recorded. When BOTH are absent or zero there is nothing measured
    and no record is written.

    Raises ``ValueError`` on an unknown purpose (a programming error).
    Never raises on I/O (an environment problem): a full disk must not abort
    an ingest run.
    """
    if purpose not in PURPOSES:
        raise ValueError(
            f"unknown purpose {purpose!r}; must be one of {sorted(PURPOSES)}. "
            "The daemon rejects an unknown purpose and the whole record is lost."
        )

    prompt = int(input_tokens or 0)
    completion = int(output_tokens or 0)
    if prompt <= 0 and completion <= 0:
        # Nothing measured. Per the contract: write no record rather than
        # inventing one. The absence is visible on the panel as a gap.
        return False

    record = {
        "id": str(uuid.uuid4()),
        "session_id": session_id,
        "usage": {
            "model": model,
            "input_tokens": prompt,
            "output_tokens": completion,
            "total_tokens": prompt + completion,
            # Zero is not a placeholder: a local model bought nothing. The
            # panel prices this against a cloud rate card at render time.
            "cost_usd": 0.0,
            "timestamp": datetime.now(timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z"),
            "purpose": purpose,
        },
    }

    path = journal_path or resolve_journal_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps(record, separators=(",", ":")) + "\n"
        # One open-append-close per record, and one write() per line. Records
        # are well under the 4 KB macOS pipe/file atomicity threshold, so
        # concurrent producers interleave whole lines rather than corrupting
        # each other. An O_APPEND write is positioned by the kernel, so no
        # lock is needed and none is taken -- a lock here would put a
        # contention point in the path of the work being measured.
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line)
        return True
    except OSError as exc:
        logger.warning(
            "usage journal write failed (%s): %s", type(exc).__name__, exc
        )
        return False


def tokens_from_ollama(response: dict) -> tuple[Optional[int], Optional[int]]:
    """Extract MEASURED token counts from an Ollama JSON response.

    Returns ``(prompt_eval_count, eval_count)``, either of which may be
    ``None`` when the endpoint did not report it. The legacy
    ``/api/embeddings`` endpoint reports neither, which is why callers on
    that endpoint record nothing at all rather than guessing.

    A non-integer value is treated as absent rather than coerced: a string
    or float here means the response shape changed, and a silently coerced
    number would enter the customer's total as though it were measured.
    """
    if not isinstance(response, dict):
        return (None, None)

    def _count(key: str) -> Optional[int]:
        value = response.get(key)
        # bool is a subclass of int; True would become 1 tokens.
        if isinstance(value, bool) or not isinstance(value, int):
            return None
        return value if value > 0 else None

    return (_count("prompt_eval_count"), _count("eval_count"))
