"""Universal "drop your export here" importer for Ostler (FDA backlog T10).

One front door for arbitrary exported data dumps. The operator drops a
folder or a zip (a Facebook "Download Your Information" export, a
WhatsApp chat export, an Apple Notes ``NoteStore.sqlite``, a Google
Takeout archive, a plain ``.mbox``, an Obsidian vault, ...), and this
module:

1. **Sniffs** what it is by inspecting the on-disk structure (not the
   filename), most-specific signal first, and
2. **Routes** it to the matching existing parser already present in
   ``ostler_fda`` (or, for the knowledge sources whose importers live in
   ``doctor.agent``, reports an honest "recognised, no ostler_fda parser
   available" result rather than crashing), and
3. returns a per-source summary.

Design rules
============

* **Reuse, never re-implement.** Detection picks a route; the actual
  extraction is delegated to the existing source parser. If a detected
  format has no callable parser on this build (e.g. the Facebook parser
  still lives on a feature branch, or the bundled ``ostler-knowledge``
  binary that drives the Obsidian/Evernote/Notion knowledge import is
  absent), the result is ``recognised_no_parser`` -- a useful, honest
  outcome, not a failure.

* **Knowledge sources reuse the real importer.** Obsidian vaults,
  Evernote ``.enex`` exports and Notion markdown exports are converted
  by the same ``ostler-knowledge`` binary that the Doctor knowledge
  import UI drives (``doctor.agent.import_evernote`` forks the very
  same ``ostler-knowledge convert --source <kind>`` command). This
  module invokes that binary synchronously so a dropped knowledge
  export actually ingests, falling back to ``recognised_no_parser``
  when the binary is not installed on this build.

* **Honour the underlying parsers' conventions.** Operator name
  (``OSTLER_USER_DISPLAY_NAME`` / ``WIKI_OPERATOR_NAME``) and the
  per-source privacy posture are owned by the target parser. This
  module does not override them.

* **stdlib only** for detection: ``zipfile``, ``os.walk``, a sqlite
  magic-header probe, and JSON structure probing. No heavy heuristics.

Detection contract
==================

``detect_format(path)`` returns a :class:`Detection` with an ordered,
most-specific-first verdict. Each detection carries a ``confidence`` and
the concrete ``signal`` that matched, so the result is auditable. An
unrecognised drop returns ``format="unknown"`` listing what was seen.

CLI
===

    python -m ostler_fda.universal_import <path>            # detect + ingest
    python -m ostler_fda.universal_import <path> --dry-run  # detect only
    python -m ostler_fda.universal_import <path> --json     # machine summary

Exit codes
==========

    0   recognised (ingested, dry-run, or recognised-no-parser)
    3   unknown format (nothing matched)
    4   bad input (path does not exist)
    1   unexpected crash
"""
from __future__ import annotations

import json
import logging
import os
import sqlite3
import sys
import tempfile
import zipfile
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Iterator, List, Optional

logger = logging.getLogger(__name__)

# SQLite file magic header (first 16 bytes of any SQLite 3 database).
_SQLITE_MAGIC = b"SQLite format 3\x00"

# How many files we are willing to walk while sniffing a directory.
# A sane cap so a pathological drop (a whole home folder) cannot make
# detection run unbounded. Detection signals are all near the root.
_WALK_FILE_BUDGET = 50_000


# ---------------------------------------------------------------------------
# Detection result
# ---------------------------------------------------------------------------


@dataclass
class Detection:
    """The verdict of sniffing a dropped path.

    Attributes:
        format: A stable format key (e.g. ``"facebook_messenger"``,
            ``"whatsapp_export"``, ``"apple_notes_sqlite"``,
            ``"google_takeout"``, ``"mbox"``, ``"apple_mail_emlx"``,
            ``"obsidian_vault"``, ``"unknown"``).
        confidence: 0.0-1.0. 1.0 = an unambiguous structural signature.
        signal: Human-readable description of the concrete evidence that
            matched (e.g. ``"messages/inbox/<thread>/message_1.json with
            participants+messages keys"``).
        route_path: The path the parser should be pointed at (may be a
            sub-path of the drop, e.g. the ``.mbox`` inside a Takeout, or
            the extracted temp dir for a zip).
        observed: For ``unknown``, a short list of what was seen at the
            top of the tree -- the "here is what I'd need" honesty hook.
    """

    format: str
    confidence: float
    signal: str
    route_path: Optional[Path] = None
    observed: List[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "format": self.format,
            "confidence": round(self.confidence, 3),
            "signal": self.signal,
            "route_path": str(self.route_path) if self.route_path else None,
            "observed": self.observed,
        }


# ---------------------------------------------------------------------------
# Zip handling
# ---------------------------------------------------------------------------


@contextmanager
def _maybe_unzip(path: Path) -> Iterator[Path]:
    """Yield a directory to inspect.

    If ``path`` is a zip, extract it to a temp dir (cleaned up on exit)
    and yield the extracted root, descending through a single wrapping
    top-level directory if the archive has one (the common
    ``takeout-.../Takeout/...`` and ``facebook-export/.../`` shapes).
    Otherwise yield ``path`` unchanged.
    """
    if path.is_file() and zipfile.is_zipfile(path):
        tmp = Path(tempfile.mkdtemp(prefix="ostler_uimport_"))
        try:
            with zipfile.ZipFile(path) as zf:
                _safe_extract_zip(zf, tmp)
            yield _descend_single_dir(tmp)
        finally:
            _rmtree(tmp)
    else:
        yield path


def _safe_extract_zip(zf: zipfile.ZipFile, dest: Path) -> None:
    """Extract a zip, refusing any member that escapes ``dest``.

    Defends against zip-slip / absolute-path members. Members that would
    resolve outside ``dest`` are skipped with a warning rather than
    extracted.
    """
    dest = dest.resolve()
    for member in zf.namelist():
        target = (dest / member).resolve()
        if dest != target and dest not in target.parents:
            logger.warning("universal_import: skipping unsafe zip member %r", member)
            continue
        zf.extract(member, dest)


