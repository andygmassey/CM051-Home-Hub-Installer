"""Ongoing Spotify listening from the Mac app: poll lightly, dedupe, ingest.

WHY (backlog "Spotify ongoing", P2). The Spotify importer reads the owner's
privacy-request export, which is a one-off download. What the owner listens
to NOW never arrived. The desktop app answers AppleScript, so a small poll
can see the current track without reading any Spotify cache (ruled out) and
without the Web API (a separate, later item).

THE DESIGN is the Apple Music refresh's (apple_music_refresh.py), because the
TCC reasoning is the same: Automation consent belongs to the process that
sends the Apple event, and a bare launchd Python would raise "python3 wants to
control Spotify". So:

1. ``com.ostler.spotify-live`` (this module renders its plist). A per-user
   LaunchAgent, Aqua session only, every 60 s. Its program is the signed
   installer app's executable with ``--spotify-poll``
   (gui/OstlerInstaller/Auth/SpotifyLiveMode.swift). The app exits at once
   unless Spotify is already running (it NEVER launches Spotify), otherwise
   runs ONE fixed osascript and writes its rc/stdout/stderr, verbatim, to
   ``state/spotify_live/poll_out.json``. It judges nothing.

2. ``com.ostler.spotify-live-apply`` (this module's ``apply``). A no-TCC job
   fired by WatchPaths on that file. It parses the answer, dedupes plays,
   applies the 30 s rule, and hands the plays to the CM019 preference ingest
   by writing an extended-format ``Streaming_History_Audio_live.json``: the
   file shape the Spotify export parser already reads, so a live play takes
   the SAME path, filters and privacy compartment as an exported one
   (a play is Neutral and passive; track titles stay local-only unless the
   owner's look-up consent is accepted, which is enforced downstream at the
   scout boundary, CM059 #32-#34).

PLAYED MEANS 30 SECONDS. A poll that sees the track ``playing`` with a player
position of 30 s or more counts it once. The same listen seen by later polls
is the same play (position keeps rising); a position that falls back is a
new play (repeat, or a seek to the start). Pause and resume are one play.
LIMIT, NOT HIDDEN: a track that starts and ends between two 60 s polls, or
changes before a poll sees 30 s, is never counted.

AUTOMATION REFUSED IS A KNOWN STATE. osascript error -1743 is recorded as
``automation_not_granted``; the Doctor row says "Ostler needs Automation
access to Spotify". It is not a failure of the install and it does not loop:
macOS remembers the refusal and the poll goes on being answered with it.

FAIL-OPEN. Every outcome exits 0. Counts only in every log line: never a
title, artist or album.
"""
from __future__ import annotations

import json
import logging
import os
import plistlib
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, List, Optional

logger = logging.getLogger("ostler_fda.spotify_live")

LABEL_RUN = "com.ostler.spotify-live"
LABEL_APPLY = "com.ostler.spotify-live-apply"

STATE_REL = Path("state") / "spotify_live"
POLL_OUT_NAME = "poll_out.json"
STATE_NAME = "state.json"
DELTA_DIR_REL = Path("imports") / "preferences" / "spotify_live"
# "streaming_history" in the name is what SpotifyParser.can_parse keys on.
EXPORT_NAME = "Streaming_History_Audio_live.json"

POLL_INTERVAL_S = 60
PLAYED_AFTER_S = 30
# A position that falls by more than this since the last poll is a new play.
RESTART_SLACK_S = 5
INGEST_TIMEOUT_S = 300.0
# Plays that could not be stored are kept, bounded, and retried.
OUTBOX_MAX = 5000

# The ONE script the app runs. The first line is the guard that stops
# AppleScript launching Spotify: asking `application "Spotify" is running`
# never starts it, `tell application "Spotify"` on its own would.
# Fields are joined with ASCII 31 so a title cannot collide with the
# separator; the position is an integer so a comma-decimal locale cannot
# change its shape.
APPLESCRIPT = (
    'if application "Spotify" is not running then return "not_running"\n'
    'set sep to (ASCII character 31)\n'
    'tell application "Spotify"\n'
    '  set st to (player state as text)\n'
    '  if st is "stopped" then return "stopped"\n'
    '  set t to current track\n'
    '  return st & sep & (id of t) & sep & (name of t) & sep & (artist of t) '
    '& sep & (album of t) & sep & (round (player position)) & sep & (duration of t)\n'
    'end tell'
)
SEP = "\x1f"

