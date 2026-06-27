"""Emit the Front Page artefacts the Hub/app surfaces serve.

Producer side of the Front Page. On each tick it:

  1. obtains the interest profile (re-compiled from the live graph, or read from
     the already-emitted ``interest_profile.json`` artefact when ``--from-artefact``),
  2. best-effort reads the install settling signal (so a fresh install shows the
     calm "still settling in" card instead of a thin page),
  3. reads the local card-state store (dismiss / snooze / complete),
  4. builds the card feed (``frontpage.build_frontpage``), and
  5. writes ``front_page.json`` + ``front_page.html`` atomically under
     ``~/.ostler/editor/`` (the well-known path the Doctor route reads).

No external network calls beyond the read-only Oxigraph query the Phase-0
compiler already makes. Stdlib only.

Paths (env overrides, mirroring CM059's other artefacts):
  * OSTLER_EDITOR_DIR        - dir for front_page.{json,html} (default ~/.ostler/editor)
  * OSTLER_INTEREST_PROFILE  - interest_profile.json to read with --from-artefact
  * OSTLER_HYDRATION_PROGRESS_FILE / OSTLER_STATE_DIR - settling signal inputs
  * OSTLER_EDITOR_CARD_STATES - the per-card state store

CLI: python3 -m compiler.emit_frontpage [--oxigraph URL] [--from-artefact]
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone

from compiler import frontpage as fp
from compiler import interest_profile as ip
from compiler import corrections as corr_mod
from compiler import render_frontpage as rf

DEFAULT_EDITOR_DIR = os.path.expanduser("~/.ostler/editor")
DEFAULT_STATE_DIR = os.path.expanduser("~/.ostler/state")
FEED_NAME = "front_page.json"
HTML_NAME = "front_page.html"
CARD_STATES_NAME = "card_states.json"


def editor_dir() -> str:
    return os.path.expanduser(os.environ.get("OSTLER_EDITOR_DIR", DEFAULT_EDITOR_DIR))


def _state_dir() -> str:
    return os.path.expanduser(os.environ.get("OSTLER_STATE_DIR", DEFAULT_STATE_DIR))


def _read_json(path: str):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def read_settling() -> dict | None:
    """Best-effort settling hint from CM051/CM044's shared sidecars.

    Reads the per-channel hydration progress (overall done/total) the install
    writes at ~/.ostler/state/hydration_progress.json. Returns a small dict
    ``{"pct", "days_remaining", "any_working"}`` the feed builder understands,
    or ``None`` when no signal exists / hydration is settled. Never raises - a
    missing signal simply means "not settling", which is the right default for
    an established install."""
    path = os.environ.get("OSTLER_HYDRATION_PROGRESS_FILE") or os.path.join(
        _state_dir(), "hydration_progress.json")
    progress = _read_json(os.path.expanduser(path))
    if not isinstance(progress, dict):
        return None
    overall = progress.get("overall") or {}
    done = int(overall.get("done") or 0)
    total = int(overall.get("total") or 0)
    failed = int(overall.get("failed") or 0)
    if total <= 0 or done + failed >= total:
        return None  # nothing queued, or backlog settled -> no settling card
    pct = max(1, min(99, int(round(done / total * 100))))
    return {"pct": pct, "any_working": True}


def read_card_states() -> dict | None:
    path = os.environ.get("OSTLER_EDITOR_CARD_STATES") or os.path.join(
        editor_dir(), CARD_STATES_NAME)
    data = _read_json(os.path.expanduser(path))
    return data if isinstance(data, dict) else None


def _atomic_write(path: str, text: str) -> str:
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    return path


def _obtain_profile(oxigraph_url: str | None, from_artefact: bool) -> dict:
    if from_artefact:
        art_path = os.path.expanduser(os.environ.get(
            "OSTLER_INTEREST_PROFILE",
            os.path.join(os.path.expanduser("~/.ostler/preferences"),
                         "interest_profile.json")))
        art = _read_json(art_path)
        if isinstance(art, dict) and art.get("interests") is not None:
            # the flat emitter artefact -> rebuild minimal domain blocks so the
            # feed builder (which groups by domain) can consume it
            return _profile_from_flat(art)
    corrections = corr_mod.load_corrections()
    return ip.build_from_live(oxigraph_url, corrections=corrections)


def _profile_from_flat(art: dict) -> dict:
    """Reconstruct the grouped profile shape from the flat emitter artefact."""
    domains: dict[str, list] = {}
    dislikes: list = []
    for it in art.get("interests", []):
        if it.get("polarity") == "dislike":
            dislikes.append(it)
        else:
            domains.setdefault(it.get("domain", "Other"), []).append(it)
    blocks = [{"domain": d, "count": len(v), "interests": v}
              for d, v in domains.items()]
    return {
        "schema_version": art.get("schema_version", "0.1"),
        "domains": blocks,
        "dislikes": dislikes,
        "stats": art.get("stats", {"interests": sum(len(b["interests"]) for b in blocks)}),
    }


def emit(oxigraph_url: str | None = None, *, from_artefact: bool = False,
         now: datetime | None = None) -> dict:
    """Build + write the Front Page artefacts. Returns
    ``{"feed": <path>, "html": <path>, "phase": ..., "cards": n}``.

    Falls back to an empty (settling-only) feed if the profile cannot be
    obtained, so a fresh / mid-hydration install still gets a graceful page."""
    now = now or datetime.now(timezone.utc)
    settling = read_settling()
    card_states = read_card_states()
    try:
        profile = _obtain_profile(oxigraph_url, from_artefact)
        feed = fp.build_frontpage(profile, now=now, settling=settling,
                                  card_states=card_states)
    except Exception as exc:  # graph down / artefact missing -> never blank
        print(f"front-page: profile unavailable ({type(exc).__name__}: {exc}); "
              "emitting settling-only feed", file=sys.stderr)
        feed = fp.empty_frontpage(now=now, settling=settling)

    out_dir = editor_dir()
    feed_path = _atomic_write(os.path.join(out_dir, FEED_NAME),
                              json.dumps(feed, indent=2, ensure_ascii=False))
    html_path = _atomic_write(os.path.join(out_dir, HTML_NAME), rf.render(feed))
    return {"feed": feed_path, "html": html_path,
            "phase": feed.get("phase"), "cards": feed.get("card_count", 0)}


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(description="Emit the Front Page card feed artefacts.")
    p.add_argument("--oxigraph",
                   default=os.environ.get("OSTLER_OXIGRAPH_URL", "http://localhost:7878"))
    p.add_argument("--from-artefact", action="store_true",
                   help="read interest_profile.json instead of re-compiling")
    args = p.parse_args(argv)
    res = emit(args.oxigraph, from_artefact=args.from_artefact)
    print(f"front-page: {res['cards']} cards (phase={res['phase']}) -> "
          f"{res['feed']} + {res['html']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
