"""Front Page setup cards: the Safari extension and RemoteCapture.

Two capture surfaces ship on every Hub but do nothing until the customer
switches them on, and nothing on the Front Page told them so. These cards do,
and leave the moment the surface is working.

Each card follows the CM051 #2878 rule (walk #27): a card never appears
without a working action. So a card is held back unless the thing its button
opens is actually on this Mac.

  card                 shown when                       hidden when
  -------------------  -------------------------------  -------------------------------
  browser_extension    the Safari extension app is      the Hub has received a page
                       installed in /Applications/      from the extension
                       Ostler                           (browsing_capture.json carries
                                                        last_write_ts or last_skipped_ts)
  remote_capture       the RemoteCapture app is         the Hub has received a capture
                       installed in /Applications/      from it (a processing dir whose
                       Ostler                           00_metadata.json says
                                                        capture_source cm042_mac)

Both are also dismissible for good (the ordinary ``drop`` verb; each card
carries a ``sources`` key so the feedback route has something to drop).

WHERE THE SIGNALS COME FROM
  * browsing_capture.json is written ONLY by the Hub's extension ingest route
    (ical-server.py ``_safari_write_state``, POST /api/safari/ingest), so a
    value there means the extension is on, paired and sending.
  * 00_metadata.json is written by CM048's processor (``_write_raw``) for every
    conversation it receives; RemoteCapture (CM042 HubConversationClient and
    the spoken_source feed) stamps ``capture_source: cm042_mac``. That lives in
    the engine room (~/.ostler/processing), which this LaunchAgent can read
    without a Files and Folders prompt. The customer-facing bundle under
    ~/Documents is deliberately NOT read here: a launchd python reading
    ~/Documents raises a TCC prompt or fails.

Only Safari is offered: no Chrome extension ships (CM051 install.sh section
3.17, OSTLER_CHROME_WEBSTORE_URL is empty). Chrome history is read through Full
Disk Access instead.

Stdlib only. Never raises: an unreadable signal reads as "not set up yet",
which shows the card, the harmless side.
"""
from __future__ import annotations

import json
import os
from datetime import datetime

APPS_DIR_DEFAULT = "/Applications/Ostler"
SAFARI_EXTENSION_APP = "Ostler Safari Extension.app"
REMOTE_CAPTURE_APP = "Ostler RemoteCapture.app"
REMOTE_CAPTURE_SOURCE = "cm042_mac"

# The action kinds the Hub app routes (ostler-assistant
# web/src/lib/frontpageActions.ts). A kind the app does not know renders no
# button, so these two names are a contract across both repos.
ACTION_OPEN_SAFARI_EXTENSION = "open_safari_extension"
ACTION_OPEN_REMOTE_CAPTURE = "open_remote_capture"

# Below the confirm-interests onboarding card (80), above interests (<=60).
PRIORITY_SETUP = 70.0

# A processing tree is one dir per conversation; cap the scan so a large
# history costs a bounded number of stats per hourly tick.
_MAX_PROCESSING_DIRS = 5000


def _apps_dirs() -> list[str]:
    """Where the installer stages Ostler's apps. /Applications/Ostler is the
    current home; the bare /Applications path is the pre-relocation one
    (install.sh _ostler_relocate_app still moves it, but a box mid-upgrade can
    have either)."""
    primary = os.environ.get("OSTLER_APPS_DIR") or APPS_DIR_DEFAULT
    out = [primary]
    if "/Applications" not in out:
        out.append("/Applications")
    return out


def _app_installed(name: str, apps_dirs: list[str]) -> bool:
    return any(os.path.isdir(os.path.join(d, name)) for d in apps_dirs)


def _browsing_state_path() -> str:
    return os.path.expanduser(
        os.environ.get("OSTLER_BROWSING_STATE_PATH")
        or "~/.ostler/state/browsing_capture.json")


def _processing_dir() -> str:
    # NOT OSTLER_STATE_DIR: CM048 reads that name as its processing dir while
    # this package reads it as ~/.ostler/state, so honouring it here would
    # point one of the two at the wrong tree.
    return os.path.expanduser(
        os.environ.get("OSTLER_PROCESSING_DIR") or "~/.ostler/processing")