def _descend_single_dir(root: Path) -> Path:
    """If ``root`` contains exactly one entry and it is a directory,
    descend into it. Many exports wrap everything in one folder.
    """
    try:
        entries = [e for e in root.iterdir() if e.name != "__MACOSX"]
    except OSError:
        return root
    if len(entries) == 1 and entries[0].is_dir():
        return entries[0]
    return root


def _rmtree(path: Path) -> None:
    import shutil

    try:
        shutil.rmtree(path, ignore_errors=True)
    except Exception:  # noqa: BLE001 -- best-effort temp cleanup
        pass


# ---------------------------------------------------------------------------
# Low-level structural probes (stdlib only)
# ---------------------------------------------------------------------------


def _is_sqlite(path: Path) -> bool:
    """True iff ``path`` is a file whose first bytes are the SQLite magic."""
    try:
        if not path.is_file():
            return False
        with path.open("rb") as fh:
            return fh.read(16) == _SQLITE_MAGIC
    except OSError:
        return False


def _sqlite_has_tables(path: Path, wanted: Iterable[str]) -> bool:
    """True iff the SQLite db at ``path`` contains all of ``wanted`` tables.

    Read-only, exception-safe. Used to disambiguate two SQLite databases
    that both pass the magic-header probe (Apple Notes' ``NoteStore`` vs
    WhatsApp's ``ChatStorage`` vs iMessage's ``chat.db``).
    """
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    except sqlite3.Error:
        return False
    try:
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type IN ('table','view')"
        ).fetchall()
        names = {r[0] for r in rows}
        return all(w in names for w in wanted)
    except sqlite3.Error:
        return False
    finally:
        conn.close()


def _walk_files(root: Path, budget: int = _WALK_FILE_BUDGET) -> Iterator[Path]:
    """Yield files under ``root`` up to a budget, skipping noise dirs."""
    count = 0
    for dirpath, dirnames, filenames in os.walk(root):
        # Prune obvious noise so the budget is spent on real content.
        dirnames[:] = [d for d in dirnames if d != "__MACOSX"]
        for name in filenames:
            yield Path(dirpath) / name
            count += 1
            if count >= budget:
                return


def _find_first(root: Path, name: str, budget: int = _WALK_FILE_BUDGET) -> Optional[Path]:
    """Return the first file named ``name`` found under ``root``."""
    for f in _walk_files(root, budget):
        if f.name == name:
            return f
    return None


def _looks_like_whatsapp_txt(path: Path) -> bool:
    """True iff ``path`` is a WhatsApp text chat export.

    WhatsApp's "Export chat" produces a ``.txt`` whose lines look like::

        [2024-01-02, 14:33:21] Alice: hello
        02/01/2024, 14:33 - Alice: hello

    We accept either the bracketed or the dash form on any of the first
    handful of non-blank lines. Lightweight, no full parse.
    """
    import re

    if path.suffix.lower() != ".txt":
        return False
    bracketed = re.compile(r"^\[\d{1,4}[./-]\d{1,2}[./-]\d{1,4},?\s+\d{1,2}:\d{2}")
    # WhatsApp's dashed export form separates timestamp and sender with a
    # hyphen, and in some locales an en-dash (U+2013). Match either; the
    # en-dash is written as a \u escape so this source file stays
    # ASCII-clean (the pre-commit guard rejects literal en/em dashes).
    _dash_class = "[-\u2013]"  # hyphen or en-dash
    dashed = re.compile(
        r"^\d{1,4}[./-]\d{1,2}[./-]\d{1,4},?\s+\d{1,2}:\d{2}\s*" + _dash_class + r"\s+"
    )
    try:
        with path.open("r", encoding="utf-8", errors="ignore") as fh:
            checked = 0
            for line in fh:
                line = line.lstrip("‎﻿ ").rstrip("\n")
                if not line:
                    continue
                if bracketed.match(line) or dashed.match(line):
                    return True
                checked += 1
                if checked >= 8:
                    break
    except OSError:
        return False
    return False


def _json_has_keys(path: Path, keys: Iterable[str]) -> bool:
    """True iff the JSON object at ``path`` has all of ``keys`` at top level."""
    try:
        with path.open("r", encoding="utf-8", errors="ignore") as fh:
            # Facebook message_1.json files are small enough to load.
            data = json.load(fh)
    except (OSError, ValueError):
        return False
    if not isinstance(data, dict):
        return False
    return all(k in data for k in keys)


# ---------------------------------------------------------------------------
# Format detectors (ordered most-specific-first)
# ---------------------------------------------------------------------------
#
# Each detector takes the (already-unzipped) inspection root and returns a
# Detection or None. detect_format() runs them in order and returns the
# first hit. Order matters: a Google Takeout *contains* an mbox, so
# Takeout must be probed before the bare-mbox detector; an Obsidian vault
# is *.md files, so it must be probed after the more specific structural
# signatures.


def _detect_facebook(root: Path) -> Optional[Detection]:
    # Facebook DYI: messages/inbox/<thread>/message_1.json with
    # participants + messages keys. Accept the known root variants.
    inbox_roots = [
        root / "messages" / "inbox",
        root / "inbox",
        root / "your_activity_across_facebook" / "messages" / "inbox",
    ]
    if root.name == "inbox":
        inbox_roots.insert(0, root)
    for inbox in inbox_roots:
        if not inbox.is_dir():
            continue
        msg = _find_first(inbox, "message_1.json", budget=5000)
        if msg and _json_has_keys(msg, ("participants", "messages")):
            return Detection(
                format="facebook_messenger",
                confidence=1.0,
                signal=f"messages/inbox/<thread>/message_1.json with "
                f"participants+messages keys ({msg.parent.name})",
                route_path=root,
            )
    return None


def _detect_apple_notes(root: Path) -> Optional[Detection]:
    candidate = root if root.name == "NoteStore.sqlite" and root.is_file() else None
    if candidate is None:
        candidate = _find_first(root, "NoteStore.sqlite", budget=20000)
    if candidate and _is_sqlite(candidate):
        return Detection(
            format="apple_notes_sqlite",
            confidence=1.0,
            signal=f"NoteStore.sqlite (SQLite magic) at {candidate.name}",
            route_path=candidate,
        )
    return None


