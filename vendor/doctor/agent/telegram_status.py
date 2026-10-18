"""Telegram channel tile for the Doctor dashboard.

GRAFTED (CM051, public-launch Telegram). Reads
``${OSTLER_HOME:-~/.ostler}/state/telegram_channel.json``, written by the
assistant's Telegram channel (ostler-assistant
``crates/zeroclaw-channels/src/telegram_ostler.rs``, ``TelegramStatus``). The
field names below are that struct's; the contract fixture
``tests/fixtures/telegram_channel_status.json`` is asserted on both sides.

No file = Telegram was never switched on = no tile. A status this reader does
not know is shown as nothing and logged, never rendered verbatim.

Never raises: this runs on the dashboard render path, where an exception
blanks the whole page.
"""
from __future__ import annotations

import html
import json
import logging
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

log = logging.getLogger(__name__)

STATE_FILENAME = "telegram_channel.json"
STATUSES = ("starting", "connected", "config_error", "api_error")

SECTION_TITLE = "Telegram"
LABELS = {
    "connected": "Connected",
    "starting": "Starting",
    "config_error": "Not running",
    "api_error": "Telegram refused the connection",
}
COLOURS = {
    "connected": "#2C4A2C",
    "starting": "rgba(236,232,221,0.40)",
    "config_error": "#5C4611",
    "api_error": "#7A1F1F",
}
ICONS = {
    "connected": "&#10003;",
    "starting": "&#8211;",
    "config_error": "&#9888;",
    "api_error": "&#10007;",
}
SETUP_HINT = "To set it up again, run ~/.ostler/bin/ostler-telegram-setup in Terminal."


@dataclass
class TelegramStatus:
    status: str
    bot_username: Optional[str]
    last_owner_message_at: Optional[str]
    non_owner_dropped: int
    last_error: Optional[str]
    updated_at: Optional[str]


def state_path() -> Path:
    base = os.environ.get("OSTLER_HOME") or os.environ.get("OSTLER_DIR")
    root = Path(base) if base else Path.home() / ".ostler"
    return root / "state" / STATE_FILENAME


def _opt_str(v) -> Optional[str]:
    return v.strip() if isinstance(v, str) and v.strip() else None


def read_telegram_status(path: Optional[Path] = None) -> Optional[TelegramStatus]:
    target = path if path is not None else state_path()
    try:
        if not target.is_file():
            return None
        payload = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as exc:
        log.warning("telegram status unreadable at %s: %s", target, exc)
        return None
    if not isinstance(payload, dict):
        return None
    status = payload.get("status")
    if status not in STATUSES:
        log.warning("telegram status at %s carries an unrecognised status", target)
        return None
    dropped = payload.get("non_owner_dropped")
    if isinstance(dropped, bool) or not isinstance(dropped, int) or dropped < 0:
        dropped = 0
    return TelegramStatus(
        status=status,
        bot_username=_opt_str(payload.get("bot_username")),
        last_owner_message_at=_opt_str(payload.get("last_owner_message_at")),
        non_owner_dropped=dropped,
        last_error=_opt_str(payload.get("last_error")),
        updated_at=_opt_str(payload.get("updated_at")),
    )


def _relative(ts: Optional[str], now_dt: Optional[datetime]) -> Optional[str]:
    if not ts:
        return None
    try:
        t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    now = now_dt or datetime.now(timezone.utc)
    secs = int((now - t).total_seconds())
    if secs < 0:
        return "just now"
    for unit, n in (("day", 86400), ("hour", 3600), ("minute", 60)):
        if secs >= n:
            k = secs // n
            return f"{k} {unit}{'s' if k != 1 else ''} ago"
    return "just now"


def render_telegram_status(now_dt: Optional[datetime] = None, path: Optional[Path] = None) -> str:
    st = read_telegram_status(path)
    if st is None:
        return ""
    e = html.escape
    lines = []
    if st.bot_username:
        lines.append(f"Bot: @{st.bot_username}")
    rel = _relative(st.last_owner_message_at, now_dt)
    lines.append(f"Your last message: {rel}" if rel else "No message from you yet")
    if st.non_owner_dropped:
        n = st.non_owner_dropped
        lines.append(f"Ignored {n} message{'s' if n != 1 else ''} from other people "
                     "(only you can talk to your assistant)")
    if st.status in ("config_error", "api_error"):
        if st.last_error:
            lines.append(st.last_error)
        lines.append(SETUP_HINT)
    detail = "".join(f'<div class="status-detail">{e(x)}</div>' for x in lines)
    return f"""
    <div class="section" id="telegramChannelSection">
        <div class="section-title">{e(SECTION_TITLE)}</div>
        <div class="status-grid">
            <div class="status-card" style="border-left:3px solid {COLOURS[st.status]}">
                <div class="status-label">{ICONS[st.status]} {e(LABELS[st.status])}</div>
                {detail}
            </div>
        </div>
    </div>"""
