"""Route 2: the owner's own internal Slack app, user token (``xoxp-``).

The owner creates a private app in their own workspace (see
``docs/SLACK_SETUP_DRAFT.md``) and pastes its user token. There is no
Ostler-published Slack app and no Ostler client id: the 2025 Slack API
Terms forbid third-party apps from bulk export and persistent archives, and
non-Marketplace distributed apps are limited to 1 request/min. Internal
customer-built apps keep Tier 3 limits (Slack changelog 2025-05-29).

Ported from the ZeroClaw Slack channel (ostler-assistant
``crates/zeroclaw-channels/src/slack.rs``): ``parse_retry_after_value``
(integer or fractional seconds), ``compute_exponential_backoff_delay``
(Retry-After x 2^attempt, capped at 120 s, plus up to 500 ms jitter), and
treating both HTTP 429 and ``{"ok": false, "error": "ratelimited"}`` as a
rate limit. NOT ported: the channel's "retries exhausted -> proceed without
history", which for an importer is a silent empty. Here exhaustion raises
``SlackRateLimited`` and the caller does not advance that channel's cursor.

The token travels only in the ``Authorization`` header. It is never put in
a URL, an exception message or a log line.
"""
from __future__ import annotations

import logging
import random
import time
from collections.abc import Callable, Iterator
from typing import Any

import httpx

log = logging.getLogger(__name__)

API_BASE = "https://slack.com/api/"
MAX_RETRIES = 5
DEFAULT_RETRY_AFTER_SECS = 1.0
MAX_BACKOFF_SECS = 120.0
MAX_JITTER_MS = 500
PAGE_LIMIT = 200
CONVERSATION_TYPES = "public_channel,private_channel,mpim,im"


class SlackApiError(Exception):
    """Slack answered ``ok: false`` with a non-rate-limit error."""

    def __init__(self, method: str, error: str, needed: str | None = None):
        self.method = method
        self.error = error
        self.needed = needed
        hint = f" (needs scope {needed})" if needed else ""
        super().__init__(f"Slack {method} failed: {error}{hint}")


class SlackRateLimited(Exception):
    """Rate-limit retries exhausted. A CANNOT-RUN, never an empty result."""


def parse_retry_after(value: str | None) -> float | None:
    """Port of ZeroClaw ``parse_retry_after_value``: integer seconds, or the
    whole part of a fractional value. None for empty or garbage."""
    if value is None:
        return None
    value = value.strip()
    if not value:
        return None
    whole = value.split(".", 1)[0]
    return float(whole) if whole.isdigit() else None


def backoff_delay(retry_after: float, attempt: int, jitter_ms: int) -> float:
    """Port of ZeroClaw ``compute_exponential_backoff_delay``."""
    return min(retry_after * (2 ** attempt), MAX_BACKOFF_SECS) + jitter_ms / 1000.0


class SlackClient:
    def __init__(
        self,
        token: str,
        *,
        transport: httpx.BaseTransport | None = None,
        sleep: Callable[[float], None] = time.sleep,
        pace_secs: float = 1.2,
        jitter: Callable[[int], int] = lambda hi: random.randint(0, hi),
    ):
        self._client = httpx.Client(
            base_url=API_BASE,
            headers={"Authorization": f"Bearer {token}"},
            timeout=30.0,
            transport=transport,
        )
        self._sleep = sleep
        self._pace = pace_secs  # ~50 calls/min keeps inside Tier 3 by default
        self._jitter = jitter
        self.calls = 0

    def close(self) -> None:
        self._client.close()

    def call(self, method: str, params: dict[str, Any] | None = None) -> dict:
        for attempt in range(MAX_RETRIES + 1):
            if self.calls and self._pace:
                self._sleep(self._pace)
            self.calls += 1
            resp = self._client.get(method, params=params or {})
            try:
                payload = resp.json()
            except ValueError:
                payload = {}
            limited = resp.status_code == 429 or (
                payload.get("ok") is False and payload.get("error") == "ratelimited"
            )
            if limited:
                if attempt >= MAX_RETRIES:
                    raise SlackRateLimited(
                        f"Slack {method} still rate limited after {MAX_RETRIES} retries"
                    )
                base = parse_retry_after(resp.headers.get("Retry-After"))
                wait = backoff_delay(
                    base if base is not None else DEFAULT_RETRY_AFTER_SECS,
                    attempt,
                    self._jitter(MAX_JITTER_MS),
                )
                log.warning(
                    "Slack %s rate limited; retry %d/%d in %.1fs",
                    method, attempt + 1, MAX_RETRIES, wait,
                )
                self._sleep(wait)
                continue
            if resp.status_code >= 400:
                raise SlackApiError(method, f"http_{resp.status_code}")
            if payload.get("ok") is not True:
                raise SlackApiError(
                    method, str(payload.get("error") or "unknown"), payload.get("needed")
                )
            return payload
        raise SlackRateLimited(f"Slack {method} rate limited")  # pragma: no cover

    def paged(self, method: str, key: str, params: dict[str, Any]) -> Iterator[dict]:
        cursor: str | None = None
        while True:
            p = dict(params, limit=PAGE_LIMIT)
            if cursor:
                p["cursor"] = cursor
            payload = self.call(method, p)
            for item in payload.get(key) or []:
                if isinstance(item, dict):
                    yield item
            cursor = (payload.get("response_metadata") or {}).get("next_cursor") or None
            if not cursor:
                return

    # -- endpoints -----------------------------------------------------------

    def auth_test(self) -> dict:
        return self.call("auth.test")

    def users(self) -> list[dict]:
        return list(self.paged("users.list", "members", {}))

    def user_info(self, user_id: str) -> dict | None:
        try:
            return self.call("users.info", {"user": user_id}).get("user")
        except SlackApiError:
            return None

    def my_conversations(self) -> list[dict]:
        """Only conversations the owner is a member of (``users.conversations``),
        never the whole workspace's public channels."""
        return list(
            self.paged(
                "users.conversations", "channels",
                {"types": CONVERSATION_TYPES, "exclude_archived": "false"},
            )
        )

    def history(self, channel_id: str, oldest: str) -> list[dict]:
        return list(
            self.paged(
                "conversations.history", "messages",
                {"channel": channel_id, "oldest": oldest, "inclusive": "true"},
            )
        )

    def replies(self, channel_id: str, thread_ts: str) -> list[dict]:
        return list(
            self.paged(
                "conversations.replies", "messages",
                {"channel": channel_id, "ts": thread_ts},
            )
        )