def _detect_whatsapp_sqlite(root: Path) -> Optional[Detection]:
    candidate = root if root.name == "ChatStorage.sqlite" and root.is_file() else None
    if candidate is None:
        candidate = _find_first(root, "ChatStorage.sqlite", budget=20000)
    if candidate and _is_sqlite(candidate):
        return Detection(
            format="whatsapp_sqlite",
            confidence=1.0,
            signal=f"ChatStorage.sqlite (SQLite magic) at {candidate.name}",
            route_path=candidate,
        )
    return None


def _detect_imessage_sqlite(root: Path) -> Optional[Detection]:
    candidate = root if root.name == "chat.db" and root.is_file() else None
    if candidate is None:
        candidate = _find_first(root, "chat.db", budget=20000)
    if candidate and _is_sqlite(candidate) and _sqlite_has_tables(
        candidate, ("message", "handle", "chat")
    ):
        return Detection(
            format="imessage_chatdb",
            confidence=1.0,
            signal="chat.db (SQLite with message/handle/chat tables)",
            route_path=candidate,
        )
    return None


def _detect_google_takeout(root: Path) -> Optional[Detection]:
    # A Takeout/ subtree is the strong signal. The mbox within it is the
    # route target (Gmail slice). If a Takeout/ dir exists but holds no
    # mbox, we still recognise it -- but route to the mbox when present.
    takeout_dir = None
    if root.name == "Takeout" and root.is_dir():
        takeout_dir = root
    elif (root / "Takeout").is_dir():
        takeout_dir = root / "Takeout"
    if takeout_dir is None:
        return None
    mbox = None
    for f in _walk_files(takeout_dir, budget=20000):
        if f.suffix.lower() == ".mbox":
            mbox = f
            break
    return Detection(
        format="google_takeout",
        confidence=1.0,
        signal="Takeout/ directory"
        + (f" containing {mbox.name}" if mbox else " (no .mbox slice found)"),
        route_path=mbox if mbox else takeout_dir,
    )


def _detect_apple_mail_emlx(root: Path) -> Optional[Detection]:
    # An Apple Mail export (the "18 - Apple Mail" GDPR slice, or a copied
    # ~/Library/Mail tree) is a directory of ``.emlx`` message files nested
    # under ``*.mbox/.../Messages/``. Apple confusingly names those folders
    # ``*.mbox`` but they are NOT RFC 4155 mbox files -- the real payload is
    # the per-message ``.emlx``. So this detector runs BEFORE _detect_mbox:
    # an Apple Mail tree has no bare ``.mbox`` *file*, only ``.mbox``
    # *directories*, and _detect_mbox would otherwise miss it entirely.
    if root.is_file() and root.suffix.lower() == ".emlx":
        return Detection(
            format="apple_mail_emlx",
            confidence=0.95,
            signal=f"{root.name} (.emlx Apple Mail message)",
            route_path=root.parent,
        )
    for f in _walk_files(root, budget=20000):
        if f.suffix.lower() == ".emlx" or f.name.lower().endswith(".partial.emlx"):
            return Detection(
                format="apple_mail_emlx",
                confidence=0.9,
                signal=f"{f.name} (.emlx Apple Mail message under drop)",
                route_path=root,
            )
    return None


def _detect_mbox(root: Path) -> Optional[Detection]:
    # A bare .mbox file or a directory containing one (not inside a
    # Takeout -- that detector runs first and wins).
    if root.is_file() and root.suffix.lower() == ".mbox":
        return Detection(
            format="mbox",
            confidence=0.95,
            signal=f"{root.name} (.mbox file)",
            route_path=root,
        )
    for f in _walk_files(root, budget=20000):
        if f.suffix.lower() == ".mbox":
            return Detection(
                format="mbox",
                confidence=0.9,
                signal=f"{f.name} (.mbox file under drop)",
                route_path=f,
            )
    return None


def _detect_whatsapp_txt(root: Path) -> Optional[Detection]:
    if root.is_file() and _looks_like_whatsapp_txt(root):
        return Detection(
            format="whatsapp_export",
            confidence=0.85,
            signal=f"{root.name} matches WhatsApp '[date, time] sender: msg'",
            route_path=root,
        )
    for f in _walk_files(root, budget=5000):
        if f.suffix.lower() == ".txt" and _looks_like_whatsapp_txt(f):
            return Detection(
                format="whatsapp_export",
                confidence=0.8,
                signal=f"{f.name} matches WhatsApp '[date, time] sender: msg'",
                route_path=f,
            )
    return None


def _detect_obsidian(root: Path) -> Optional[Detection]:
    if (root / ".obsidian").is_dir():
        return Detection(
            format="obsidian_vault",
            confidence=1.0,
            signal=".obsidian/ config directory present",
            route_path=root,
        )
    return None


def _detect_evernote(root: Path) -> Optional[Detection]:
    if root.is_file() and root.suffix.lower() == ".enex":
        return Detection(
            format="evernote_enex",
            confidence=1.0,
            signal=f"{root.name} (.enex file)",
            route_path=root,
        )
    for f in _walk_files(root, budget=5000):
        if f.suffix.lower() == ".enex":
            return Detection(
                format="evernote_enex",
                confidence=0.95,
                signal=f"{f.name} (.enex file under drop)",
                route_path=f,
            )
    return None


def _detect_markdown_collection(root: Path) -> Optional[Detection]:
    # Last-resort knowledge signal: a directory with several .md files
    # (a Notion export or a plain markdown folder) and no more specific
    # signature. Lower confidence -- it is genuinely ambiguous.
    md_count = 0
    for f in _walk_files(root, budget=5000):
        if f.suffix.lower() in (".md", ".markdown"):
            md_count += 1
            if md_count >= 3:
                break
    if md_count >= 3:
        return Detection(
            format="markdown_collection",
            confidence=0.5,
            signal=f"{md_count}+ markdown files, no more-specific signature",
            route_path=root,
        )
    return None


