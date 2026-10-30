"""Undo an automatic contact merge from the Hub ("Not the same person? Split").

WHY THIS FILE EXISTS. The batch resolver joins two Contacts cards into one
person when they carry the same full name AND share an exact email, mobile or
LinkedIn profile (identity_resolver/exact_identifier.py). Every such merge is
journalled with a restorable snapshot (identity_resolver/merge_journal.py,
CM051 #3217), and the resolver CLI already undoes one by id
(``batch_resolver --undo-merge``). Until now that undo was reachable only from
a terminal, so a customer whose two different friends had been joined had no
way to separate them.

This module is the Hub's thin route onto that existing undo. It does NOT
reimplement any merge or restore logic:

  list   reads the merge journal (the resolver's own file, read-only) and
         reports each merge that has not been undone, with the names the two
         cards had before the merge, read from the merge's own snapshot.
  split  1. records a ``distinct`` decision for the pair FIRST, through
            duplicate_decision.write_decision, the same record the wiki's
            "Not the same" answer writes and the resolver already honours.
            Recording it before the undo means there is no instant at which
            both nodes exist again without the decision that keeps them apart.
         2. runs the resolver's own ``--undo-merge`` in the import pipeline,
            exactly as the converge pass is run (same directory, same venv,
            same ``./backups`` journal), so the graph and vector restore and
            the ``undo`` journal line are the resolver's code, not ours.

Idempotent: a merge that is already undone answers ``already_split`` and
changes nothing; the decision write is itself idempotent. Concurrent calls are
serialised by a process lock so two taps cannot run two undos.

Carries no identifier values: the journal holds identifier KINDS only, and the
names returned are the display names the customer already sees.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import uuid
from typing import Any, Callable, Dict, List, Optional, Tuple

#: Merge ids are minted by merge_journal.record_merge as
#: ``YYYYMMDDTHHMMSSZ-<8 hex>``. Anything else is refused before it reaches a
#: subprocess argument or a file path.
MERGE_ID_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")

JOURNAL_NAME = "merge_journal.jsonl"
UNDO_TIMEOUT_S = 300

_LOCK = threading.Lock()


class SplitError(Exception):
    """Carries an HTTP status and a plain-English reason."""

    def __init__(self, detail: str, status: int = 400, reason: str = ""):
        super().__init__(detail)
        self.detail = detail
        self.status = status
        self.reason = reason or "error"


# -- locations ---------------------------------------------------------------

def pipeline_dir() -> str:
    """The import pipeline the converge pass runs in (install.sh resolves it
    the same way: OSTLER_PIPELINE_DIR, else ~/.ostler/import-pipeline)."""
    return os.environ.get("OSTLER_PIPELINE_DIR") or os.path.join(
        os.path.expanduser("~"), ".ostler", "import-pipeline")


def journal_dir() -> str:
    """``<pipeline>/backups/merge_journal``: the converge pass runs with the
    resolver's default ``--backup-dir ./backups`` from the pipeline dir."""
    return os.environ.get("OSTLER_MERGE_JOURNAL_DIR") or os.path.join(
        pipeline_dir(), "backups", "merge_journal")


def short_id(uri: str) -> str:
    """Mirror of identity_resolver/decisions.py::short_id (the id the
    distinct decision is keyed by)."""
    if "person_" in uri:
        return uri.split("person_")[-1]
    if "business_" in uri:
        return uri.split("business_")[-1]
    return uri.rsplit("/", 1)[-1]


# -- journal -----------------------------------------------------------------

def read_journal(jdir: Optional[str] = None) -> Tuple[str, List[Dict[str, Any]]]:
    """(state, entries). state is ``ok`` or ``absent`` (no merge has ever been
    journalled on this box). An unreadable journal raises SplitError 503: it is
    an outage, never an empty list."""
    jdir = jdir or journal_dir()
    path = os.path.join(jdir, JOURNAL_NAME)
    if not os.path.exists(path):
        return "absent", []
    out: List[Dict[str, Any]] = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue          # one torn line must not hide the rest
    except OSError as exc:
        raise SplitError(
            "The list of combined contacts could not be read.", 503,
            reason=f"journal_unreadable:{type(exc).__name__}")
    return "ok", out


def _undone_ids(entries: List[Dict[str, Any]]) -> set:
    return {e.get("merge_id") for e in entries if e.get("kind") == "undo"}


def _find_merge(entries: List[Dict[str, Any]], merge_id: str) -> Optional[Dict[str, Any]]:
    return next((e for e in entries
                 if e.get("kind") == "merge" and e.get("id") == merge_id), None)


def _snapshot(jdir: str, merge: Dict[str, Any]) -> Dict[str, Any]:
    rel = merge.get("snapshot") or ""
    # The snapshot path comes from the journal; keep it inside the journal dir.
    path = os.path.realpath(os.path.join(jdir, rel))
    if not rel or not path.startswith(os.path.realpath(jdir) + os.sep):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _literal(snap: Dict[str, Any], uri: str, local_name: str) -> str:
    node = (snap.get("nodes") or {}).get(uri) or {}
    for pred, obj in node.get("subj") or []:
        if isinstance(pred, str) and pred.endswith("#" + local_name):
            if isinstance(obj, list) and len(obj) >= 2 and obj[0] in ("lit", "literal"):
                return str(obj[1])
    return ""


def _card(snap: Dict[str, Any], uri: str) -> Dict[str, str]:
    """What the customer can tell the two cards apart by: the name each card
    had before the merge, plus its organisation or job title when present."""
    name = _literal(snap, uri, "displayName")
    detail = _literal(snap, uri, "organization") or _literal(snap, uri, "jobTitle")
    return {"id": short_id(uri), "name": name, "detail": detail}


