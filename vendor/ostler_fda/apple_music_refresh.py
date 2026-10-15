"""The scheduled Apple Music refresh: daily and at login, additive, fail-open.

WHY (Andy, 2026-10-15, "please don't let that slip"). Apple Music was read at
INSTALL ONLY. The recurring FDA re-run is a launchd job, and a launchd job
cannot hold the "Media & Apple Music" grant (kTCCServiceMediaLibrary) the
customer gave the installer, so its native read is refused and the library
went stale the day after install.

THE DESIGN, in three parts (the TCC reasoning is in
``docs/APPLE_MUSIC_REFRESH_TCC.md``; read it before changing any of this):

1. ``com.ostler.music-refresh`` (this module renders its plist). A per-user
   LaunchAgent limited to the Aqua (logged-in GUI) session. Its program is
   the signed installer app's own executable with ``--music-refresh``
   (gui/OstlerInstaller/Auth/MusicRefreshMode.swift). The app runs the SAME
   signed ``ostler-music-library`` helper as a child, so the read is
   attributed to the app identity that already holds the grant, exactly as
   it is when install.sh runs the helper. The app writes the helper's JSON
   to ``state/music_refresh/helper_out.json`` and exits. It does nothing
   else: no script path is taken from anywhere, so the app's other grants
   (Contacts, Calendar, Photos) cannot be borrowed by editing a file.

2. ``com.ostler.music-refresh-apply`` (this module's ``apply``). A plain
   launchd job, with NO TCC need, fired by WatchPaths when the app writes
   that file. It diffs against the last snapshot and hands only the CHANGED
   tracks to the CM019 preference ingest (upsert by a source-keyed id, so
   additive and idempotent).

3. THE GATE THAT KEEPS IT QUIET. Nothing in the background may ever raise a
   permission dialog. macOS has no public status call for this service, so
   the install arms the refresh (``arm``) only after its own native read
   succeeded, which proves the customer clicked Allow. The app does nothing
   unless ``armed`` exists. Three refusals in a row disarm it again.

FAIL-OPEN. No grant, no helper, no Music app, bad output, a failed ingest:
all of them log ``could not look`` (or ``could not store``) with a reason
and exit 0. Nothing here can abort an install or loop.

ADDITIVE. Tracks that vanish from the library are never deleted from the
Hub. A snapshot is committed only after the ingest succeeded, so a failed
ingest is retried whole on the next run.

Counts only in every log line: no title, artist or playlist name.
"""
from __future__ import annotations

import json
import logging
import os
import plistlib
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, List, Optional

from . import apple_music

logger = logging.getLogger("ostler_fda.apple_music_refresh")

LABEL_RUN = "com.ostler.music-refresh"
LABEL_APPLY = "com.ostler.music-refresh-apply"

STATE_REL = Path("state") / "music_refresh"
ARMED_NAME = "armed"
HELPER_OUT_NAME = "helper_out.json"
STATE_NAME = "state.json"
# Separate from the install's staged full export so a delta never clobbers a
# full export the importer has not read yet. The CM019 parser matches this
# exact file name, not the directory.
DELTA_DIR_REL = Path("imports") / "preferences" / "apple_music_refresh"

# Daily, off the hour so a fleet of Macs does not fire together, and at login
# (RunAtLoad on a LaunchAgent fires at each GUI login).
DEFAULT_HOUR = 4
DEFAULT_MINUTE = 17
# Consecutive refusals before the refresh disarms itself.
DISARM_AFTER = 3
INGEST_TIMEOUT_S = 900.0

# The fields whose change makes a track worth re-sending. Title, artist and
# album are identity, not signal.
_WATCHED = ("play_count", "skip_count", "last_played", "rating", "loved",
            "disliked", "in_user_playlist")


# ── paths ──────────────────────────────────────────────────────────────────

def state_dir(ostler_dir: Path) -> Path:
    return Path(ostler_dir) / STATE_REL


def _default_ostler_dir() -> Path:
    raw = os.environ.get("OSTLER_DIR", "").strip()
    return Path(raw) if raw else Path.home() / ".ostler"