# Order is load-bearing: most specific structural signatures first.
_DETECTORS: List[Callable[[Path], Optional[Detection]]] = [
    _detect_facebook,
    _detect_apple_notes,
    _detect_whatsapp_sqlite,
    _detect_imessage_sqlite,
    _detect_google_takeout,
    _detect_apple_mail_emlx,
    _detect_mbox,
    _detect_whatsapp_txt,
    _detect_obsidian,
    _detect_evernote,
    _detect_markdown_collection,
]


def detect_format(root: Path) -> Detection:
    """Sniff an already-unzipped inspection root, most-specific first.

    Returns the first matching :class:`Detection`, or an ``unknown``
    Detection listing the top-level entries it saw (the "here is what I'd
    need" honesty hook).
    """
    root = Path(root)
    for detector in _DETECTORS:
        try:
            hit = detector(root)
        except Exception as exc:  # noqa: BLE001 -- a probe must never crash detection
            logger.warning("universal_import: detector %s raised %s", detector.__name__, exc)
            hit = None
        if hit is not None:
            return hit

    observed: List[str] = []
    try:
        if root.is_dir():
            for e in sorted(root.iterdir())[:20]:
                observed.append(e.name + ("/" if e.is_dir() else ""))
        else:
            observed.append(root.name)
    except OSError:
        pass
    return Detection(
        format="unknown",
        confidence=0.0,
        signal="no known format signature matched",
        route_path=None,
        observed=observed,
    )


# ---------------------------------------------------------------------------
# Dispatch: route a detection to the matching existing parser
# ---------------------------------------------------------------------------
#
# Each dispatcher reuses an EXISTING parser. It must never re-implement
# extraction. Where a recognised format has no callable parser on this
# build (Facebook still on a feature branch; the ``ostler-knowledge``
# binary that drives Obsidian/Evernote/Notion not installed), the
# dispatcher returns status "recognised_no_parser" -- an honest,
# non-crashing result.

# Knowledge formats (Obsidian / Evernote / Notion) all convert through
# the same bundled ``ostler-knowledge`` binary. The Doctor knowledge
# import UI (``doctor.agent.import_evernote``) forks exactly this command;
# we drive it synchronously here. The value is the ``--source`` kind the
# binary expects for each detected format.
_KNOWLEDGE_SOURCES = {
    "obsidian_vault": "obsidian",
    "evernote_enex": "evernote",
    "markdown_collection": "notion",
}

# Resolve the same binary path the Doctor runner uses, honouring the same
# override env var so the two stay consistent on every install.
_DEFAULT_KNOWLEDGE_BIN = "/usr/local/bin/ostler-knowledge"


def _dispatch(detection: Detection, *, dry_run: bool, output_dir: Optional[Path]) -> dict:
    """Route a detection to its parser and return a per-source summary."""
    fmt = detection.format
    base = {"format": fmt, "detection": detection.to_dict()}

    if fmt == "unknown":
        return {**base, "status": "unknown"}

    if dry_run:
        return {**base, "status": "detected", "dispatched": False}

    handler = _DISPATCH.get(fmt)
    if handler is None:
        # A recognised-but-unrouted format (e.g. whatsapp_export .txt,
        # which has no ostler_fda parser).
        return {
            **base,
            "status": "recognised_no_parser",
            "detail": f"recognised {fmt}; no ostler_fda parser available on this build",
        }

    try:
        return {**base, **handler(detection, output_dir=output_dir)}
    except Exception as exc:  # noqa: BLE001 -- surface type only (privacy)
        logger.warning("universal_import: dispatch for %s failed: %s", fmt, exc)
        return {**base, "status": "error", "error": type(exc).__name__}


def _out_dir(output_dir: Optional[Path]) -> Path:
    d = output_dir or (Path.home() / ".ostler" / "imports" / "fda")
    d.mkdir(parents=True, exist_ok=True)
    return d


# ---------------------------------------------------------------------------
# Conversation persistence (reuse the real CM048 sink, never reimplement)
# ---------------------------------------------------------------------------
#
# A dropped Facebook Messenger export (and, later, any conversation-shaped
# source) becomes a list of CM048 ``process()`` payloads -- a dict per
# thread with ``conversation_id`` / ``transcript`` / ``metadata`` keys. The
# canonical conversation sink for the whole product is the CM048 pipeline:
# the ``pwg-convo process <transcript> <metadata>`` CLI that the per-channel
# WhatsApp / iMessage / email / meeting bundles already drive. We persist by
# driving that SAME CLI, one payload at a time -- we do NOT re-implement the
# Qdrant / Oxigraph / four-artefact bundle writes that CM048 owns.
#
# Deliberately decoupled (productisation Rule 0.5): ostler_fda does NOT
# import the CM048 package. It shells out to the installed ``pwg-convo``
# binary instead, so the two repos stay decoupled on disk and a build
# without the pipeline degrades to honest "staged, not persisted" rather
# than an import error.
#
# Skip-if-absent: when no ``pwg-convo`` is resolvable the payloads remain in
# the staging JSON and the result reports ``persist_status="no_pipeline"``.
# Never fatal: a single thread that fails the pipeline is counted, not
# raised, so one bad thread cannot abort the import of the rest.

# The Doctor / per-feed bundles resolve pwg-convo by this env var first,
# then the CM048 venv binary, then the /usr/local/bin symlink, then PATH.
_DEFAULT_PWG_CONVO_BIN = "/usr/local/bin/pwg-convo"


