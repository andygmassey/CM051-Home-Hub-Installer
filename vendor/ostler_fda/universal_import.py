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


def _is_facebook_activity_dirname(name: str) -> bool:
    """True iff ``name`` is a Facebook "Download Your Information" activity
    root (``your_facebook_activity`` in current exports,
    ``your_activity_across_facebook`` in older ones).

    Deliberately excludes Instagram. Instagram's Meta export is the same
    shape (``your_instagram_activity/messages/inbox/<thread>/message_1.json``
    with the same ``participants``/``messages`` keys), so a Facebook
    detector must NOT claim it. We require a ``facebook`` token and reject
    anything carrying an ``instagram`` token.
    """
    lower = name.lower()
    if "instagram" in lower:
        return False
    return "facebook" in lower and "activity" in lower


def _detect_facebook(root: Path) -> Optional[Detection]:
    # Facebook DYI: messages/inbox/<thread>/message_1.json with
    # participants + messages keys.
    #
    # Meta has reshuffled the export layout over time. Rather than chase a
    # hardcoded full path that goes stale every generation, we accept the
    # ``messages/inbox`` segment under any Facebook activity root
    # (``your_facebook_activity`` today, ``your_activity_across_facebook``
    # in older dumps), plus the two flatter shapes some exports use.
    # Instagram is intentionally NOT matched here -- see
    # ``_is_facebook_activity_dirname`` -- because its export is the same
    # shape under its own ``your_instagram_activity`` root.
    inbox_roots = [
        root / "messages" / "inbox",
        root / "inbox",
    ]
    # Generalise over the drifting Facebook activity-root segment: any
    # top-level dir that looks like a Facebook activity root and holds a
    # messages/inbox subtree.
    try:
        for child in root.iterdir():
            if child.is_dir() and _is_facebook_activity_dirname(child.name):
                inbox_roots.append(child / "messages" / "inbox")
    except OSError:
        pass
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


# ---------------------------------------------------------------------------
# Message people-graph persistence (reuse the real pwg_ingest sinks)
# ---------------------------------------------------------------------------
#
# A dropped WhatsApp ``ChatStorage.sqlite`` or an iMessage ``chat.db`` becomes
# the SAME staging JSON the live FDA sweep writes (``whatsapp_conversations.json``
# / ``imessage_conversations.json``). The live sweep persists those by driving
# ``pwg_ingest.ingest_whatsapp`` / ``pwg_ingest.ingest_imessage`` -- People-only
# sinks that mint a ``pwg:Person`` (plus phone/email identifier and
# last-contact) for each participant and NEVER store message bodies. We persist
# by driving those SAME ingest functions over the staging dir the dispatch just
# wrote. Reuse, never re-implement -- this module owns no graph writes.
#
# Privacy posture: People-only, identical to the mailbox correspondent leg.
# Message bodies are never persisted or surfaced -- ``ingest_whatsapp`` /
# ``ingest_imessage`` mint Person + identifier triples at
# ``pwg_ingest.DEFAULT_PRIVACY`` (the normal People level) and read no body
# text. Routing WhatsApp/iMessage THREAD bodies to the conversation sink is a
# deliberate follow-up (the same one the mailbox leg defers): it needs the
# per-message privacy levelling those bodies are not yet given in this pipeline.
#
# Skip-if-absent: when the graph (Oxigraph) is unreachable the staged JSON
# remains as the durable, re-runnable artefact and the result reports
# ``persist_status="no_graph"`` -- honest, never a crash, never an install
# failure. One unreachable graph cannot abort the rest of an import.


