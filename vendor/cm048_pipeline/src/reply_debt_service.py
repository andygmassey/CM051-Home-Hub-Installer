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
threads and a synthetic snapshot. The live feed is the snapshot written by the
iMessage feed (``ostler-assistant run-source imessage``); this process never
opens chat.db, so it never asks TCC for Full Disk Access.
"""
from __future__ import annotations

import json
import logging
from http.server import BaseHTTPRequestHandler
from typing import Callable, Iterable, Optional

from . import reply_debt
from . import reply_debt_adapters as adapters
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
    omitted, the default live source is the iMessage adapter, which reads the
    snapshot the signed iMessage feed writes (never chat.db from this process). Email / WhatsApp adapters can be appended here
    as they are proven on the box.
    """
    if thread_sources is None:
        thread_sources = [
            adapters.iter_imessage_threads(
                strength_lookup=strength_lookup,
                lookback_days=lookback_days,
            ),
        ]

    # A source that could not be read is NOT a source with nothing owed. This
    # loop used to log and skip a failing source, so a Hub that could not read
    # Messages at all answered "No replies owed - you're all caught up." with
    # degraded:false (CM051 #30, studio29). Any unreadable source now raises,
    # and the endpoint turns that into degraded:true with the reason.
    all_threads: list[Thread] = []
    for src in thread_sources:
        try:
            all_threads.extend(src)
        except adapters.ReplyDebtSourceUnavailable:
            raise
        except Exception as exc:
            logger.warning("reply_debt: source failed: %s", exc)
            raise adapters.ReplyDebtSourceUnavailable(
                "reply_debt_source_failed", f"{type(exc).__name__}: {str(exc)[:200]}"
            ) from exc

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
        "degraded": False,
    }


def degraded_payload(reason: str, detail: str = "") -> dict:
    """The ONLY shape an unreadable source may produce: no all-clear copy."""
    out = {"count": 0, "brief_line": "", "debts": [], "degraded": True,
           "reason": reason}
    if detail:
        out["detail"] = detail[:200]
    return out


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
    except adapters.ReplyDebtSourceUnavailable as exc:
        payload = degraded_payload(exc.reason, exc.detail)
        status = 200
    except Exception as exc:  # pragma: no cover - defensive
        logger.warning("reply_debt endpoint failed: %s", exc)
        payload = degraded_payload("reply_debt_failed", str(exc))
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
    "degraded_payload",
    "handle_reply_debt",
]
