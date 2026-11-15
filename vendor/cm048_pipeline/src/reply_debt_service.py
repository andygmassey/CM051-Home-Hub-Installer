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
from . import reply_debt_sources as sources
from .reply_debt import ReplyDebt, Thread

logger = logging.getLogger(__name__)


# The live channels, in the order the brief names them.
LIVE_CHANNELS = ("imessage", "whatsapp", "email")


def _imessage_loader(*, directory, strength_lookup, lookback_days):
    return list(adapters.iter_imessage_threads(
        strength_lookup=strength_lookup, lookback_days=lookback_days,
    )), {}


def _snapshot_loader(channel):
    def load(*, directory, strength_lookup, lookback_days):
        read = sources.load_channel(channel, directory=directory, lookback_days=lookback_days)
        return read.threads, read.excluded
    return load


def default_channel_loaders() -> dict:
    return {
        "imessage": _imessage_loader,
        "whatsapp": _snapshot_loader("whatsapp"),
        "email": _snapshot_loader("email"),
    }


def compute_reply_debts(
    *,
    thread_sources: Optional[Iterable[Iterable[Thread]]] = None,
    strength_lookup: Optional[Callable] = None,
    threshold_hours: float = reply_debt.DEFAULT_THRESHOLD_HOURS,
    min_score: float = reply_debt.DEFAULT_MIN_SCORE,
    include_group: bool = False,
    lookback_days: int = 90,
    directory=None,
    channel_loaders: Optional[dict] = None,
) -> list[ReplyDebt]:
    """Compute ranked reply debts across all sources.

    ``thread_sources`` lets a test inject pre-built thread iterables (no
    channel bookkeeping). Otherwise every channel in ``LIVE_CHANNELS`` is read
    through ``channel_loaders`` (default: the iMessage, WhatsApp and email
    snapshots the signed feeds write; this process never opens a protected
    store). Per channel:

      * read: its threads join the list and it is named in ``sources``;
      * ``<channel>_not_connected``: the install never set it up, so it is
        neither read nor named;
      * any other ``ReplyDebtSourceUnavailable``: it is connected but could
        not be checked; recorded in ``channels`` and ``partial`` is set.

    When NO channel could be read, the first failure (in channel order, a
    connected-but-unreadable channel before a not-connected one) is raised, so the endpoint answers degraded:true with that reason exactly as
    the iMessage-only service did.
    """
    names_degraded = ""
    excluded: Optional[dict] = None
    channels: Optional[dict] = None
    read_order: list[str] = []
    all_threads: list[Thread] = []

    if thread_sources is not None:
        # A source that could not be read is NOT a source with nothing owed
        # (CM051 #30, studio29): any unreadable injected source raises.
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
    else:
        # P13: the directory first, because the WhatsApp and email rules ask
        # it who the owner is and who is carded.
        if directory is None:
            from . import handle_resolver
            directory, names_degraded = handle_resolver.build_directory()
        loaders = channel_loaders if channel_loaders is not None else default_channel_loaders()
        channels = {}
        failures: list[adapters.ReplyDebtSourceUnavailable] = []
        channel_excluded: dict[str, int] = {}
        for channel in LIVE_CHANNELS:
            load = loaders.get(channel)
            if load is None:
                continue
            try:
                threads, dropped = load(
                    directory=directory,
                    strength_lookup=strength_lookup,
                    lookback_days=lookback_days,
                )
            except adapters.ReplyDebtSourceUnavailable as exc:
                if exc.reason.endswith("_not_connected"):
                    channels[channel] = {"status": "not_connected"}
                else:
                    channels[channel] = {"status": "unavailable", "reason": exc.reason}
                failures.append(exc)
                continue
            except Exception as exc:
                logger.warning("reply_debt: %s source failed: %s", channel, exc)
                wrapped = adapters.ReplyDebtSourceUnavailable(
                    "reply_debt_source_failed", f"{type(exc).__name__}: {str(exc)[:200]}"
                )
                channels[channel] = {"status": "unavailable", "reason": wrapped.reason}
                failures.append(wrapped)
                continue
            channels[channel] = {"status": "read"}
            read_order.append(channel)
            all_threads.extend(threads)
            for reason, n in (dropped or {}).items():
                key = f"{channel}_{reason}"
                channel_excluded[key] = channel_excluded.get(key, 0) + n
        if not read_order:
            # A connected channel that could not be checked outranks one that
            # was never set up: "couldn't check" must not read as "not set up".
            failures.sort(key=lambda e: e.reason.endswith("_not_connected"))
            raise failures[0] if failures else adapters.ReplyDebtSourceUnavailable(
                "no_reply_debt_channel", "no channel loader configured"
            )
        excluded = dict(channel_excluded)

    # P13 (v1.0.117 walk): name every counterpart from Contacts, and drop the
    # owner's own handles and non-person senders, BEFORE detection. The live
    # path always looks handles up; an injected source does when the caller
    # passes a directory. See reply_debt.identify_threads.
    if directory is not None:
        all_threads, identified = reply_debt.identify_threads(all_threads, directory)
        excluded = {**(excluded or {}), **identified}

    out = DebtList(reply_debt.detect(
        all_threads,
        threshold_hours=threshold_hours,
        min_score=min_score,
        include_group=include_group,
    ))
    out.excluded = excluded
    out.names_degraded = names_degraded
    out.sources = read_order
    out.channels = channels
    return out


class DebtList(list):
    """A ranked debt list that remembers what identification dropped, and
    keeps it across slicing (the endpoint slices to ``limit``)."""

    excluded = None
    names_degraded = ""
    sources: list = []
    channels = None

    def __getitem__(self, item):
        got = super().__getitem__(item)
        if isinstance(item, slice):
            got = DebtList(got)
            got.excluded = self.excluded
            got.names_degraded = self.names_degraded
            got.sources = self.sources
            got.channels = self.channels
        return got


def reply_debt_payload(debts: list[ReplyDebt], *, brief_limit: int = 5) -> dict:
    """Shape the API/JSON payload the brief + wiki consume."""
    payload = {
        "count": len(debts),
        "brief_line": reply_debt.render_brief_block(
            debts, limit=brief_limit,
            names_unavailable=bool(getattr(debts, "names_degraded", "")),
        ),
        "debts": [d.to_dict() for d in debts],
        # Counted, never silently dropped: the owner's own handles and
        # non-person senders (short codes, sender ids, no-reply mailboxes).
        "excluded": getattr(debts, "excluded", None),
        # Set when the People graph could not be read, so every counterpart
        # reads "not in your contacts" for a reason the consumer can show.
        "names_degraded": getattr(debts, "names_degraded", "") or "",
        "degraded": False,
    }
    # The channels actually read, which the brief heading names (oa
    # brief/catchup.rs ReplyDebtBody.sources), and each channel's state. A
    # connected channel that could not be checked sets ``partial``: the list
    # is then complete only for the channels in ``sources``.
    channels = getattr(debts, "channels", None)
    if channels is not None:
        payload["sources"] = list(getattr(debts, "sources", []) or [])
        payload["channels"] = channels
        payload["partial"] = any(c.get("status") == "unavailable" for c in channels.values())
    return payload


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