# ── scheduling: the two plists ─────────────────────────────────────────────

STABLE_APP_PREFIXES = ("/Applications/", )


def stable_app_executable(path: str) -> bool:
    """True for an installed app (/Applications or ~/Applications), never a DMG
    mount or a temp tree: launchd fails silently when such a path goes away."""
    p = str(path)
    home_apps = str(Path.home() / "Applications") + "/"
    return p.startswith(STABLE_APP_PREFIXES + (home_apps,)) and ".app/Contents/MacOS/" in p


def render_run_plist(app_executable: str, logs_dir: str,
                     hour: int = DEFAULT_HOUR, minute: int = DEFAULT_MINUTE) -> dict:
    """The agent that runs in the logged-in GUI session."""
    if not (0 <= int(hour) <= 23 and 0 <= int(minute) <= 59):
        raise ValueError("hour/minute out of range")
    return {
        "Label": LABEL_RUN,
        "ProgramArguments": [str(app_executable), "--music-refresh"],
        # The grant applies in the GUI session only: never load anywhere else.
        "LimitLoadToSessionType": "Aqua",
        # At login ...
        "RunAtLoad": True,
        # ... and daily. Hour+Minute only (no Day/Month/Year), so it recurs;
        # a fully dated StartCalendarInterval is a one-shot (see the
        # fda-rerun note in install.sh, #714).
        "StartCalendarInterval": {"Hour": int(hour), "Minute": int(minute)},
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "StandardOutPath": str(Path(logs_dir) / "music-refresh.log"),
        "StandardErrorPath": str(Path(logs_dir) / "music-refresh.err"),
    }


def render_apply_plist(python: str, fda_parent: str, ostler_dir: str,
                       logs_dir: str, user: str) -> dict:
    """The no-TCC job that stores what the app read."""
    sdir = state_dir(Path(ostler_dir))
    return {
        "Label": LABEL_APPLY,
        "ProgramArguments": [str(python), "-m", "ostler_fda.apple_music_refresh", "apply"],
        "EnvironmentVariables": {
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
            "PYTHONPATH": str(fda_parent),
            "OSTLER_DIR": str(ostler_dir),
            "OSTLER_USER": str(user),
        },
        "WatchPaths": [str(sdir / HELPER_OUT_NAME)],
        # Consuming the file removes it, which is itself a path event: the
        # throttle keeps that echo to one cheap no-op run.
        "ThrottleInterval": 30,
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "StandardOutPath": str(Path(logs_dir) / "music-refresh-apply.log"),
        "StandardErrorPath": str(Path(logs_dir) / "music-refresh-apply.err"),
    }


def write_plist_if_changed(path: Path, payload: dict) -> bool:
    """Write ``payload`` as an XML plist. True when the file changed."""
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


# ── the arming gate ────────────────────────────────────────────────────────

def is_armed(ostler_dir: Path) -> bool:
    return (state_dir(ostler_dir) / ARMED_NAME).is_file()


def arm(ostler_dir: Path, export_path: Path, run_summary: Optional[dict] = None) -> bool:
    """Arm the refresh iff THIS run's own native read succeeded.

    ``run_summary`` is the ``run_all`` summary of the run that just finished
    (or its ``sources.apple_music`` entry). It must show ``reader`` native and
    more than 0 tracks. The export on disk is NOT enough on its own: after a
    refused or empty read, extract_all deliberately keeps the previous export
    (reader still ``native``) and only the summary says ``previous_export``,
    so trusting the file would arm without proof of the grant. No summary, no
    arming.
    """
    stats = _apple_music_stats(run_summary)
    if stats is None or stats.get("reader") != "native":
        return False
    try:
        if int(stats.get("total_tracks") or 0) <= 0:
            return False
    except (TypeError, ValueError):
        return False
    try:
        data = json.loads(Path(export_path).read_text())
    except (OSError, ValueError):
        return False
    if not (isinstance(data, dict) and data.get("reader") == "native"
            and isinstance(data.get("tracks"), list) and data["tracks"]):
        return False
    sdir = state_dir(ostler_dir)
    sdir.mkdir(parents=True, exist_ok=True)
    (sdir / ARMED_NAME).write_text(_now_iso() + "\n")
    return True