def _pwg_convo_cmd() -> Optional[List[str]]:
    """Resolve the ``pwg-convo`` invocation, or None if not installed.

    Honours ``OSTLER_PWG_CONVO_CMD`` (an absolute path or a shell-style
    command string the per-feed bundles also read) before falling back to
    the CM048 venv binary, the install symlink, and finally ``PATH``. The
    returned value is an argv prefix; the caller appends
    ``["process", <transcript>, <metadata>]``. Returns None when nothing is
    resolvable so the caller can fall back to "staged, not persisted".
    """
    import shlex
    import shutil

    raw = os.environ.get("OSTLER_PWG_CONVO_CMD", "").strip()
    if raw:
        parts = shlex.split(raw)
        if parts:
            head = Path(parts[0]).expanduser()
            if head.is_absolute() or os.sep in parts[0]:
                return [str(head), *parts[1:]] if head.is_file() else None
            resolved = shutil.which(parts[0])
            return [resolved, *parts[1:]] if resolved else None

    # CM048 venv binary (absolute, no PATH dependency under launchd).
    venv_bin = Path.home() / ".ostler" / "services" / "cm048" / ".venv" / "bin" / "pwg-convo"
    if venv_bin.is_file():
        return [str(venv_bin)]

    default = Path(_DEFAULT_PWG_CONVO_BIN)
    if default.is_file():
        return [str(default)]

    found = shutil.which("pwg-convo")
    return [found] if found else None


def _persist_conversations(payloads: List[dict], *, source: str) -> dict:
    """Hand CM048 ``process()`` payloads to the real conversation sink.

    Drives ``pwg-convo process <transcript> <metadata>`` once per payload
    (the exact CLI the per-channel conversation bundles use), so a dropped
    export's threads land in the conversations store the rest of the
    product reads. Reuse, never re-implement: this function owns no store
    writes of its own.

    Args:
        payloads: list of dicts each with ``conversation_id`` /
            ``transcript`` / ``metadata`` -- the CM048 process() shape.
        source: a short source label for log lines (privacy: label only,
            never bodies).

    Returns:
        A counts-only dict: ``persist_status`` (``ok`` / ``no_pipeline`` /
        ``partial``), ``persisted`` (threads accepted by the pipeline), and
        ``persist_failed`` (threads the pipeline rejected). No names, no
        bodies -- safe to log and to surface on the install summary.
    """
    import subprocess

    if not payloads:
        return {"persist_status": "ok", "persisted": 0, "persist_failed": 0}

    cmd_prefix = _pwg_convo_cmd()
    if cmd_prefix is None:
        logger.info(
            "universal_import: %s conversations staged but pwg-convo not "
            "installed; not persisted to the conversations store", source
        )
        return {
            "persist_status": "no_pipeline",
            "persisted": 0,
            "persist_failed": 0,
        }

    persisted = 0
    failed = 0
    for payload in payloads:
        conv_id = payload.get("conversation_id")
        transcript = payload.get("transcript")
        metadata = payload.get("metadata")
        if not conv_id or transcript is None or metadata is None:
            failed += 1
            continue
        # Stage transcript + metadata to a temp pair (cleaned up) exactly
        # as the CLI expects: process() reads two files.
        tmp = Path(tempfile.mkdtemp(prefix="ostler_convo_"))
        try:
            t_file = tmp / "transcript.md"
            m_file = tmp / "metadata.json"
            t_file.write_text(transcript)
            m_file.write_text(json.dumps(metadata))
            cmd = [*cmd_prefix, "process", str(t_file), str(m_file)]
            proc = subprocess.run(cmd, check=False, capture_output=True, text=True)
            if proc.returncode == 0:
                persisted += 1
            else:
                # Surface the exit code only -- never the captured output,
                # which can carry thread content.
                logger.warning(
                    "universal_import: pwg-convo process rejected a %s "
                    "conversation (exit %s)", source, proc.returncode
                )
                failed += 1
        except (OSError, ValueError) as exc:  # noqa: BLE001 -- type only (privacy)
            logger.warning(
                "universal_import: pwg-convo exec failed for %s (%s)",
                source, type(exc).__name__,
            )
            failed += 1
        finally:
            _rmtree(tmp)

    status = "ok" if failed == 0 else ("partial" if persisted else "error")
    return {
        "persist_status": status,
        "persisted": persisted,
        "persist_failed": failed,
    }


def _dispatch_facebook(detection: Detection, *, output_dir: Optional[Path]) -> dict:
    try:
        from . import facebook_messenger as fbm
    except ImportError:
        return {
            "status": "recognised_no_parser",
            "detail": "recognised Facebook Messenger export; facebook_messenger "
            "parser not present on this build",
        }
    threads = fbm.parse_export(export_root=detection.route_path)
    stats = fbm.conversation_stats(threads)
    payloads = [
        fbm.thread_to_payload(t)
        for t in threads
        if getattr(t, "tier", None) != getattr(fbm, "TIER_T3_SKIP", object())
    ]
    out = _out_dir(output_dir)
    (out / "facebook_messenger_conversations.json").write_text(
        json.dumps(payloads, indent=2)
    )
    # Persist to the real conversations store via the CM048 pipeline. The
    # staging JSON above stays as the durable, re-runnable artefact; this
    # additionally routes each ingestible thread through pwg-convo so the
    # conversation actually lands in the store the product reads. Honest
    # skip-if-absent: when pwg-convo is not installed the threads remain
    # staged and persist_status reports "no_pipeline" (no crash, no abort).
    persist = _persist_conversations(payloads, source="facebook_messenger")
    return {
        "status": "ok",
        "dispatched": "facebook_messenger",
        "summary": stats,
        **persist,
    }


def _dispatch_whatsapp_sqlite(detection: Detection, *, output_dir: Optional[Path]) -> dict:
    from . import whatsapp_history as wa

    chats = wa.extract_conversations(db_path=detection.route_path)
    stats = wa.conversation_stats(chats)
    ingestible = [c for c in chats if c.tier != wa.TIER_T3_SKIP]
    out = _out_dir(output_dir)
    (out / "whatsapp_conversations.json").write_text(
        json.dumps([wa.chat_to_dict(c) for c in ingestible], indent=2)
    )
    return {"status": "ok", "dispatched": "whatsapp_history", "summary": stats}


def _dispatch_apple_notes(detection: Detection, *, output_dir: Optional[Path]) -> dict:
    from dataclasses import asdict

    from . import apple_notes as an

    notes = an.extract_notes(db_path=detection.route_path, include_locked=False)
    out = _out_dir(output_dir)
    (out / "apple_notes.json").write_text(
        json.dumps([asdict(n) for n in notes], indent=2, default=str)
    )
    return {
        "status": "ok",
        "dispatched": "apple_notes",
        "summary": {
            "notes": len(notes),
            "total_words": sum(n.word_count for n in notes),
        },
    }