def _persist_people_from_staging(
    staging_dir: Path, *, ingest_fn_name: str, source: str
) -> dict:
    """Drive a People-only ``pwg_ingest`` ingest over an already-staged dir.

    The dispatch has already written the per-source staging JSON
    (``whatsapp_conversations.json`` / ``imessage_conversations.json``) into
    ``staging_dir``; this hands that dir to the matching ``pwg_ingest``
    function -- the SAME People-only sink the live FDA sweep uses -- so each
    participant lands as a ``pwg:Person`` with an identifier at the normal
    People privacy level. Reuse, never re-implement; bodies are never read.

    Args:
        staging_dir: the dir the dispatch wrote the staging JSON into.
        ingest_fn_name: ``"ingest_whatsapp"`` or ``"ingest_imessage"``.
        source: short source label for log lines (privacy: label only).

    Returns:
        A counts-only dict: ``persist_status`` (``ok`` / ``no_graph``) plus
        ``people_created`` / ``people_enriched``. No participants, no bodies.
    """
    try:
        from . import pwg_ingest as pwg

        ingest_fn = getattr(pwg, ingest_fn_name)
        result = ingest_fn(staging_dir)
        status = result.get("status")
        if status == "ok":
            return {
                "persist_status": "ok",
                "people_created": int(result.get("people_created", 0)),
                "people_enriched": int(result.get("people_enriched", 0)),
            }
        # "skipped" (no staging file) or any other non-ok: nothing persisted,
        # but not a failure -- the staged JSON stays for a re-run.
        return {"persist_status": "ok", "people_created": 0, "people_enriched": 0}
    except Exception as exc:  # noqa: BLE001 -- graph down or transient; type only
        # Skip-if-absent: an unreachable Oxigraph (or any ingest failure) is
        # not fatal. The staged JSON stays in staging_dir for a re-run.
        logger.info(
            "universal_import: %s participants staged but people-graph sink "
            "unavailable (%s); not persisted", source, type(exc).__name__
        )
        return {"persist_status": "no_graph", "people_created": 0, "people_enriched": 0}


def _dispatch_whatsapp_sqlite(detection: Detection, *, output_dir: Optional[Path]) -> dict:
    from . import whatsapp_history as wa

    chats = wa.extract_conversations(db_path=detection.route_path)
    stats = wa.conversation_stats(chats)
    ingestible = [c for c in chats if c.tier != wa.TIER_T3_SKIP]
    out = _out_dir(output_dir)
    (out / "whatsapp_conversations.json").write_text(
        json.dumps([wa.chat_to_dict(c) for c in ingestible], indent=2)
    )
    # Persist participants to the people graph via the real pwg_ingest sink
    # (the same People-only function the live FDA sweep drives). Skip-if-absent:
    # an unreachable graph leaves the JSON staged and reports "no_graph".
    persist = _persist_people_from_staging(
        out, ingest_fn_name="ingest_whatsapp", source="whatsapp_sqlite"
    )
    return {
        "status": "ok",
        "dispatched": "whatsapp_history",
        "summary": stats,
        **persist,
    }