# osascript's "Not authorized to send Apple events" is -1743.
_DENIED_MARKERS = ("-1743", "not authorized", "not allowed assistive")


# ── paths ──────────────────────────────────────────────────────────────────

def state_dir(ostler_dir: Path) -> Path:
    return Path(ostler_dir) / STATE_REL


def _default_ostler_dir() -> Path:
    raw = os.environ.get("OSTLER_DIR", "").strip()
    return Path(raw) if raw else Path.home() / ".ostler"


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ── reading what osascript said ────────────────────────────────────────────

@dataclass
class Observation:
    """What one poll saw. ``status`` is one of: playing, paused, stopped,
    not_running, automation_not_granted, could_not_look."""
    status: str
    track_id: str = ""
    name: str = ""
    artist: str = ""
    album: str = ""
    position_s: int = 0
    duration_ms: int = 0
    reason: str = ""


def parse_poll(rc: int, stdout: str, stderr: str) -> Observation:
    """Turn one osascript run into an Observation. NEVER raises.

    A non-zero rc is judged by its stderr: only the Automation refusal has a
    fix the owner can do, so only it is named; anything else is
    ``could_not_look`` with the reason class, never a guess.
    """
    try:
        rc = int(rc)
    except (TypeError, ValueError):
        return Observation("could_not_look", reason="bad_rc")
    err = (stderr or "").lower()
    if rc != 0:
        if any(m in err for m in _DENIED_MARKERS):
            return Observation("automation_not_granted")
        return Observation("could_not_look", reason="osascript_rc_%d" % rc)
    out = (stdout or "").rstrip("\r\n")
    if out == "not_running":
        return Observation("not_running")
    if out == "stopped":
        return Observation("stopped")
    parts = out.split(SEP)
    if len(parts) != 7 or parts[0] not in ("playing", "paused"):
        return Observation("could_not_look", reason="unrecognised_output")
    try:
        pos = int(float(parts[5].replace(",", ".")))
        dur = int(float(parts[6].replace(",", ".")))
    except ValueError:
        return Observation("could_not_look", reason="unrecognised_output")
    return Observation(parts[0], track_id=parts[1].strip(), name=parts[2].strip(),
                       artist=parts[3].strip(), album=parts[4].strip(),
                       position_s=max(pos, 0), duration_ms=max(dur, 0))


# ── the play logic ─────────────────────────────────────────────────────────

def _is_music_track(obs: Observation) -> bool:
    """Only catalogue tracks. Ads (spotify:ad:), podcast episodes
    (spotify:episode:) and local files are counted as skipped, not emitted."""
    return (obs.track_id.startswith("spotify:track:")
            and bool(obs.name) and bool(obs.artist))


def advance(state: dict, obs: Observation, polled_at: float) -> Optional[dict]:
    """Fold one observation into ``state['current']``. Returns a play dict
    (to be queued) when this poll is the one that makes a play count, else
    None. Mutates ``state``.

    current = {id, position, polled_at, counted}. The same instance of the
    same track keeps its ``counted`` flag, so it is counted once however
    many polls see it.
    """
    if obs.status in ("stopped", "not_running"):
        state["current"] = None
        return None
    if obs.status != "playing":
        # paused: keep the instance so a resume is the same play.
        return None
    cur = state.get("current")
    same = (isinstance(cur, dict) and cur.get("id") == obs.track_id
            and obs.position_s >= int(cur.get("position", 0)) - RESTART_SLACK_S)
    if not same:
        cur = {"id": obs.track_id, "counted": False}
    cur["position"] = obs.position_s
    cur["polled_at"] = polled_at
    state["current"] = cur
    if cur["counted"] or obs.position_s < PLAYED_AFTER_S:
        return None
    cur["counted"] = True
    if not _is_music_track(obs):
        state["skipped_non_track"] = int(state.get("skipped_non_track", 0)) + 1
        return None
    started = datetime.fromtimestamp(polled_at - obs.position_s, timezone.utc)
    return {"id": obs.track_id, "name": obs.name, "artist": obs.artist,
            "album": obs.album, "ms_played": obs.position_s * 1000,
            "ts": started.strftime("%Y-%m-%dT%H:%M:%SZ")}