def _apple_music_stats(run_summary: Optional[dict]) -> Optional[dict]:
    if not isinstance(run_summary, dict):
        return None
    src = run_summary.get("sources")
    entry = src.get("apple_music") if isinstance(src, dict) else run_summary
    if not isinstance(entry, dict) or entry.get("status") != "ok":
        return None
    return entry


def parse_run_summary(text: str) -> Optional[dict]:
    """The ``run_all`` JSON is the last JSON line of install.sh's FDA output."""
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                obj = json.loads(line)
            except ValueError:
                return None
            return obj if isinstance(obj, dict) else None
    return None


def disarm(ostler_dir: Path) -> None:
    try:
        (state_dir(ostler_dir) / ARMED_NAME).unlink()
    except FileNotFoundError:
        pass


# ── the diff ───────────────────────────────────────────────────────────────

@dataclass
class Delta:
    rows: List[dict] = field(default_factory=list)
    total: int = 0
    new: int = 0
    plays: int = 0       # play count rose
    recency: int = 0     # last_played moved, count did not rise
    other: int = 0       # rating / loved / skips / playlist membership
    snapshot: Dict[str, list] = field(default_factory=dict)

    @property
    def changed(self) -> int:
        return len(self.rows)


def _row_sig(row: dict) -> list:
    return [row.get(k) for k in _WATCHED]


def compute_delta(library: apple_music.MusicLibrary, previous: Dict[str, list]) -> Delta:
    """Only the tracks that are new or whose signal changed since ``previous``.

    ``previous`` maps track id -> signature (as stored in state.json). A track
    absent from the library now is ignored, never reported: additive only.
    """
    export = apple_music.to_preference_export(library)
    delta = Delta(total=len(export["tracks"]))
    for row in export["tracks"]:
        tid = str(row["id"])
        sig = _row_sig(row)
        delta.snapshot[tid] = sig
        old = previous.get(tid)
        if old == sig:
            continue
        delta.rows.append(row)
        if old is None:
            delta.new += 1
        elif (row.get("play_count") or 0) > (old[0] or 0):
            delta.plays += 1
        elif row.get("last_played") != old[2]:
            delta.recency += 1
        else:
            delta.other += 1
    delta.snapshot = _merge_snapshots(previous, delta.snapshot)
    return delta


def _merge_snapshots(previous: Dict[str, list], current: Dict[str, list]) -> Dict[str, list]:
    """Keep ids that left the library: they are never re-announced as new."""
    merged = dict(previous)
    merged.update(current)
    return merged


# ── state ──────────────────────────────────────────────────────────────────

def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_state(ostler_dir: Path) -> dict:
    try:
        data = json.loads((state_dir(ostler_dir) / STATE_NAME).read_text())
    except (OSError, ValueError):
        return {"snapshot": {}, "refusals": 0}
    if not isinstance(data, dict) or not isinstance(data.get("snapshot"), dict):
        return {"snapshot": {}, "refusals": 0}
    data.setdefault("refusals", 0)
    return data


def save_state(ostler_dir: Path, state: dict) -> None:
    sdir = state_dir(ostler_dir)
    sdir.mkdir(parents=True, exist_ok=True)
    tmp = sdir / (STATE_NAME + ".tmp")
    tmp.write_text(json.dumps(state))
    os.replace(tmp, sdir / STATE_NAME)


# ── the ingest ─────────────────────────────────────────────────────────────

def run_cm019_ingest(directory: Path, ostler_dir: Path, user: str) -> bool:
    """Hand ``directory`` to the CM019 preference ingest. True on success.

    Same command, same upsert, as ostler-import's preference leg. Missing
    venv, non-zero exit, timeout: all False (fail-open, retried next run).
    """
    cm019 = Path(ostler_dir) / "services" / "cm019"
    py = cm019 / ".venv" / "bin" / "python3"
    if not py.is_file():
        logger.warning("music-refresh: could not store (preference ingest not installed)")
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
        logger.warning("music-refresh: could not store (%s)", type(exc).__name__)
        return False
    if proc.returncode != 0:
        logger.warning("music-refresh: could not store (ingest rc=%d)", proc.returncode)
        return False
    return True


