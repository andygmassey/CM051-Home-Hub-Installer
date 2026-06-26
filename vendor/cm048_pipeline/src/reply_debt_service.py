"""Reply-debt service + HTTP endpoint for the daily brief.

Ties the detector core (``reply_debt``) to the adapters
(``reply_debt_adapters``) and exposes the result two ways:

  * ``compute_reply_debts(...)`` - the in-process entry point. Pulls threads
    from every available adapter, runs the detector, returns a ranked list of
    ``ReplyDebt`` dicts. This is what a brief generator or the wiki wing calls.

  * ``handle_reply_debt(handler)`` - a ``BaseHTTPRequestHandler`` shim in the
    same shape as ``api_endpoint.handle_conversation_process``, so the Hub's
    unified API server (ical-server.py on :8090) can expose
    ``GET /api/v1/reply-debt`` for the daily brief to hit. The assistant daemon
    already reads its fallback brief from :8090; this gives it a "you owe a
    reply to N people" datum to read.

Daily-brief wiring (NOT applied here - documented for the owner):
  1. ical-server.py do_GET routing:
         elif path == '/api/v1/reply-debt':
             handle_reply_debt(self)
  2. The PRIMARY brief is an LLM cron job in ostler-assistant whose prompt is
     the section spec; add a line: "If GET /api/v1/reply-debt returns owed
     replies, lead the brief with 'You owe a reply to N people' and name the
     top 3." The FALLBACK brief (zeroclaw-runtime brief/fallback.rs) can add a
     FallbackBriefData field that fetches the same endpoint.

Proven vs not: the service + endpoint logic is unit-tested with injected
threads. The live feed (iMessage chat.db) needs the box + Full Disk Access and
is UNPROVEN on real data until run there.
"""
from __future__ import annotations

import json
import logging
from http.server import BaseHTTPRequestHandler
from typing import Callable, Iterable, Optional

from . import reply_debt
from . import reply_debt_adapters as adapters
from . import reply_debt_store_adapter as store_adapter
from .reply_debt import ReplyDebt, Thread

logger = logging.getLogger(__name__)


def compute_reply_debts(
    *,
    thread_sources: Optional[Iterable[Iterable[Thread]]] = None,
    strength_lookup: Optional[Callable] = None,
    threshold_hours: float = reply_debt.DEFAULT_THRESHOLD_HOURS,
    min_score: float = reply_debt.DEFAULT_MIN_SCORE,
    include_group: bool = False,
    lookback_days: int = 90,
) -> list[ReplyDebt]:
    """Compute ranked reply debts across all sources.

    ``thread_sources`` lets a test inject pre-built thread iterables. When
    omitted, the default live sources are:

      * the iMessage chat.db adapter -- the strongest direction signal, but
        box-only (needs Full Disk Access); silently yields nothing off-box.
      * the conversation-store adapter -- reads the on-disk bundles
        (WhatsApp / email / meeting threads) and is provable off-box. iMessage
        bundles are skipped there to avoid double-counting with chat.db.

    Both default sources are isolated below: a failure in one (a chat.db read
    error, an unreadable bundle) does not sink the other.
    """
    if thread_sources is None:
        thread_sources = [
            adapters.iter_imessage_threads(
                strength_lookup=strength_lookup,
                lookback_days=lookback_days,
            ),
            store_adapter.iter_store_threads(
                strength_lookup=strength_lookup,
                lookback_days=lookback_days,
            ),
        ]

    all_threads: list[Thread] = []
    for src in thread_sources:
        try:
            all_threads.extend(src)
        except Exception as exc:  # pragma: no cover - source failures are
            # isolated so one bad adapter does not sink the whole brief datum
            logger.warning("reply_debt: source failed, skipping: %s", exc)

    return reply_debt.detect(
        all_threads,
        threshold_hours=threshold_hours,
        min_score=min_score,
        include_group=include_group,
    )


def reply_debt_payload(debts: list[ReplyDebt], *, brief_limit: int = 5) -> dict:
    """Shape the API/JSON payload the brief + wiki consume."""
    return {
        "count": len(debts),
        "brief_line": reply_debt.render_brief_block(debts, limit=brief_limit),
        "debts": [d.to_dict() for d in debts],
    }


def handle_reply_debt(handler: BaseHTTPRequestHandler) -> None:
    """Handle GET /api/v1/reply-debt.

    Mirrors api_endpoint._send_json's response shape. Never raises out to the
    server: any failure returns an empty (count 0) payload so the brief simply
    omits the section rather than going red.
    """
    try:
        debts = compute_reply_debts()
        payload = reply_debt_payload(debts)
        status = 200
    except Exception as exc:  # pragma: no cover - defensive
        logger.warning("reply_debt endpoint failed: %s", exc)
        payload = {"count": 0, "brief_line": "", "debts": [], "error": str(exc)}
        status = 200  # brief should degrade gracefully, not 500

    body = json.dumps(payload, indent=2).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


__all__ = [
    "compute_reply_debts",
    "reply_debt_payload",
    "handle_reply_debt",
]