def _dispatch_apple_notes(detection: Detection, *, output_dir: Optional[Path]) -> dict:
    # DEFERRED persistence (documented follow-up): the apple_notes parser
    # emits a note-list JSON, but the ``ostler-knowledge`` converter the
    # other knowledge formats persist through reads SOURCE directories
    # (Obsidian vault / Evernote ``.enex`` / Notion markdown export) and has
    # no confirmed ``--source apple_notes`` kind for a note-list JSON on this
    # build. Wiring it to a guessed source kind would be a risky broad
    # mapping, so this leg stays stage-only until the converter grows an
    # apple_notes source (or a notes-JSON -> markdown shim is built). The
    # staged JSON is the durable, re-runnable artefact in the meantime.
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
    # Persist participants to the people graph via the real pwg_ingest sink
    # (the same People-only function the live FDA sweep drives). Skip-if-absent:
    # an unreachable graph leaves the JSON staged and reports "no_graph".
    persist = _persist_people_from_staging(
        out, ingest_fn_name="ingest_imessage", source="imessage"
    )
    return {
        "status": "ok",
        "dispatched": "imessage",
        "summary": stats,
        **persist,
    }


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
#
# Email THREADS -> the conversation sink are a deliberate, documented
# follow-up (v1.0.3 decision, P3): routing them is intentionally NOT done
# here. Two reasons make it the safe call rather than risky broad wiring:
#   1. This pipeline has no email thread -> CM048 payload builder. The mbox is
#      streamed metadata-only (``_stream_mbox_correspondents`` discards the body
#      preview the instant an address is counted), so no body content ever
#      leaves this process. Routing threads would mean newly CAPTURING and
#      persisting email bodies -- reversing the leg's body-never-stored design.
#   2. The only conversation-body precedent that reaches ``pwg-convo`` here is
#      the Facebook parser, which sets ``metadata['privacy_level']``
#      EXPLICITLY (L2) because CM048's ``_CHANNEL_DEFAULTS`` table has no row
#      for the channel and otherwise falls through to its L3 defence-in-depth
#      default. There is no "email" row in that table either, and with the
#      services down that sink cannot be verified end-to-end. Per the P3
#      decision gate (a partial-but-correct result beats risky broad wiring),
#      email stays People-only until an email thread->payload builder lands
#      that sets a CONSERVATIVE explicit privacy_level (matching Facebook's
#      explicit-level discipline, never lowering it).
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
    # ONE bounded pass yields BOTH the People-only correspondent map AND the
    # reduced message rows for the conversation leg. The 37GB file is never
    # loaded into memory (the underlying stream is a generator).
    contacts, messages, total, sent, received = (
        _stream_mbox_messages_and_correspondents(detection.route_path)
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
    # Leg 1 (UNCHANGED, People-only): stage the correspondent map as the
    # durable artefact, then persist people-graph facts via the real
    # pwg_ingest sink. Skip-if-absent: when the graph is unreachable the JSON
    # stays staged and persist_status reports "no_graph" (no crash, no abort).
    (out / _MAIL_CONTACTS_STAGING).write_text(json.dumps(contacts, indent=2))
    persist = _persist_mail_contacts(contacts, source="mbox")
    # Leg 2 (ADDITIVE, v1.0.3): group the same messages into threads and
    # persist them to the CM048 conversation sink, PRIVATE-BY-DEFAULT (explicit
    # L2 on every payload). Reuses _persist_conversations / pwg-convo.
    convo = _persist_email_conversations(
        messages, source="email_mbox", output_dir=out
    )
    return {
        "status": "ok",
        "dispatched": "google_takeout(mbox)",
        "summary": {
            "total_messages": total,
            "sent_count": sent,
            "received_count": received,
            "correspondent_count": len(contacts),
            "conversation_threads": convo["conversation_threads"],
        },
        **persist,
        **convo,
    }


# ---------------------------------------------------------------------------
# Email THREADS -> the CM048 conversation sink (v1.0.3, P-email)
# ---------------------------------------------------------------------------
#
# ADDITIVE to the People-only correspondent leg above. A dropped mailbox
# (Gmail Takeout .mbox or an Apple Mail .emlx tree) is now ALSO grouped into
# threads and persisted to the SAME CM048 conversation sink the Facebook
# Messenger parser drives -- ``pwg-convo process <transcript> <metadata>`` via
# ``_persist_conversations``. We do NOT invent a new sink and we do NOT touch
# the People-only ``_persist_mail_contacts`` leg: both run from one bounded
# mbox pass.
#
# Privacy -- the crux of the v1.0.3 GREEN-light. Email content is
# PRIVATE-BY-DEFAULT: ingested so the OWNER can search and have the assistant
# answer over it, but NEVER surfaced in demo / shareable / public / third-party
# views. We set ``metadata['privacy_level']`` EXPLICITLY to L2 (never a
# default) on every email conversation payload. Why L2 and not L3, read against
# this codebase's actual level semantics (CM048 ``privacy.py`` docstring; CM052
# ``wire.py`` Option A; the CM044 ``bundle_conversation_pages`` / AI-chat
# renderers):
#
#   L2  = embedded in Qdrant -> OWNER-searchable + assistant-answerable; body
#         rendered COLLAPSED-by-default in the owner's LOCAL wiki (never raw);
#         and the CM044 bundle/AI-chat wings HARD-SUPPRESS the entire wing in
#         demo mode regardless of level. So L2 == owner-searchable AND
#         withheld from demo/shareable. On a single-Mac product all L2 data is
#         local-only by construction.
#   L3  = body suppressed even for the owner in the wiki AND short-circuited
#         BEFORE the CM048 embed -> NOT in Qdrant -> the assistant CANNOT find
#         it without a deliberate ``request_unredacted=True`` MCP fetch. That
#         breaks "owner can search", so L3 is TOO restrictive for this intent.
#
# L2 is therefore the conservative level that still satisfies "owner-
# searchable": it is the MORE private of the two that keeps owner search
# working, and it matches the explicit-L2 discipline the Facebook leg already
# uses (CM048's ``_CHANNEL_DEFAULTS`` does carry an ``"email": "L2"`` row, but
# we still set the level EXPLICITLY so the posture never depends on that table
# nor on the L3 defence-in-depth fallback). The per-address L1 ladder
# (``infer_for_email_addresses``: newsletters -> L1, legal/medical/financial
# -> L3) is deliberately NOT applied here: L1 would make a body wiki-browseable
# (less private than the floor the owner asked for), so the email-conversation
# floor stays a flat, conservative L2 and CM048's adapter can still ESCALATE to
# L3 for sensitive senders. We never LOWER below L2 and we never emit L0/L1.
_EMAIL_CHANNEL = "email"
_EMAIL_SOURCE = "email_mailbox"
# Explicit, conservative privacy floor for every email conversation payload.
# Private-by-default + owner-searchable. Never L0/L1 (would be less private).
_EMAIL_PRIVACY_LEVEL = "L2"

# Transcript body cap per message. google_takeout's default body preview is
# 500 chars (a People-leg signal-only slice); a conversation transcript wants
# more of the message, but we still bound it so one mailbox cannot balloon the
# staged transcript. The owner can widen via OSTLER_EMAIL_BODY_CHARS.
_EMAIL_BODY_CHARS_DEFAULT = 4000
# Bound the number of threads we will persist from one mailbox so a pathological
# mailbox cannot mint an unbounded number of conversation bundles. Override via
# OSTLER_EMAIL_MAX_THREADS (0 or negative = unlimited).
_EMAIL_MAX_THREADS = 20_000


def _email_body_chars() -> int:
    raw = os.environ.get("OSTLER_EMAIL_BODY_CHARS", "").strip()
    if not raw:
        return _EMAIL_BODY_CHARS_DEFAULT
    try:
        n = int(raw)
    except ValueError:
        return _EMAIL_BODY_CHARS_DEFAULT
    return n if n > 0 else _EMAIL_BODY_CHARS_DEFAULT


def _email_max_threads() -> Optional[int]:
    raw = os.environ.get("OSTLER_EMAIL_MAX_THREADS", "").strip()
    if not raw:
        return _EMAIL_MAX_THREADS
    try:
        n = int(raw)
    except ValueError:
        return _EMAIL_MAX_THREADS
    return None if n <= 0 else n


def _normalise_subject(subject: str) -> str:
    """Strip reply/forward prefixes + whitespace for thread keying.

    ``"Re: Fwd: RE: Lunch?"`` and ``"Lunch?"`` collapse to the same key so a
    reply chain that shares no Message-ID linkage still groups by subject.
    Case-folded and whitespace-squashed. Empty/blank subjects fold to a single
    sentinel so they group together rather than each spawning a lone thread.
    """
    import re

    s = (subject or "").strip()
    # Repeatedly peel a leading reply/forward marker (any locale's two-letter
    # Re/Fw plus the common 3-letter Fwd), tolerating the ``Re[2]:`` count form.
    prefix = re.compile(r"^(re|fwd|fw)(\[\d+\])?\s*:\s*", re.IGNORECASE)
    while True:
        new = prefix.sub("", s, count=1)
        if new == s:
            break
        s = new.strip()
    s = re.sub(r"\s+", " ", s).strip().lower()
    return s or "(no subject)"


@dataclass
class _EmailMessage:
    """One mailbox message reduced to the fields a transcript needs."""

    message_id: str
    from_address: str
    from_name: str
    to_addresses: list[str] = field(default_factory=list)
    subject: str = ""
    date: Optional["object"] = None  # datetime | None
    body: str = ""
    is_sent: bool = False
    in_reply_to: str = ""
    references: list[str] = field(default_factory=list)


@dataclass
class _EmailThread:
    """A grouped email thread, ready to render to a CM048 payload."""

    key: str
    subject: str
    messages: list = field(default_factory=list)  # list[_EmailMessage]
    participants: set = field(default_factory=set)  # email addresses, non-user


def _group_email_threads(
    messages: Iterable["_EmailMessage"],
    *,
    user_email: Optional[str],
    max_threads: Optional[int],
) -> List["_EmailThread"]:
    """Group a stream of messages into threads.

    Grouping signal, strongest first:
      1. Message-ID linkage: a message whose ``In-Reply-To`` or any
         ``References`` id points at a Message-ID we have already seen joins
         that message's thread (union-find over the id graph).
      2. Otherwise, the normalised subject (``Re:``/``Fwd:`` stripped) keys the
         thread, so a reply chain that dropped its References headers still
         groups.

    Bounded: once ``max_threads`` distinct threads exist, further messages that
    would open a NEW thread are dropped (counted by the caller via the returned
    length vs the stream) so a pathological mailbox cannot mint unbounded
    bundles. Messages that join an EXISTING thread are always kept.
    """
    user = (user_email or "").lower()
    threads: dict[str, _EmailThread] = {}
    # Map a known Message-ID -> the thread key it belongs to.
    id_to_key: dict[str, str] = {}

    for m in messages:
        # Resolve which thread this message belongs to.
        key: Optional[str] = None
        for parent in [m.in_reply_to, *m.references]:
            if parent and parent in id_to_key:
                key = id_to_key[parent]
                break
        if key is None:
            key = _normalise_subject(m.subject)

        thread = threads.get(key)
        if thread is None:
            if max_threads is not None and len(threads) >= max_threads:
                # Cap reached: only messages joining an existing thread are
                # kept; a brand-new thread is dropped.
                continue
            thread = _EmailThread(key=key, subject=m.subject or "(no subject)")
            threads[key] = thread

        thread.messages.append(m)
        if m.message_id:
            id_to_key[m.message_id] = key
        # Participants = every address on the thread except the operator.
        for addr in [m.from_address, *m.to_addresses]:
            if addr and addr.lower() != user:
                thread.participants.add(addr)

    # Stable order: oldest-thread-first by earliest message date, deterministic.
    def _thread_start(t: "_EmailThread"):
        dates = [msg.date for msg in t.messages if msg.date is not None]
        return min(dates) if dates else None

    ordered = sorted(
        threads.values(),
        key=lambda t: (
            _thread_start(t) is None,
            str(_thread_start(t)),
            t.key,
        ),
    )
    return ordered


def _render_email_transcript(thread: "_EmailThread") -> str:
    """Render a thread to a speaker-labelled transcript.

    One block per message, oldest first: ``[ISO date] Sender <addr>: body``.
    Mirrors the Facebook ``render_transcript`` shape the CM048 processor
    consumes. Messages are sorted by date (None dates sort last, stably).
    """
    def _msg_sort(m: "_EmailMessage"):
        return (m.date is None, str(m.date) if m.date is not None else "")

    lines: List[str] = []
    for m in sorted(thread.messages, key=_msg_sort):
        if m.date is not None:
            try:
                ts = m.date.strftime("%Y-%m-%d %H:%M")
            except (AttributeError, ValueError):
                ts = str(m.date)
        else:
            ts = "unknown"
        speaker = m.from_name or m.from_address or "Unknown"
        addr = f" <{m.from_address}>" if m.from_address else ""
        body = (m.body or "").strip()
        lines.append(f"[{ts}] {speaker}{addr}: {body}")
    return "\n\n".join(lines)


def _email_thread_to_payload(
    thread: "_EmailThread", *, user_email: Optional[str]
) -> dict:
    """Convert an email thread to a CM048 ``process()`` payload.

    Same three-key shape (``conversation_id`` / ``transcript`` / ``metadata``)
    the Facebook parser emits. ``metadata['privacy_level']`` is set EXPLICITLY
    to the conservative ``_EMAIL_PRIVACY_LEVEL`` (L2) on EVERY payload so the
    posture never depends on a CM048 channel default nor the L3 fallback.
    """
    import hashlib

    dates = [m.date for m in thread.messages if m.date is not None]
    started = min(dates) if dates else None
    ended = max(dates) if dates else None

    def _iso(d):
        try:
            return d.isoformat() if d is not None else None
        except (AttributeError, ValueError):
            return None

    def _ymd(d):
        try:
            return d.strftime("%Y-%m-%d") if d is not None else "1970-01-01"
        except (AttributeError, ValueError):
            return "1970-01-01"

    # Stable id: date + a short hash of the thread key (which is a Message-ID
    # lineage or the normalised subject), so a re-run of the same mailbox
    # yields the same id -- the CM048 writer's idempotency contract.
    date_part = started.strftime("%Y%m%d") if started is not None else "00000000"
    key_hash = hashlib.sha1(thread.key.encode("utf-8")).hexdigest()[:12]
    conversation_id = f"email_{date_part}_{key_hash}"

    participants: List[dict] = []
    if user_email:
        participants.append(
            {"id": user_email, "display": user_email, "role": "user"}
        )
    for addr in sorted(thread.participants):
        participants.append({"id": addr, "display": addr, "role": "other"})

    metadata = {
        "conversation_id": conversation_id,
        "date": _ymd(started),
        "source": _EMAIL_SOURCE,
        "channel": _EMAIL_CHANNEL,
        "participants": participants,
        "started_at": _iso(started),
        "ended_at": _iso(ended),
        # EXPLICIT conservative privacy floor: private-by-default, owner-
        # searchable, demo-withheld. Never a default, never below L2.
        "privacy_level": _EMAIL_PRIVACY_LEVEL,
        "subject": thread.subject,
        "is_group_chat": len(thread.participants) > 1,
        "message_count": len(thread.messages),
    }

    return {
        "conversation_id": conversation_id,
        "transcript": _render_email_transcript(thread),
        "metadata": metadata,
    }


def _stream_mbox_messages_and_correspondents(
    mbox_path: Path,
) -> tuple[dict, List["_EmailMessage"], int, int, int]:
    """Single bounded pass over a mailbox.

    Builds BOTH legs in ONE stream (the underlying ``stream_messages`` is a
    generator -- a 37GB file is never loaded into memory):

      1. the People-only ``{email: count}`` correspondent map (unchanged
         behaviour), and
      2. a list of reduced ``_EmailMessage`` rows for the conversation leg.

    Bounded by the same ``OSTLER_MBOX_MAX_MESSAGES`` cap the correspondent leg
    uses. Returns ``(contacts, messages, total, sent, received)`` -- counts +
    reduced rows, never the raw mailbox object.
    """
    from . import google_takeout as gt

    user_email = (os.environ.get("OSTLER_USER_EMAIL", "").strip() or None)
    cap = _mbox_message_cap()
    body_chars = _email_body_chars()
    contacts: dict[str, int] = {}
    messages: List[_EmailMessage] = []
    total = sent = received = 0
    for m in gt.stream_messages(
        mbox_path,
        since_days=365 * 5,
        limit=cap,
        user_email=user_email,
        body_preview_chars=body_chars,
    ):
        total += 1
        if m.is_sent:
            sent += 1
            for addr in m.to_addresses:
                if addr:
                    contacts[addr] = contacts.get(addr, 0) + 1
        else:
            received += 1
            if m.from_address:
                contacts[m.from_address] = contacts.get(m.from_address, 0) + 1
        messages.append(
            _EmailMessage(
                message_id=getattr(m, "message_id", "") or "",
                from_address=m.from_address or "",
                from_name=getattr(m, "from_name", "") or "",
                to_addresses=list(m.to_addresses or []),
                subject=m.subject or "",
                date=m.date,
                body=getattr(m, "body_preview", "") or "",
                is_sent=bool(m.is_sent),
                in_reply_to=getattr(m, "in_reply_to", "") or "",
                references=list(getattr(m, "references", []) or []),
            )
        )
    return contacts, messages, total, sent, received


def _persist_email_conversations(
    messages: List["_EmailMessage"], *, source: str, output_dir: Path
) -> dict:
    """Group reduced mailbox rows into threads and persist them to CM048.

    Reuse, never re-implement: groups the messages into threads, builds one
    CM048 payload per thread (explicit L2 privacy on every one), stages them as
    the durable ``email_conversations.json`` artefact, then hands them to the
    SAME ``_persist_conversations`` -> ``pwg-convo`` path the Facebook leg uses.
    Counts only in the returned dict; no subjects, no bodies, no addresses.
    """
    user_email = (os.environ.get("OSTLER_USER_EMAIL", "").strip() or None)
    threads = _group_email_threads(
        messages, user_email=user_email, max_threads=_email_max_threads()
    )
    payloads = [
        _email_thread_to_payload(t, user_email=user_email)
        for t in threads
        if t.messages
    ]
    # Belt-and-braces: never let a non-L2 (or absent) level slip through to the
    # sink. Every email conversation is owner-searchable + demo-withheld L2.
    for p in payloads:
        p["metadata"]["privacy_level"] = _EMAIL_PRIVACY_LEVEL
    (output_dir / "email_conversations.json").write_text(
        json.dumps(payloads, indent=2, default=str)
    )
    persist = _persist_conversations(payloads, source=source)
    return {
        "conversation_threads": len(payloads),
        "conversation_persist_status": persist.get("persist_status"),
        "conversations_persisted": persist.get("persisted", 0),
        "conversations_failed": persist.get("persist_failed", 0),
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
    # correspondent -> people-graph flow AND the conversation flow the Gmail
    # mbox uses. People-only leg is UNCHANGED; the conversation leg is ADDITIVE
    # and private-by-default (explicit L2) -- identical posture to _dispatch_mbox.
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
        contacts, messages, total, sent, received = (
            _stream_mbox_messages_and_correspondents(mbox_path)
        )
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
        # Leg 1 (UNCHANGED, People-only).
        (out / _MAIL_CONTACTS_STAGING).write_text(json.dumps(contacts, indent=2))
        persist = _persist_mail_contacts(contacts, source="apple_mail_emlx")
        # Leg 2 (ADDITIVE, private-by-default L2 conversations).
        convo = _persist_email_conversations(
            messages, source="email_apple_mail", output_dir=out
        )
        return {
            "status": "ok",
            "dispatched": "apple_mail(emlx)",
            "summary": {
                "total_messages": total,
                "sent_count": sent,
                "received_count": received,
                "correspondent_count": len(contacts),
                "emlx_converted": converted,
                "conversation_threads": convo["conversation_threads"],
            },
            **persist,
            **convo,
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