def to_export_rows(plays: List[dict]) -> List[dict]:
    """Extended-format rows, the shape SpotifyParser._parse_streaming_history
    reads (master_metadata_*, ms_played, ts, spotify_track_uri)."""
    return [{"ts": p["ts"], "ms_played": int(p["ms_played"]),
             "master_metadata_track_name": p["name"],
             "master_metadata_album_artist_name": p["artist"],
             "master_metadata_album_album_name": p.get("album", ""),
             "spotify_track_uri": p["id"], "skipped": False} for p in plays]


# ── state ──────────────────────────────────────────────────────────────────

def load_state(ostler_dir: Path) -> dict:
    try:
        data = json.loads((state_dir(ostler_dir) / STATE_NAME).read_text())
    except (OSError, ValueError):
        data = None
    if not isinstance(data, dict):
        data = {}
    if not isinstance(data.get("outbox"), list):
        data["outbox"] = []
    data.setdefault("current", None)
    return data


def save_state(ostler_dir: Path, state: dict) -> None:
    sdir = state_dir(ostler_dir)
    sdir.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = sdir / (STATE_NAME + ".tmp")
    tmp.write_text(json.dumps(state))
    os.chmod(tmp, 0o600)
    os.replace(tmp, sdir / STATE_NAME)


# ── the ingest ─────────────────────────────────────────────────────────────

