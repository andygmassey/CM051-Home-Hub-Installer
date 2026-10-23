"""Local web search (Vane) readiness tile + Retry for Ostler Doctor.

CM051-only (declared in vendor/VENDOR_ONLY.tsv). Reads the state file the
background fetcher ``~/.ostler/bin/ostler-vane-fetch`` writes, and kicks
that fetcher's LaunchAgent when the customer presses Retry.

Why it exists (v1.0.118, W5 + W8)
---------------------------------

The Vane image is about 3.4 GB. The installer used to pull it inside the
install; on a slow link that took close to two hours, and on one console
install it died part-way while the install still reported every step done.
The download now happens in the background after the install. That makes a
new, normal state -- web search is not there YET -- and this tile is where a
customer sees it, instead of a search tool that silently does not work.

States (from ``~/.ostler/state/vane-fetch.json``, written by the fetcher)
-----------------------------------------------------------------------

* ``ready``      Vane answered the install's own credential. Green.
* ``deferred``   waiting for the install to finish before downloading.
* ``starting``   image present, container starting.
* ``pulling``    a download attempt is running (try N of M).
* ``retrying``   an attempt stopped early; the next one is scheduled.
* ``waiting``    this run is out of tries; launchd starts the next run at
                 login, boot or within the hour.

Every state except ``ready`` renders "Web search not ready yet" with a
Retry button. A state file that is ABSENT renders nothing: that is an
install from before the fetcher existed, and saying "not ready" there would
be a claim about something this build never set up. A file that is present
but unreadable, or names a state this module does not know, renders
"could not check" -- never green, never hidden.
"""
from __future__ import annotations

import html
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Optional

FETCH_LABEL = "com.ostler.vane-fetch"

STATUS_READY = "ready"
STATUS_NOT_READY = "not-ready"
STATUS_CHECK_FAILED = "check-failed"
STATUS_ABSENT = "absent"

_KNOWN_PENDING = ("deferred", "starting", "pulling", "retrying", "waiting")

_SECTION_TITLE = "Web search"
_TITLE_READY = "Web search ready"
_TITLE_NOT_READY = "Web search not ready yet"
_TITLE_CHECK_FAILED = "Web search status could not be checked"
_RETRY_LABEL = "Retry now"

_COLOURS = {
    STATUS_READY: "#2C4A2C",
    STATUS_NOT_READY: "#5C4611",
    STATUS_CHECK_FAILED: "#7A1F1F",
}
_ICONS = {
    STATUS_READY: "&#10003;",
    STATUS_NOT_READY: "&#8987;",
    STATUS_CHECK_FAILED: "&#9888;",
}


def _state_path(ostler_dir: Optional[os.PathLike] = None) -> Path:
    base = Path(ostler_dir) if ostler_dir else Path(
        os.environ.get("OSTLER_DIR") or (Path.home() / ".ostler")
    )
    return base / "state" / "vane-fetch.json"


def read_web_search_state(ostler_dir: Optional[os.PathLike] = None) -> dict:
    """Classify the fetcher's state file. Never raises.

    Returns a dict with ``status`` (one of the STATUS_* constants) plus the
    raw fields that were readable.
    """
    path = _state_path(ostler_dir)
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {"status": STATUS_ABSENT}
    except OSError as exc:
        return {"status": STATUS_CHECK_FAILED, "reason": f"unreadable: {exc.__class__.__name__}"}
    try:
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError("not an object")
    except ValueError:
        return {"status": STATUS_CHECK_FAILED, "reason": "malformed state file"}

    state = data.get("state")
    out = dict(data)
    out["fetch_state"] = state
    if state == "ready":
        out["status"] = STATUS_READY
    elif state in _KNOWN_PENDING:
        out["status"] = STATUS_NOT_READY
    else:
        out["status"] = STATUS_CHECK_FAILED
        out["reason"] = "unknown state"
    return out


def _int(v) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0


def _clock(epoch: int) -> str:
    try:
        return time.strftime("%H:%M", time.localtime(epoch))
    except (OverflowError, ValueError, OSError):
        return ""