# ── apply ──────────────────────────────────────────────────────────────────

def apply(ostler_dir: Path, user: str = "ostler",
          ingest: Optional[Callable[[Path, Path, str], bool]] = None) -> dict:
    """Run one apply and record its outcome in source_activity. NEVER raises."""
    try:
        result = _apply(ostler_dir, user=user, ingest=ingest)
    except Exception as exc:  # noqa: BLE001 - fail-open by contract
        logger.warning("music-refresh: could not look (%s)", type(exc).__name__)
        result = {"outcome": "could_not_look", "reason": type(exc).__name__}
    record_activity(Path(ostler_dir), result)
    return result


def _apply(ostler_dir: Path, user: str = "ostler",
           ingest: Optional[Callable[[Path, Path, str], bool]] = None) -> dict:
    """Consume ``helper_out.json`` once. NEVER raises. Returns a summary.

    ``outcome`` is one of: nothing_to_do, could_not_look, unchanged,
    stored, could_not_store.
    """
    ostler_dir = Path(ostler_dir)
    ingest = ingest or run_cm019_ingest
    sdir = state_dir(ostler_dir)
    src = sdir / HELPER_OUT_NAME
    try:
        raw = src.read_bytes()
    except FileNotFoundError:
        return {"outcome": "nothing_to_do"}
    except OSError as exc:
        logger.warning("music-refresh: could not look (%s)", type(exc).__name__)
        return {"outcome": "could_not_look", "reason": type(exc).__name__}

    state = load_state(ostler_dir)
    lib = apple_music.library_from_helper_output(raw)
    if lib.reader != "native":
        state["refusals"] = int(state.get("refusals", 0)) + 1
        state["last_status"] = lib.native_status
        state["last_run"] = _now_iso()
        reason = lib.native_status + (f" {lib.native_detail}" if lib.native_detail else "")
        logger.info("music-refresh: could not look (%s)", reason)
        if state["refusals"] >= DISARM_AFTER:
            disarm(ostler_dir)
            logger.info("music-refresh: disarmed after %d refusals; the next "
                        "install re-arms it", state["refusals"])
        save_state(ostler_dir, state)
        _consume(src)
        return {"outcome": "could_not_look", "reason": reason,
                "refusals": state["refusals"], "armed": is_armed(ostler_dir)}

    delta = compute_delta(lib, state["snapshot"])
    state["refusals"] = 0
    state["last_status"] = "ok"
    state["last_run"] = _now_iso()
    summary = {"total": delta.total, "changed": delta.changed, "new": delta.new,
               "plays": delta.plays, "recency": delta.recency, "other": delta.other}

    if not delta.rows:
        save_state(ostler_dir, state)
        _consume(src)
        logger.info("music-refresh: read %d tracks, 0 changed", delta.total)
        return dict(summary, outcome="unchanged")

    out_dir = ostler_dir / DELTA_DIR_REL
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / apple_music.PREFERENCE_EXPORT_NAME
    payload = apple_music.to_preference_export(lib)
    payload["tracks"] = delta.rows
    tmp = out_dir / (out.name + ".tmp")
    tmp.write_text(json.dumps(payload))
    os.replace(tmp, out)

    stored = False
    try:
        stored = bool(ingest(out_dir, ostler_dir, user))
    except Exception as exc:  # noqa: BLE001 - fail-open by contract
        logger.warning("music-refresh: could not store (%s)", type(exc).__name__)
    if not stored:
        # Snapshot NOT advanced: the same delta is rebuilt and retried.
        save_state(ostler_dir, state)
        _consume(src)
        logger.info("music-refresh: read %d tracks, %d changed, not stored; will retry",
                    delta.total, delta.changed)
        return dict(summary, outcome="could_not_store")

    state["snapshot"] = delta.snapshot
    save_state(ostler_dir, state)
    _consume(src)
    _consume(out)
    logger.info("music-refresh: read %d tracks, %d changed (%d new, %d plays, "
                "%d recency, %d other), stored", delta.total, delta.changed,
                delta.new, delta.plays, delta.recency, delta.other)
    return dict(summary, outcome="stored")