def run_cm019_ingest(directory: Path, ostler_dir: Path, user: str) -> bool:
    """Hand ``directory`` to the CM019 preference ingest. True on success.

    The same command the Apple Music refresh and ostler-import use.
    """
    cm019 = Path(ostler_dir) / "services" / "cm019"
    py = cm019 / ".venv" / "bin" / "python3"
    if not py.is_file():
        logger.warning("spotify-live: could not store (preference ingest not installed)")
        return False
    env = dict(os.environ, QDRANT_COLLECTION="preferences")
    try:
        proc = subprocess.run(
            [str(py), "-m", "services.ingest.src.cli", "ingest-dir", str(directory),
             "-u", user],
            cwd=str(cm019), env=env, stdin=subprocess.DEVNULL,
            capture_output=True, timeout=INGEST_TIMEOUT_S, check=False,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        logger.warning("spotify-live: could not store (%s)", type(exc).__name__)
        return False
    if proc.returncode != 0:
        logger.warning("spotify-live: could not store (ingest rc=%d)", proc.returncode)
        return False
    return True


# ── apply ──────────────────────────────────────────────────────────────────

def apply(ostler_dir: Path, user: str = "ostler",
          ingest: Optional[Callable[[Path, Path, str], bool]] = None,
          now: Optional[float] = None) -> dict:
    """Consume one poll answer. NEVER raises; records the outcome for the Doctor."""
    try:
        result = _apply(Path(ostler_dir), user, ingest or run_cm019_ingest, now)
    except Exception as exc:  # noqa: BLE001 - fail-open by contract
        logger.warning("spotify-live: could not look (%s)", type(exc).__name__)
        result = {"outcome": "could_not_look", "reason": type(exc).__name__}
    record_activity(Path(ostler_dir), result)
    return result


def _apply(ostler_dir: Path, user: str, ingest, now: Optional[float]) -> dict:
    """``outcome``: nothing_to_do, idle, could_not_look, cannot_run, queued,
    stored, could_not_store."""
    src = state_dir(ostler_dir) / POLL_OUT_NAME
    try:
        raw = src.read_bytes()
    except FileNotFoundError:
        return {"outcome": "nothing_to_do"}
    except OSError as exc:
        return {"outcome": "could_not_look", "reason": type(exc).__name__}
    try:
        doc = json.loads(raw)
        obs = parse_poll(doc.get("rc"), doc.get("stdout", ""), doc.get("stderr", ""))
        polled_at = float(doc.get("polled_at") or (now if now is not None
                                                   else datetime.now(timezone.utc).timestamp()))
    except (ValueError, AttributeError, TypeError):
        _consume(src)
        return {"outcome": "could_not_look", "reason": "bad_poll_file"}
    _consume(src)

    state = load_state(ostler_dir)
    if obs.status == "automation_not_granted":
        state["current"] = None
        save_state(ostler_dir, state)
        logger.info("spotify-live: could not look (automation_not_granted)")
        return {"outcome": "cannot_run", "reason": "automation_not_granted"}
    if obs.status == "could_not_look":
        logger.info("spotify-live: could not look (%s)", obs.reason)
        return {"outcome": "could_not_look", "reason": obs.reason}

    play = advance(state, obs, polled_at)
    if play is not None:
        state["outbox"].append(play)
        del state["outbox"][:-OUTBOX_MAX]
    if not state["outbox"]:
        save_state(ostler_dir, state)
        return {"outcome": "idle", "state": obs.status}

    out_dir = ostler_dir / DELTA_DIR_REL
    out_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    out = out_dir / EXPORT_NAME
    tmp = out_dir / (out.name + ".tmp")
    tmp.write_text(json.dumps(to_export_rows(state["outbox"])))
    os.chmod(tmp, 0o600)
    os.replace(tmp, out)
    n = len(state["outbox"])
    stored = False
    try:
        stored = bool(ingest(out_dir, ostler_dir, user))
    except Exception as exc:  # noqa: BLE001 - fail-open by contract
        logger.warning("spotify-live: could not store (%s)", type(exc).__name__)
    if not stored:
        save_state(ostler_dir, state)  # outbox kept: retried whole next time
        logger.info("spotify-live: %d play(s) not stored; will retry", n)
        return {"outcome": "could_not_store", "plays": n}
    state["outbox"] = []
    state["stored_total"] = int(state.get("stored_total", 0)) + n
    save_state(ostler_dir, state)
    _consume(out)
    logger.info("spotify-live: %d play(s) stored", n)
    return {"outcome": "stored", "plays": n, "stored_total": state["stored_total"]}


def record_activity(ostler_dir: Path, result: dict) -> None:
    """Write the outcome where the Doctor reads it.

    Two records, same as every other source: the hydrate sentinel (which is
    what makes the row exist) and state/source_activity/spotify_live.tsv.
    ``idle`` and ``nothing_to_do`` change nothing. Best effort: bookkeeping
    must never fail the run it describes.
    """
    try:
        outcome = str(result.get("outcome", "unknown"))
        if outcome in ("nothing_to_do", "idle"):
            return
        status = {"stored": "ok", "cannot_run": "cannot_run",
                  "could_not_look": "cannot_run",
                  "could_not_store": "error"}.get(outcome, "error")
        now = _now_iso()
        act = Path(ostler_dir) / "state" / "source_activity"
        act.mkdir(parents=True, exist_ok=True)
        f = act / "spotify_live.tsv"
        prev_success = ""
        try:
            for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
                if line.startswith("last_success_at="):
                    prev_success = line.split("=", 1)[1]
        except OSError:
            pass
        detail = {k: v for k, v in result.items() if k != "outcome"}
        detail["outcome"] = outcome
        tmp = act / "spotify_live.tsv.tmp"
        tmp.write_text(
            "source=spotify_live\n"
            f"last_run_at={now}\n"
            f"last_status={status}\n"
            f"last_success_at={now if status == 'ok' else prev_success}\n"
            f"last_detail={json.dumps(detail, default=str)[:400]}\n"
            "writer=ostler-spotify-live\n", encoding="utf-8")
        os.replace(tmp, f)
        hyd = Path(ostler_dir) / "state" / "hydrate"
        hyd.mkdir(parents=True, exist_ok=True)
        total = int(load_state(Path(ostler_dir)).get("stored_total", 0))
        tmp = hyd / "spotify_live.done.tmp"
        tmp.write_text(
            "source=spotify_live\n"
            f"status={status}\n"
            f"item_count={total}\n"
            f"recorded_at={now}\n"
            f"detail={result.get('reason') or outcome}\n", encoding="utf-8")
        os.replace(tmp, hyd / "spotify_live.done")
    except Exception as exc:  # noqa: BLE001 - bookkeeping only
        logger.warning("spotify-live: could not record activity (%s)", type(exc).__name__)


def note_cannot_run(ostler_dir: Path, reason: str) -> None:
    record_activity(Path(ostler_dir), {"outcome": "cannot_run", "reason": reason})


def _consume(path: Path) -> None:
    try:
        Path(path).unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        logger.warning("spotify-live: could not remove %s (%s)", Path(path).name,
                       type(exc).__name__)


# ── scheduling: the two plists ─────────────────────────────────────────────

def stable_app_executable(path: str) -> bool:
    """True for an installed app, never a DMG mount or a temp tree."""
    p = str(path)
    home_apps = str(Path.home() / "Applications") + "/"
    return p.startswith(("/Applications/", home_apps)) and ".app/Contents/MacOS/" in p


def spotify_installed() -> bool:
    return any((Path(base) / "Spotify.app").is_dir() for base in
               ("/Applications", str(Path.home() / "Applications")))


def render_run_plist(app_executable: str, logs_dir: str) -> dict:
    return {
        "Label": LABEL_RUN,
        "ProgramArguments": [str(app_executable), "--spotify-poll"],
        # Automation is a GUI-session grant: never load anywhere else.
        "LimitLoadToSessionType": "Aqua",
        "StartInterval": POLL_INTERVAL_S,
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "StandardOutPath": str(Path(logs_dir) / "spotify-live.log"),
        "StandardErrorPath": str(Path(logs_dir) / "spotify-live.err"),
    }


def render_apply_plist(python: str, fda_parent: str, ostler_dir: str,
                       logs_dir: str, user: str) -> dict:
    sdir = state_dir(Path(ostler_dir))
    return {
        "Label": LABEL_APPLY,
        "ProgramArguments": [str(python), "-m", "ostler_fda.spotify_live", "apply"],
        "EnvironmentVariables": {
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
            "PYTHONPATH": str(fda_parent),
            "OSTLER_DIR": str(ostler_dir),
            "OSTLER_USER": str(user),
        },
        "WatchPaths": [str(sdir / POLL_OUT_NAME)],
        # Consuming the file is itself a path event: the throttle keeps that
        # echo to one cheap no-op run.
        "ThrottleInterval": 10,
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "StandardOutPath": str(Path(logs_dir) / "spotify-live-apply.log"),
        "StandardErrorPath": str(Path(logs_dir) / "spotify-live-apply.err"),
    }


def write_plist_if_changed(path: Path, payload: dict) -> bool:
    data = plistlib.dumps(payload, fmt=plistlib.FMT_XML)
    try:
        if Path(path).read_bytes() == data:
            return False
    except OSError:
        pass
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(path) + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)
    return True