def _detail_for(st: dict) -> str:
    """Customer copy for a not-ready state, with progress where it is cheap."""
    fetch_state = st.get("fetch_state")
    attempt = _int(st.get("attempt"))
    max_tries = _int(st.get("max_tries"))
    layers = _int(st.get("layers_done"))
    tries = f" (try {attempt} of {max_tries})" if attempt and max_tries else ""
    parts = f" {layers} parts downloaded so far." if layers else ""
    if fetch_state == "deferred":
        return "The web search engine downloads once setup has finished. Everything else works meanwhile."
    if fetch_state == "starting":
        return "The web search engine is downloaded and starting up."
    if fetch_state == "pulling":
        return f"Downloading the web search engine (about 3.5 GB){tries}.{parts}"
    if fetch_state == "retrying":
        at = _clock(_int(st.get("next_try_at")))
        when = f" at {at}" if at else " shortly"
        return (
            f"The last download attempt stopped early{tries}. Ostler tries again{when}, "
            f"and keeps what it has already downloaded.{parts}"
        )
    if fetch_state == "waiting":
        return (
            "Several download attempts stopped early. Ostler tries again within the "
            "hour and each time your Mac starts, keeping what it has already "
            "downloaded. To try now, use the Retry button."
        )
    return "Web search is getting ready."


def render_web_search_status(ostler_dir: Optional[os.PathLike] = None) -> str:
    """Render the web search tile as static HTML ('' when nothing to show)."""
    st = read_web_search_state(ostler_dir)
    status = st.get("status")
    if status == STATUS_ABSENT:
        return ""

    if status == STATUS_READY:
        title, detail = _TITLE_READY, "Your assistant can search the web through the local search engine."
    elif status == STATUS_NOT_READY:
        title, detail = _TITLE_NOT_READY, _detail_for(st)
    else:
        title = _TITLE_CHECK_FAILED
        detail = "Ostler could not read the web search download status. To check again, use the Retry button."
        status = STATUS_CHECK_FAILED

    retry = ""
    if status != STATUS_READY:
        retry = (
            '\n                <div style="margin-top:8px">'
            '<button class="copy-btn" id="webSearchRetry" '
            "onclick=\"this.disabled=true;fetch('/api/v1/web-search/retry',{method:'POST'})"
            ".then(function(){location.reload();})"
            ".catch(function(){location.reload();})\">"
            f"{html.escape(_RETRY_LABEL)}</button></div>"
        )

    return f"""
    <div class="section" id="webSearchStatusSection">
        <div class="section-title">{html.escape(_SECTION_TITLE)}</div>
        <div class="status-grid">
        <div class="status-card">
            <div class="status-indicator" style="background:{_COLOURS[status]}">{_ICONS[status]}</div>
            <div class="status-info">
                <div class="status-name">{html.escape(title)}</div>
                <div class="status-detail">{html.escape(detail)}</div>{retry}
            </div>
        </div>
        </div>
    </div>"""


def retry_web_search(ostler_dir: Optional[os.PathLike] = None) -> dict:
    """Start the fetcher now. Returns ``{ok, detail, state}``.

    An attempt that is already downloading is LEFT ALONE: restarting it
    would throw away the layer in flight. Any other state is restarted with
    ``kickstart -k``, which cuts a backoff wait short.
    """
    st = read_web_search_state(ostler_dir)
    if st.get("fetch_state") == "pulling":
        return {"ok": True, "detail": "already downloading", "state": "pulling"}
    if st.get("status") == STATUS_READY:
        return {"ok": True, "detail": "already ready", "state": "ready"}
    launchctl = os.environ.get("OSTLER_LAUNCHCTL", "/bin/launchctl")
    target = f"gui/{os.getuid()}/{FETCH_LABEL}"
    try:
        proc = subprocess.run(
            [launchctl, "kickstart", "-k", target],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "detail": f"could not start the download: {exc.__class__.__name__}",
                "state": st.get("fetch_state")}
    if proc.returncode != 0:
        return {"ok": False, "detail": f"launchctl kickstart exited {proc.returncode}",
                "state": st.get("fetch_state")}
    return {"ok": True, "detail": "download restarted", "state": st.get("fetch_state")}