def _dispatch_imessage(detection: Detection, *, output_dir: Optional[Path]) -> dict:
    from dataclasses import asdict

    from . import imessage as im

    convs = im.extract_conversations(db_path=detection.route_path)
    stats = im.conversation_stats(convs)
    out = _out_dir(output_dir)
    (out / "imessage_conversations.json").write_text(
        json.dumps([asdict(c) for c in convs], indent=2, default=str)
    )
    return {"status": "ok", "dispatched": "imessage", "summary": stats}


# ---------------------------------------------------------------------------
# Mail people-graph persistence (reuse the real pwg_ingest sink)
# ---------------------------------------------------------------------------
#
# A dropped mailbox (Gmail Takeout .mbox or an Apple Mail .emlx tree) becomes
# a CORRESPONDENT-FREQUENCY map -- ``{email: count}`` for every address the
# operator exchanged mail with. That map is the exact staging shape the
# existing ``pwg_ingest.ingest_mail_contacts`` already reads
# (``apple_mail_contacts.json``), so persisting people-graph facts is just:
# build the map while streaming, stage the JSON, then drive the SAME ingest
# function the FDA sweep uses. Reuse, never re-implement: this module owns no
# Oxigraph writes of its own.
#
# Privacy posture: ONLY people-graph facts are persisted -- who the operator
# corresponds with, and how often. Message BODIES are never persisted or
# surfaced here. The mbox is streamed metadata-only (body preview is dropped
# the moment a count is taken) so no body content leaves this process. The
# resulting Person nodes inherit ``pwg_ingest.DEFAULT_PRIVACY`` (L2), the
# normal People privacy level, exactly as the live FDA Apple Mail ingest does.
# Thread bodies -> the conversation sink are a deliberate follow-up (see the
# module note above _dispatch_mbox): routing them safely needs the per-message
# privacy levelling iMessage/WhatsApp bodies get, so this leg stays people-only.
#
# Skip-if-absent: when the graph (Oxigraph) is unreachable the staged JSON
# remains as the durable, re-runnable artefact and the result reports
# ``persist_status="no_graph"`` -- honest, never a crash, never an install
# failure. One unreachable graph cannot abort the rest of an import.

# The staging file pwg_ingest.ingest_mail_contacts reads. Keeping the exact
# filename means we drive the unmodified ingest function, no new sink.
_MAIL_CONTACTS_STAGING = "apple_mail_contacts.json"


def _persist_mail_contacts(contacts: dict, *, source: str) -> dict:
    """Hand a ``{email: count}`` correspondent map to the people-graph sink.

    Stages the map as ``apple_mail_contacts.json`` and drives the existing
    ``pwg_ingest.ingest_mail_contacts`` (the same function the FDA sweep
    uses) so each frequent correspondent lands as a ``pwg:Person`` with an
    email identifier at the normal People privacy level. Reuse, never
    re-implement -- this function owns no graph writes.

    Args:
        contacts: ``{email: count}`` -- correspondent address to message
            count. No names, no subjects, no bodies.
        source: short source label for log lines (privacy: label only).

    Returns:
        A counts-only dict: ``persist_status`` (``ok`` / ``no_graph`` /
        ``error``) and ``people_created``. No addresses, no bodies -- safe
        to log and to surface on the install summary.
    """
    if not contacts:
        return {"persist_status": "ok", "people_created": 0}

    # The ingest function reads its staging file from a fda_dir; we own a
    # private temp dir so we never clobber a real FDA staging directory.
    staging = Path(tempfile.mkdtemp(prefix="ostler_mail_"))
    try:
        (staging / _MAIL_CONTACTS_STAGING).write_text(json.dumps(contacts))
        from . import pwg_ingest as pwg

        result = pwg.ingest_mail_contacts(staging)
        if result.get("status") == "ok":
            return {
                "persist_status": "ok",
                "people_created": int(result.get("people_created", 0)),
            }
        # ingest_mail_contacts returned a non-ok status (e.g. "skipped").
        return {"persist_status": "ok", "people_created": 0}
    except Exception as exc:  # noqa: BLE001 -- graph down or transient; type only
        # Skip-if-absent: an unreachable Oxigraph (or any ingest failure) is
        # not fatal. The staged JSON stays in output_dir below for a re-run.
        logger.info(
            "universal_import: %s contacts staged but people-graph sink "
            "unavailable (%s); not persisted", source, type(exc).__name__
        )
        return {"persist_status": "no_graph", "people_created": 0}
    finally:
        _rmtree(staging)


# Hard cap on messages streamed from one mailbox so a pathological 37GB
# Gmail mbox cannot wedge the install. Override via OSTLER_MBOX_MAX_MESSAGES
# (0 or negative = unlimited, for an operator who explicitly wants the lot).
# 250k covers a very heavy multi-year mailbox while bounding wall-time.
_MBOX_MESSAGE_CAP = 250_000


def _mbox_message_cap() -> Optional[int]:
    """Resolve the per-mailbox streaming cap, or None for unlimited."""
    raw = os.environ.get("OSTLER_MBOX_MAX_MESSAGES", "").strip()
    if not raw:
        return _MBOX_MESSAGE_CAP
    try:
        n = int(raw)
    except ValueError:
        return _MBOX_MESSAGE_CAP
    return None if n <= 0 else n


def _stream_mbox_correspondents(
    mbox_path: Path,
) -> tuple[dict, int, int, int]:
    """Stream an mbox once, returning correspondent counts + tallies.

    Single bounded pass over the mailbox (the underlying ``stream_messages``
    is a generator, so a 37GB file is never loaded into memory). Builds a
    ``{email: count}`` map over the operator's correspondents -- senders of
    received mail and recipients of sent mail -- the people-graph signal.
    Body previews are discarded the instant the address is counted; no body
    content is retained.

    Returns:
        ``(contacts, total, sent, received)`` -- the correspondent map and
        plain message tallies. Counts only, no bodies.
    """
    from . import google_takeout as gt

    user_email = (os.environ.get("OSTLER_USER_EMAIL", "").strip() or None)
    cap = _mbox_message_cap()
    contacts: dict[str, int] = {}
    total = sent = received = 0
    for m in gt.stream_messages(
        mbox_path,
        since_days=365 * 5,
        limit=cap,
        user_email=user_email,
    ):
        total += 1
        if m.is_sent:
            sent += 1
            # Sent mail: the correspondents are the recipients.
            for addr in m.to_addresses:
                if addr:
                    contacts[addr] = contacts.get(addr, 0) + 1
        else:
            received += 1
            # Received mail: the correspondent is the sender.
            if m.from_address:
                contacts[m.from_address] = contacts.get(m.from_address, 0) + 1
    return contacts, total, sent, received