# ── CLI ────────────────────────────────────────────────────────────────────

def main(argv: Optional[List[str]] = None) -> int:
    import argparse
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(asctime)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%S")
    ap = argparse.ArgumentParser(prog="ostler_fda.spotify_live")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("apply", help="store what the app last polled")
    c = sub.add_parser("cannot-run", help="record why the poll is not scheduled")
    c.add_argument("--reason", required=True)
    sub.add_parser("script", help="print the AppleScript the app runs")
    i = sub.add_parser("install-agents", help="write both LaunchAgent plists")
    i.add_argument("--app-executable", required=True)
    i.add_argument("--python", required=True)
    i.add_argument("--fda-parent", required=True)
    i.add_argument("--agents-dir", default=str(Path.home() / "Library" / "LaunchAgents"))
    i.add_argument("--user", default=os.environ.get("OSTLER_USER", "ostler"))
    args = ap.parse_args(argv)
    odir = _default_ostler_dir()
    try:
        if args.cmd == "apply":
            apply(odir, user=os.environ.get("OSTLER_USER", "ostler"))
        elif args.cmd == "cannot-run":
            note_cannot_run(odir, args.reason)
        elif args.cmd == "script":
            print(APPLESCRIPT)
        elif args.cmd == "install-agents":
            if not spotify_installed():
                print("not installed: Spotify is not installed")
                return 0
            if not stable_app_executable(args.app_executable):
                note_cannot_run(odir, "installer_not_in_applications")
                print("not installed: app executable is not at a stable path")
                return 0
            logs = odir / "logs"
            logs.mkdir(parents=True, exist_ok=True)
            adir = Path(args.agents_dir)
            c1 = write_plist_if_changed(adir / f"{LABEL_RUN}.plist",
                                        render_run_plist(args.app_executable, str(logs)))
            c2 = write_plist_if_changed(
                adir / f"{LABEL_APPLY}.plist",
                render_apply_plist(args.python, args.fda_parent, str(odir), str(logs),
                                   args.user))
            print(f"run_changed={int(c1)} apply_changed={int(c2)}")
    except Exception as exc:  # noqa: BLE001 - never a non-zero exit from a background job
        logger.warning("spotify-live: could not look (%s)", type(exc).__name__)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