def _person_ids(snap: Dict[str, Any], keep: str) -> List[str]:
    """Ids the Hub's People rows can carry for the surviving person: the
    uuid5(person_uri) vector point id the pipeline mints, plus any point the
    pre-merge snapshot held for that person."""
    ids = [str(uuid.uuid5(uuid.NAMESPACE_URL, keep))]
    for pt in ((snap.get("qdrant") or {}).get("points") or []):
        payload = pt.get("payload") or {}
        if payload.get("person_uri") == keep and pt.get("id") is not None:
            pid = str(pt["id"])
            if pid not in ids:
                ids.append(pid)
    return ids


def list_merges(person: str = "", jdir: Optional[str] = None) -> Dict[str, Any]:
    """Every journalled merge not yet undone, newest first. ``person`` narrows
    to merges whose surviving person matches a short id, a full URI or a
    People row id."""
    jdir = jdir or journal_dir()
    state, entries = read_journal(jdir)
    undone = _undone_ids(entries)
    merges = []
    for e in entries:
        if e.get("kind") != "merge" or e.get("id") in undone:
            continue
        keep, discard = e.get("keep") or "", e.get("discard") or ""
        if not keep or not discard:
            continue
        snap = _snapshot(jdir, e)
        row = {
            "merge_id": e.get("id"),
            "merged_at": e.get("ts"),
            "person": short_id(keep),
            "person_ids": _person_ids(snap, keep),
            "shared": list(e.get("shared_kinds") or []),
            "cards": [_card(snap, keep), _card(snap, discard)],
        }
        if person and person not in (
                row["person"], keep, *row["person_ids"]):
            continue
        merges.append(row)
    merges.sort(key=lambda r: r.get("merged_at") or "", reverse=True)
    return {"status": "ok", "journal": state, "merges": merges}


# -- split -------------------------------------------------------------------

def _run_undo(merge_id: str) -> Tuple[int, str, str]:
    """Run the resolver's own undo, exactly as the converge pass is run."""
    pdir = pipeline_dir()
    py = os.path.join(pdir, ".venv", "bin", "python3")
    if not os.path.isdir(os.path.join(pdir, "identity_resolver")) or not os.access(py, os.X_OK):
        raise SplitError(
            "The contact tools are not installed on this Hub, so nothing was changed.",
            503, reason="resolver_not_installed")
    env = dict(os.environ)
    env.setdefault("OXIGRAPH_URL", "http://localhost:7878")
    env.setdefault("QDRANT_URL", "http://localhost:6333")
    try:
        proc = subprocess.run(
            [py, "-m", "identity_resolver.batch_resolver", "--undo-merge", merge_id],
            cwd=pdir, env=env, capture_output=True, text=True,
            timeout=UNDO_TIMEOUT_S, check=False)
    except subprocess.TimeoutExpired:
        raise SplitError(
            "Separating these contacts took too long. Nothing was lost; "
            "try again in a few minutes.", 504, reason="undo_timeout")
    return proc.returncode, proc.stdout, proc.stderr


def _record_distinct(keep: str, discard: str) -> Dict[str, Any]:
    from duplicate_decision import write_decision
    return write_decision({"action": "distinct",
                           "ids": [short_id(keep), short_id(discard)]})


def _last_json_line(text: str) -> Dict[str, Any]:
    for line in reversed((text or "").splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except ValueError:
                return {}
    return {}


def split(
    merge_id: Any,
    *,
    jdir: Optional[str] = None,
    run_undo: Optional[Callable[[str], Tuple[int, str, str]]] = None,
    record_distinct: Optional[Callable[[str, str], Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    """Undo one journalled merge and keep the pair apart. See module doc."""
    if not isinstance(merge_id, str) or not MERGE_ID_RE.match(merge_id):
        raise SplitError("That is not a merge this Hub knows about.", 400,
                         reason="bad_merge_id")
    jdir = jdir or journal_dir()
    run_undo = run_undo or _run_undo
    record_distinct = record_distinct or _record_distinct
    with _LOCK:
        _state, entries = read_journal(jdir)
        merge = _find_merge(entries, merge_id)
        if merge is None:
            raise SplitError("That is not a merge this Hub knows about.", 404,
                             reason="unknown_merge")
        keep, discard = merge["keep"], merge["discard"]
        snap = _snapshot(jdir, merge)
        cards = [_card(snap, keep), _card(snap, discard)]
        if merge_id in _undone_ids(entries):
            # Make sure the decision exists even for an undo run from a
            # terminal, then answer as a success: the pair is apart.
            record_distinct(keep, discard)
            return {"status": "already_split", "merge_id": merge_id,
                    "cards": cards, "pinned_distinct": True}
        try:
            record_distinct(keep, discard)
        except Exception as exc:  # noqa: BLE001
            raise SplitError(
                "Your answer could not be saved, so nothing was changed.", 500,
                reason=f"decision_unwritable:{type(exc).__name__}")
        rc, out, err = run_undo(merge_id)
        result = _last_json_line(out)
        if rc != 0 or result.get("merge_id") != merge_id:
            # Another caller (or a terminal) may have undone it meanwhile.
            _s, after = read_journal(jdir)
            if merge_id in _undone_ids(after):
                return {"status": "already_split", "merge_id": merge_id,
                        "cards": cards, "pinned_distinct": True}
            tail = (err or "").strip().splitlines()[-1:] or [""]
            raise SplitError(
                "These contacts could not be separated, so nothing was changed.",
                502, reason=f"undo_failed:{tail[0][:200]}")
        return {"status": "split", "merge_id": merge_id, "cards": cards,
                "pinned_distinct": True,
                "operations": result.get("operations"),
                "qdrant": result.get("qdrant")}
