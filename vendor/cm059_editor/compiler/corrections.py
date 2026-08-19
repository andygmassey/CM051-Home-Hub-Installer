"""Interest-profile corrections: the high-value verify-and-correct loop.

User actions on an interest card - strengthen / weaken / drop / add - are the
cleanest training signal we will ever get, so they must persist across a
recompile and always win over inferred signal.

Write target (per Andy's 2026-06-20 decision: "graph-assert, with a local
fallback"):

  * LOCAL STORE is authoritative for Phase 0. A small JSON file (mirrors
    CM044's corrections.py pattern) that compile_profile() consumes on every
    run. This always works and never depends on a live service.

  * GRAPH SYNC is the forward path. Andy chose to ride the learning-loop
    /memory/assert endpoint (CM041, fixed in PR #66). HONEST CAVEAT: that
    endpoint today asserts *Person facts / relationships*, not preferences -
    it has no shape for "strengthen LikePreference X". So graph sync is
    OFF by default behind `enable_graph_sync`, with the exact payload it
    *would* send stubbed, ready to switch on once CM041 grows a
    preference-assert shape (the precise follow-up, see PREFERENCE_ASSERT_GAP).

So: corrections work end-to-end today via the local store; the graph path is
wired but gated, not faked.
"""

from __future__ import annotations

import json
import os
import urllib.request
from datetime import datetime, timezone

DEFAULT_STORE = os.path.expanduser("~/.ostler/editor/interest_corrections.json")

PREFERENCE_ASSERT_GAP = (
    "CM041 /api/v1/memory/assert asserts Person facts/relationships only; it has "
    "no preference verb. Need POST shape e.g. {kind:'preference', subject, "
    "polarity, action:'strengthen|weaken|drop|add', factor} that writes/edits a "
    "pwg:LikePreference node. Until then, corrections live in the local store."
)

_EMPTY = {"drop": [], "strengthen": {}, "weaken": {}, "add": []}


def load_corrections(path: str | None = None) -> dict:
    path = path or os.environ.get("OSTLER_EDITOR_CORRECTIONS", DEFAULT_STORE)
    if not os.path.exists(path):
        return {k: (v.copy() if isinstance(v, (list, dict)) else v) for k, v in _EMPTY.items()}
    with open(path) as fh:
        data = json.load(fh)
    # normalise shape so callers never KeyError
    out = {k: (v.copy() if isinstance(v, (list, dict)) else v) for k, v in _EMPTY.items()}
    out["drop"] = list(data.get("drop", []))
    out["strengthen"] = dict(data.get("strengthen", {}))
    out["weaken"] = dict(data.get("weaken", {}))
    out["add"] = list(data.get("add", []))
    return out


def save_corrections(corr: dict, path: str | None = None) -> str:
    path = path or os.environ.get("OSTLER_EDITOR_CORRECTIONS", DEFAULT_STORE)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    payload = dict(corr)
    payload["_updated_utc"] = datetime.now(timezone.utc).isoformat()
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)
    os.replace(tmp, path)  # atomic
    return path


class CorrectionStore:
    """Thin façade the macOS/iOS app calls one method per card tap."""

    def __init__(self, path: str | None = None, enable_graph_sync: bool = False,
                 ical_server_url: str | None = None):
        self.path = path or os.environ.get("OSTLER_EDITOR_CORRECTIONS", DEFAULT_STORE)
        self.enable_graph_sync = enable_graph_sync
        self.ical_server_url = ical_server_url or os.environ.get(
            "OSTLER_ICAL_SERVER_URL", "http://localhost:8090")
        self.corr = load_corrections(self.path)

    # --- card actions -----------------------------------------------------
    def strengthen(self, key: str, factor: float = 1.5):
        self.corr["strengthen"][key] = float(factor)
        self.corr["weaken"].pop(key, None)
        return self._commit("strengthen", key, factor)

    def weaken(self, key: str, factor: float = 0.5):
        self.corr["weaken"][key] = float(factor)
        self.corr["strengthen"].pop(key, None)
        return self._commit("weaken", key, factor)

    def drop(self, key: str):
        if key not in self.corr["drop"]:
            self.corr["drop"].append(key)
        return self._commit("drop", key, None)

    def add(self, subject: str, domain: str | None = None,
            category: str = "user_added"):
        entry = {"subject": subject, "domain": domain, "category": category}
        self.corr["add"].append(entry)
        return self._commit("add", subject, None)

    # --- persistence ------------------------------------------------------
    def _commit(self, action: str, key: str, factor):
        save_corrections(self.corr, self.path)
        synced = False
        if self.enable_graph_sync:
            synced = self._graph_sync(action, key, factor)
        return {"ok": True, "action": action, "key": key,
                "stored_local": True, "synced_graph": synced}

    def _graph_sync(self, action: str, key: str, factor) -> bool:
        """Best-effort push to the graph. Returns False (and never raises)
        until a preference-assert endpoint exists - see PREFERENCE_ASSERT_GAP."""
        payload = self._assert_payload(action, key, factor)
        try:
            url = self.ical_server_url.rstrip("/") + "/api/v1/memory/assert"
            req = urllib.request.Request(
                url, data=json.dumps(payload).encode("utf-8"),
                method="POST", headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                return 200 <= resp.status < 300
        except Exception:
            return False

    @staticmethod
    def _assert_payload(action: str, key: str, factor) -> dict:
        """The shape we WOULD send once CM041 models preferences."""
        return {
            "kind": "preference",
            "subject": key,
            "action": action,
            "factor": factor,
            "asserted_via": "the_editor_frontpage",
            "asserted_at": datetime.now(timezone.utc).isoformat(),
        }