def record_activity(ostler_dir: Path, result: dict) -> None:
    """Write this refresh's outcome to state/source_activity/apple_music.tsv.

    Same record, same fields, as the FDA tick writes for every other source,
    so the Doctor shows when Apple Music last refreshed and when it last
    worked. last_success_at is carried forward from the previous record when
    this run was not a success. Best effort: bookkeeping must never fail the
    run it describes.
    """
    try:
        outcome = str(result.get("outcome", "unknown"))
        if outcome == "nothing_to_do":
            return
        status = {"stored": "ok", "unchanged": "ok",
                  "could_not_look": "skipped",
                  "could_not_store": "error"}.get(outcome, "error")
        now = _now_iso()
        act = Path(ostler_dir) / "state" / "source_activity"
        act.mkdir(parents=True, exist_ok=True)
        f = act / "apple_music.tsv"
        prev_success = ""
        try:
            for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
                if line.startswith("last_success_at="):
                    prev_success = line.split("=", 1)[1]
        except OSError:
            pass
        detail = {k: v for k, v in result.items() if k != "outcome"}
        detail["outcome"] = outcome
        detail["via"] = "scheduled_refresh"
        tmp = act / "apple_music.tsv.tmp"
        tmp.write_text(
            "source=apple_music\n"
            f"last_run_at={now}\n"
            f"last_status={status}\n"
            f"last_success_at={now if status == 'ok' else prev_success}\n"
            f"last_detail={json.dumps(detail, default=str)[:400]}\n"
            "writer=ostler-music-refresh\n", encoding="utf-8")
        os.replace(tmp, f)
    except Exception as exc:  # noqa: BLE001 - bookkeeping only
        logger.warning("music-refresh: could not record activity (%s)", type(exc).__name__)


def _consume(path: Path) -> None:
    try:
        Path(path).unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        logger.warning("music-refresh: could not remove %s (%s)", Path(path).name,
                       type(exc).__name__)


# ── CLI ────────────────────────────────────────────────────────────────────

def main(argv: Optional[List[str]] = None) -> int:
    import argparse
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(asctime)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%S")
    ap = argparse.ArgumentParser(prog="ostler_fda.apple_music_refresh")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("apply", help="store what the app last read")
    a = sub.add_parser("arm", help="arm the refresh from the install's export")
    a.add_argument("--export", required=True)
    a.add_argument("--run-summary", default="-",
                   help="file holding this run's FDA output ('-' = stdin)")
    sub.add_parser("disarm")
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
            return 0
        if args.cmd == "arm":
            text = (sys.stdin.read() if args.run_summary == "-"
                    else Path(args.run_summary).read_text())
            ok = arm(odir, Path(args.export), parse_run_summary(text))
            print("armed" if ok else "not armed")
            return 0
        if args.cmd == "disarm":
            disarm(odir)
            return 0
        if args.cmd == "install-agents":
            if not stable_app_executable(args.app_executable):
                print("not installed: app executable is not at a stable path")
                return 0
            logs = odir / "logs"
            logs.mkdir(parents=True, exist_ok=True)
            adir = Path(args.agents_dir)
            c1 = write_plist_if_changed(adir / f"{LABEL_RUN}.plist",
                                        render_run_plist(args.app_executable, str(logs)))
            c2 = write_plist_if_changed(
                adir / f"{LABEL_APPLY}.plist",
                render_apply_plist(args.python, args.fda_parent, str(odir), str(logs), args.user))
            print(f"run_changed={int(c1)} apply_changed={int(c2)}")
            return 0
    except Exception as exc:  # noqa: BLE001 - never a non-zero exit from a background job
        logger.warning("music-refresh: could not look (%s)", type(exc).__name__)
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