def _dispatch_mbox(detection: Detection, *, output_dir: Optional[Path]) -> dict:
    contacts, total, sent, received = _stream_mbox_correspondents(
        detection.route_path
    )
    out = _out_dir(output_dir)
    (out / "mbox_summary.json").write_text(
        json.dumps(
            {
                "total_messages": total,
                "sent_count": sent,
                "received_count": received,
                "correspondent_count": len(contacts),
                "source_path": str(detection.route_path),
            },
            indent=2,
            default=str,
        )
    )
    # Stage the correspondent map as the durable artefact, then persist
    # people-graph facts via the real pwg_ingest sink. Skip-if-absent: when
    # the graph is unreachable the JSON stays staged and persist_status
    # reports "no_graph" (no crash, no abort).
    (out / _MAIL_CONTACTS_STAGING).write_text(json.dumps(contacts, indent=2))
    persist = _persist_mail_contacts(contacts, source="mbox")
    return {
        "status": "ok",
        "dispatched": "google_takeout(mbox)",
        "summary": {
            "total_messages": total,
            "sent_count": sent,
            "received_count": received,
            "correspondent_count": len(contacts),
        },
        **persist,
    }


def _emlx_tree_to_mbox(emlx_root: Path, mbox_path: Path) -> int:
    """Convert an Apple Mail ``.emlx`` tree into a single mbox file.

    Reuses ``apple_mail_mbox``'s existing emlx building blocks
    (``discover_emlx_files`` + ``parse_emlx`` + ``_format_mbox_record``) --
    the SAME parser the live Apple Mail -> CM046 bridge uses -- rather than
    re-implementing emlx decoding. Streams one file at a time and appends to
    the output mbox; a 37GB mailbox is never held in memory. One corrupt
    ``.emlx`` is skipped (counted, never raised) so a single bad message
    cannot abort the conversion (the #249 hardening class).

    Returns the number of messages written.
    """
    from . import apple_mail_mbox as amx

    cap = _mbox_message_cap()
    written = 0
    with mbox_path.open("wb") as out:
        for emlx in amx.discover_emlx_files(emlx_root):
            if cap is not None and written >= cap:
                break
            try:
                parsed = amx.parse_emlx(emlx)
            except (OSError, ValueError) as exc:  # noqa: BLE001 -- type only
                logger.debug(
                    "universal_import: skipping unparseable .emlx (%s)",
                    type(exc).__name__,
                )
                continue
            out.write(amx._format_mbox_record(parsed))
            written += 1
    return written


def _dispatch_apple_mail_emlx(detection: Detection, *, output_dir: Optional[Path]) -> dict:
    # Apple Mail dropped as a ``.emlx`` tree. Convert it to a single mbox
    # (reusing the existing emlx parser), then route through the very same
    # correspondent -> people-graph flow the Gmail mbox uses. People-only,
    # bodies never persisted -- identical privacy posture to _dispatch_mbox.
    out = _out_dir(output_dir)
    work = Path(tempfile.mkdtemp(prefix="ostler_emlx_"))
    mbox_path = work / "apple_mail.mbox"
    try:
        converted = _emlx_tree_to_mbox(detection.route_path, mbox_path)
        if converted == 0:
            return {
                "status": "ok",
                "dispatched": "apple_mail(emlx)",
                "summary": {"total_messages": 0, "correspondent_count": 0},
                "persist_status": "ok",
                "people_created": 0,
            }
        contacts, total, sent, received = _stream_mbox_correspondents(mbox_path)
        (out / "mbox_summary.json").write_text(
            json.dumps(
                {
                    "total_messages": total,
                    "sent_count": sent,
                    "received_count": received,
                    "correspondent_count": len(contacts),
                    "emlx_converted": converted,
                    "source_path": str(detection.route_path),
                },
                indent=2,
                default=str,
            )
        )
        (out / _MAIL_CONTACTS_STAGING).write_text(json.dumps(contacts, indent=2))
        persist = _persist_mail_contacts(contacts, source="apple_mail_emlx")
        return {
            "status": "ok",
            "dispatched": "apple_mail(emlx)",
            "summary": {
                "total_messages": total,
                "sent_count": sent,
                "received_count": received,
                "correspondent_count": len(contacts),
                "emlx_converted": converted,
            },
            **persist,
        }
    finally:
        _rmtree(work)


def _dispatch_google_takeout(detection: Detection, *, output_dir: Optional[Path]) -> dict:
    # route_path is the .mbox if one was found, else the Takeout dir.
    if detection.route_path and detection.route_path.suffix.lower() == ".mbox":
        return _dispatch_mbox(detection, output_dir=output_dir)
    return {
        "status": "recognised_no_parser",
        "detail": "recognised Google Takeout but found no Gmail .mbox slice to ingest",
    }


def _knowledge_bin() -> Optional[str]:
    """Resolve the ``ostler-knowledge`` binary, or None if not present.

    Honours ``OSTLER_KNOWLEDGE_BIN`` (the same override the Doctor runner
    reads) before falling back to the install default. An absolute path
    must exist on disk; a bare name is resolved against ``PATH``. Returns
    None when nothing is found so the caller can fall back to an honest
    ``recognised_no_parser`` rather than crashing on a missing binary.
    """
    import shutil

    raw = os.environ.get("OSTLER_KNOWLEDGE_BIN", _DEFAULT_KNOWLEDGE_BIN).strip()
    if not raw:
        return None
    candidate = Path(raw).expanduser()
    if candidate.is_absolute() or os.sep in raw:
        return str(candidate) if candidate.is_file() else None
    return shutil.which(raw)