def extension_active(path: str | None = None) -> bool:
    """True once the Hub has taken a page from the extension. A skipped
    (sensitive-domain) page counts: the extension is on and talking."""
    try:
        with open(path or _browsing_state_path(), encoding="utf-8") as fh:
            state = json.load(fh)
    except Exception:  # noqa: BLE001 - missing / unreadable = not yet
        return False
    if not isinstance(state, dict):
        return False
    return any(isinstance(state.get(k), (int, float)) and state.get(k) > 0
               for k in ("last_write_ts", "last_skipped_ts"))


def remote_capture_used(processing_dir: str | None = None) -> bool:
    """True once any conversation the Hub received came from RemoteCapture."""
    root = processing_dir or _processing_dir()
    try:
        entries = os.listdir(root)
    except Exception:  # noqa: BLE001
        return False
    for name in entries[:_MAX_PROCESSING_DIRS]:
        meta = os.path.join(root, name, "00_metadata.json")
        try:
            with open(meta, encoding="utf-8") as fh:
                data = json.load(fh)
        except Exception:  # noqa: BLE001
            continue
        if isinstance(data, dict) and data.get("capture_source") == REMOTE_CAPTURE_SOURCE:
            return True
    return False


def read_setup_state(*, apps_dirs: list[str] | None = None,
                     browsing_state_path: str | None = None,
                     processing_dir: str | None = None) -> dict:
    """What the two setup cards need to know, read from this Mac."""
    dirs = apps_dirs if apps_dirs is not None else _apps_dirs()
    return {
        "browser_extension": {
            "installed": _app_installed(SAFARI_EXTENSION_APP, dirs),
            "active": extension_active(browsing_state_path),
        },
        "remote_capture": {
            "installed": _app_installed(REMOTE_CAPTURE_APP, dirs),
            "used": remote_capture_used(processing_dir),
        },
    }


def _card(make_card, key: str, *, title: str, body: str, evidence: str,
          label: str, action_kind: str, now: datetime) -> dict:
    card = make_card(
        "onboarding", f"setup_{key}", title=title, body=body, now=now,
        priority=PRIORITY_SETUP,
        action={"label": label, "kind": action_kind},
        evidence=evidence, source=f"ostler:setup_{key}",
        privacy="L1",  # Ostler's own setup copy; about the operator, no PII
    )
    # The dismiss control drops this key; without a key the feedback route
    # refuses a drop ("interest_id required"), and the card could not go.
    card["sources"] = [f"setup::{key}"]
    card["dismissible"] = True
    return card


def browser_extension_card(now: datetime, make_card) -> dict:
    return _card(
        make_card, "browser_extension",
        title="Add Ostler to Safari",
        body=("Ostler can keep a record of the pages you read in Safari, saved "
              "only to this Mac, so it can tell you what you read and connect "
              "it to the rest of your world. In the window that opens, choose "
              "Open Safari Preferences, then tick the box next to the "
              "extension."),
        evidence="Works with Safari on this Mac",
        label="Turn it on in Safari",
        action_kind=ACTION_OPEN_SAFARI_EXTENSION, now=now)


def remote_capture_card(now: datetime, make_card) -> dict:
    return _card(
        make_card, "remote_capture",
        title="Transcribe your calls with RemoteCapture",
        body=("RemoteCapture transcribes your Zoom, Teams, Meet and FaceTime "
              "calls right here on your Mac. No bot joins the call, and the "
              "audio is never kept: once it is transcribed, it is gone. Click "
              "the microphone icon in the menu bar and choose Start Capture "
              "when a call begins, then Stop Capture when it ends. Ostler "
              "files a summary, the to-dos and the transcript for you."),
        evidence=("Needs Microphone and Screen & System Audio Recording "
                  "permission in System Settings"),
        label="Open RemoteCapture",
        action_kind=ACTION_OPEN_REMOTE_CAPTURE, now=now)


def setup_cards(state: dict | None, now: datetime, make_card) -> list[dict]:
    """The setup cards this Mac should show right now. ``state`` is
    ``read_setup_state()``; ``None`` (not read, e.g. demo) yields nothing."""
    if not isinstance(state, dict):
        return []
    out = []
    ext = state.get("browser_extension") or {}
    if ext.get("installed") is True and ext.get("active") is not True:
        out.append(browser_extension_card(now, make_card))
    rc = state.get("remote_capture") or {}
    if rc.get("installed") is True and rc.get("used") is not True:
        out.append(remote_capture_card(now, make_card))
    return out