def _dispatch_knowledge(detection: Detection, *, output_dir: Optional[Path]) -> dict:
    """Convert a knowledge export via the bundled ``ostler-knowledge`` binary.

    Reuses the exact command the Doctor knowledge import runner forks
    (``ostler-knowledge convert --source <kind> <path> --output <dir>``),
    run synchronously so a dropped Obsidian vault / Evernote ``.enex`` /
    Notion markdown export actually ingests. If the binary is absent we
    return the honest ``recognised_no_parser`` result; we never crash.
    """
    import subprocess

    source = _KNOWLEDGE_SOURCES.get(detection.format)
    if source is None:  # pragma: no cover -- registry/detector mismatch guard
        return {
            "status": "recognised_no_parser",
            "detail": f"recognised {detection.format}; no knowledge source mapping",
        }

    binary = _knowledge_bin()
    if binary is None:
        return {
            "status": "recognised_no_parser",
            "detail": (
                f"recognised {detection.format}; the ostler-knowledge importer "
                "is not installed on this build"
            ),
        }

    staging = _out_dir(output_dir) / "knowledge"
    staging.mkdir(parents=True, exist_ok=True)
    cmd = [
        binary, "convert", "--source", source,
        str(detection.route_path), "--output", str(staging),
    ]
    try:
        proc = subprocess.run(cmd, check=False, capture_output=True, text=True)
    except (OSError, ValueError) as exc:
        # Binary vanished between the which() probe and exec, or a bad arg.
        logger.warning("universal_import: ostler-knowledge exec failed: %s", type(exc).__name__)
        return {
            "status": "recognised_no_parser",
            "detail": (
                f"recognised {detection.format}; could not run the ostler-knowledge "
                f"importer ({type(exc).__name__})"
            ),
        }

    if proc.returncode != 0:
        return {
            "status": "error",
            "dispatched": f"ostler-knowledge({source})",
            "error": "import_failed",
            "exit_code": proc.returncode,
        }
    return {
        "status": "ok",
        "dispatched": f"ostler-knowledge({source})",
        "summary": {"source": source, "output_dir": str(staging)},
    }


_DISPATCH: dict = {
    "facebook_messenger": _dispatch_facebook,
    "whatsapp_sqlite": _dispatch_whatsapp_sqlite,
    "apple_notes_sqlite": _dispatch_apple_notes,
    "imessage_chatdb": _dispatch_imessage,
    "mbox": _dispatch_mbox,
    "google_takeout": _dispatch_google_takeout,
    "apple_mail_emlx": _dispatch_apple_mail_emlx,
    # Knowledge formats convert through the bundled ostler-knowledge binary.
    "obsidian_vault": _dispatch_knowledge,
    "evernote_enex": _dispatch_knowledge,
    "markdown_collection": _dispatch_knowledge,
    # whatsapp_export (.txt) intentionally has no ostler_fda dispatcher --
    # see _dispatch() for the honest recognised_no_parser result.
}


# ---------------------------------------------------------------------------
# Public entry
# ---------------------------------------------------------------------------


def import_path(
    path: Path,
    *,
    dry_run: bool = False,
    output_dir: Optional[Path] = None,
) -> dict:
    """Detect the format of a dropped path and dispatch to its parser.

    Args:
        path: A folder or a zip of an exported data dump.
        dry_run: Detect + report only; do not ingest.
        output_dir: Where dispatched parsers write their JSON. Defaults
            to ``~/.ostler/imports/fda``.

    Returns:
        A summary dict: ``{"input", "dry_run", "result": {...}}``.
    """
    path = Path(path).expanduser()
    if not path.exists():
        return {
            "input": str(path),
            "dry_run": dry_run,
            "result": {"format": "unknown", "status": "no_such_path"},
        }

    with _maybe_unzip(path) as inspect_root:
        detection = detect_format(inspect_root)
        result = _dispatch(detection, dry_run=dry_run, output_dir=output_dir)

    return {"input": str(path), "dry_run": dry_run, "result": result}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: Optional[List[str]] = None) -> int:
    import argparse

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    parser = argparse.ArgumentParser(
        prog="pwg-universal-import",
        description=(
            "Drop a folder or zip of an exported data dump; this sniffs the "
            "format and routes it to the matching Ostler parser."
        ),
    )
    parser.add_argument("path", type=Path, help="Folder or zip to import.")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="Where dispatched parsers write JSON. Default ~/.ostler/imports/fda.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Detect and report only; do not ingest.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit the machine-readable summary as JSON to stdout.",
    )
    args = parser.parse_args(argv)

    try:
        summary = import_path(
            args.path, dry_run=args.dry_run, output_dir=args.output_dir
        )
    except Exception as exc:  # noqa: BLE001 -- surface type only (privacy)
        logger.error("universal_import: unexpected failure: %s", type(exc).__name__)
        return 1

    result = summary["result"]
    if args.json:
        print(json.dumps(summary, default=str))
    else:
        det = result.get("detection", {})
        logger.info("Input:      %s", summary["input"])
        logger.info("Format:     %s (confidence %s)", result.get("format"),
                    det.get("confidence"))
        if det.get("signal"):
            logger.info("Signal:     %s", det["signal"])
        logger.info("Status:     %s", result.get("status"))
        if result.get("detail"):
            logger.info("Detail:     %s", result["detail"])
        if result.get("dispatched"):
            logger.info("Dispatched: %s", result["dispatched"])
        if result.get("summary"):
            logger.info("Summary:    %s", json.dumps(result["summary"], default=str))
        if result.get("format") == "unknown" and det.get("observed"):
            logger.info("Saw:        %s", ", ".join(det["observed"]))

    status = result.get("status")
    if status in ("ok", "detected", "recognised_no_parser"):
        return 0
    if status == "unknown":
        return 3
    if status == "no_such_path":
        return 4
    return 1


if __name__ == "__main__":
    sys.exit(main())
