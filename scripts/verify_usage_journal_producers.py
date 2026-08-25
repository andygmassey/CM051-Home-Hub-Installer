#!/usr/bin/env python3
"""verify_usage_journal_producers.py -- EVERY declared producer, or a RED.

============================================================================
WHAT THIS GATE ASSERTS
============================================================================

After a full compile on a real box, the usage journal must carry a record from
EVERY producer the usage-journal contract declares -- not ">= 1 record of each
kind".

The contract (HR015 launch/USAGE_JOURNAL_CONTRACT.md) asks, in its own gate
paragraph, for "at least one `enriching` record and at least one `ingesting`
record". THREE repos owe `enriching`. So one of them writing satisfies that
predicate forever while the other two are dark, and the panel shows a smaller
number, which reads as a quiet month rather than a broken pipeline. That is the
silent-failure shape the contract says the gate exists to stop, rebuilt inside
the gate itself.

A ">= 1" predicate is a GOLDEN CASE and cannot give a denominator: nine
producers with one writing passes forever. So the denominator is declared, in a
tracked file -- scripts/usage_journal_producers.tsv -- and its size is pinned
separately in scripts/usage_journal_producer_floor.tsv.

============================================================================
THREE OUTCOMES, THREE EXIT CODES. THIS IS THE POINT, NOT THE PACKAGING.
============================================================================

    0   PASS         every REQUIRED producer has at least one record
    1   FAIL         records exist, and a required producer has none of them
    2   CANNOT-RUN   nothing was measured

CANNOT-RUN is not FAIL and is not PASS. It is returned when:

    * the roster or the floor file cannot be read
    * the roster carries fewer rows than the pinned floor -- the gate cannot
      state a denominator, so it has not measured anything
    * the journal does not exist
    * the journal exists and holds ZERO parseable records

The last of those is the one that matters at a box walk. An empty journal means
no producer has EVER written, which is indistinguishable from "no compile has
run yet" -- and calling that a FAIL would train an operator to ignore a red
that fires before they have done the thing being measured. Calling it a PASS
would be worse. It gets its own code.

Once ANY record exists, the pipeline has demonstrably produced something, and a
producer with no record is a genuine absence rather than an unstarted run.

============================================================================
THE JOURNAL PATH IS RESOLVED, NEVER HARDCODED
============================================================================

`~/.ostler/assistant-config/workspace/state/costs.jsonl` is right on a customer
install and nowhere else. This file mirrors the four resolution branches the
daemon uses (zeroclaw-config/src/schema.rs::resolve_runtime_config_dirs), as
ported by HR015 ostler_fda/usage_journal.py::resolve_journal_path.

It is a MIRROR because the writer is not vendored into every tree this gate
runs in. A mirror can drift, and a reader pointed at the wrong directory finds
an absent file -- which this gate reports as CANNOT-RUN, loudly, rather than as
a pass. AND: when `ostler_fda.usage_journal` IS importable, the mirror is
cross-checked against it and a disagreement is CANNOT-RUN, so drift can never
be silent in either direction.

============================================================================
USAGE
============================================================================

    scripts/verify_usage_journal_producers.py
    scripts/verify_usage_journal_producers.py --journal /path/to/costs.jsonl
    scripts/verify_usage_journal_producers.py --print-journal-path

Written for python3.8+, which is what an installed Hub and every runner in this
repo carry. No third-party imports.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

EX_PASS = 0
EX_FAIL = 1
EX_CANNOT_RUN = 2

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ROSTER = REPO_ROOT / "scripts" / "usage_journal_producers.tsv"
DEFAULT_FLOOR = REPO_ROOT / "scripts" / "usage_journal_producer_floor.tsv"

# The five purposes, verbatim from the contract. An UNKNOWN purpose string is
# REJECTED rather than coerced, deliberately: a typo in a pipeline must be
# loud. `"enrichment"` is not `"enriching"`.
VALID_PURPOSES = frozenset(
    {"ingesting", "enriching", "answering", "noticing", "unattributed"}
)

VALID_MATCH_KINDS = frozenset({"session_prefix", "purpose"})


def cannot_run(msg: str) -> "int":
    print("VERDICT: CANNOT-RUN -- %s" % msg)
    return EX_CANNOT_RUN


# ---------------------------------------------------------------------------
# Journal path resolution. Mirrors HR015 ostler_fda/usage_journal.py, which in
# turn ports zeroclaw-config/src/schema.rs::resolve_runtime_config_dirs.
# ---------------------------------------------------------------------------
def _expand(raw: str) -> Path:
    return Path(os.path.expanduser(raw.strip()))


def _default_config_dir() -> Path:
    # The daemon prefers the HOME env var over the passwd database, so we do
    # the same: a process launched with a different HOME must resolve to the
    # same tree the daemon is reading.
    home = os.environ.get("HOME", "").strip()
    return Path(home) / ".ostler" if home else Path.home() / ".ostler"


def _config_dir_from_marker(default_config_dir: Path):
    marker = default_config_dir / "active_workspace.toml"
    try:
        contents = marker.read_text(encoding="utf-8")
    except OSError:
        return None
    raw = ""
    for line in contents.splitlines():
        line = line.strip()
        if not line.startswith("config_dir"):
            continue
        _, _, value = line.partition("=")
        raw = value.strip().strip('"').strip("'").strip()
        break
    if not raw:
        return None
    parsed = _expand(raw)
    return parsed if parsed.is_absolute() else default_config_dir / parsed


def _workspace_for(workspace_env: Path) -> Path:
    # The installer sets ZEROCLAW_WORKSPACE=$OSTLER_DIR/assistant-config, which
    # is a CONFIG dir, not a workspace -- so the daemon appends `workspace`
    # when it finds a config.toml beside it.
    if (workspace_env / "config.toml").exists():
        return workspace_env / "workspace"
    legacy = workspace_env.parent / ".zeroclaw"
    if (legacy / "config.toml").exists():
        return workspace_env
    if workspace_env.name == "workspace":
        return workspace_env
    return workspace_env / "workspace"


def resolve_journal_path() -> Path:
    """<workspace_dir>/state/costs.jsonl, the way the daemon resolves it."""
    config_dir_env = os.environ.get("ZEROCLAW_CONFIG_DIR", "").strip()
    if config_dir_env:
        return _expand(config_dir_env) / "workspace" / "state" / "costs.jsonl"

    workspace_env = (
        os.environ.get("OSTLER_WORKSPACE", "").strip()
        or os.environ.get("ZEROCLAW_WORKSPACE", "").strip()
    )
    if workspace_env:
        return _workspace_for(_expand(workspace_env)) / "state" / "costs.jsonl"

    default_config_dir = _default_config_dir()
    from_marker = _config_dir_from_marker(default_config_dir)
    if from_marker is not None:
        return from_marker / "workspace" / "state" / "costs.jsonl"

    return default_config_dir / "workspace" / "state" / "costs.jsonl"


def _shared_writer_disagreement(mine: Path):
    """Return a disagreement string when the shared writer resolves elsewhere.

    Returns None when the shared writer is not importable (the common case --
    ostler_fda is not on the path in every tree this gate runs in) or when it
    agrees. A DISAGREEMENT is CANNOT-RUN, never a pass: it means this gate and
    the producers are reading and writing two different files, which is the
    exact defect the contract's "RESOLVE that path, never hardcode it" section
    records.
    """
    try:
        from ostler_fda.usage_journal import (  # type: ignore
            resolve_journal_path as authority,
        )
    except Exception:
        return None
    try:
        theirs = Path(authority())
    except Exception as exc:  # pragma: no cover -- the writer raising IS news
        return "ostler_fda.usage_journal.resolve_journal_path() raised %r" % (exc,)
    if theirs != mine:
        return "the shared writer resolves %s, this gate resolves %s" % (theirs, mine)
    return None


# ---------------------------------------------------------------------------
# The roster and its pinned floor.
# ---------------------------------------------------------------------------
class Producer(object):
    __slots__ = ("producer_id", "repo", "purpose", "match_kind", "match_value",
                 "status", "provenance", "hits")

    def __init__(self, row):
        (self.producer_id, self.repo, self.purpose, self.match_kind,
         self.match_value, self.status, self.provenance) = row
        self.hits = 0

    @property
    def required(self):
        return self.status == "required"


def _read_rows(path: Path):
    """Yield non-comment, non-blank TAB-split rows. Raises OSError if absent.

    No `2>/dev/null` equivalent and no swallowed exception: an unreadable
    roster must reach the caller as an error, because "the file said nothing"
    and "I could not read the file" must not print the same.
    """
    text = path.read_text(encoding="utf-8")
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        yield lineno, line.split("\t")


def load_roster(path: Path):
    producers = []
    for lineno, fields in _read_rows(path):
        if len(fields) != 7:
            raise ValueError(
                "%s:%d has %d tab-separated fields, expected 7"
                % (path, lineno, len(fields))
            )
        p = Producer([f.strip() for f in fields])
        if p.match_kind not in VALID_MATCH_KINDS:
            raise ValueError(
                "%s:%d declares match_kind %r; must be one of %s"
                % (path, lineno, p.match_kind, sorted(VALID_MATCH_KINDS))
            )
        if p.purpose not in VALID_PURPOSES:
            raise ValueError(
                "%s:%d declares purpose %r, which the contract does not define"
                % (path, lineno, p.purpose)
            )
        if p.status not in ("required", "dormant"):
            raise ValueError(
                "%s:%d declares status %r; must be required or dormant"
                % (path, lineno, p.status)
            )
        producers.append(p)
    return producers


def load_floor(path: Path):
    floor = {}
    for lineno, fields in _read_rows(path):
        if len(fields) != 2:
            raise ValueError(
                "%s:%d has %d tab-separated fields, expected 2"
                % (path, lineno, len(fields))
            )
        key, raw = fields[0].strip(), fields[1].strip()
        floor[key] = int(raw)
    for key in ("declared", "required"):
        if key not in floor:
            raise ValueError("%s declares no '%s' floor" % (path, key))
    return floor


# ---------------------------------------------------------------------------
# The journal.
# ---------------------------------------------------------------------------
def purpose_of(record):
    """The record's purpose, with the contract's serde default applied.

    "`unattributed` is the serde default on the Rust side, so a record with no
    `purpose` key still parses and lands there."
    """
    usage = record.get("usage")
    if not isinstance(usage, dict):
        return None
    return usage.get("purpose", "unattributed")


def matches(producer, record, purpose):
    if producer.match_kind == "purpose":
        return purpose == producer.match_value
    # session_prefix: the prefix AND the declared purpose. Both, because a
    # producer writing the wrong purpose is also a defect, and matching on the
    # prefix alone would score it present.
    session_id = record.get("session_id")
    if not isinstance(session_id, str):
        return False
    return session_id.startswith(producer.match_value) and purpose == producer.purpose


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    ap.add_argument("--journal", default=None,
                    help="journal file; default is the resolved workspace path")
    ap.add_argument("--roster", default=str(DEFAULT_ROSTER))
    ap.add_argument("--floor", default=str(DEFAULT_FLOOR))
    ap.add_argument("--print-journal-path", action="store_true",
                    help="print the resolved journal path and exit 0")
    args = ap.parse_args(argv)

    if args.journal:
        journal = Path(args.journal)
        resolved_by = "--journal"
    else:
        journal = resolve_journal_path()
        resolved_by = "resolved from the environment"
        drift = _shared_writer_disagreement(journal)
        if drift is not None:
            return cannot_run(
                "the journal path mirror in this gate DISAGREES with the shared "
                "writer: %s. Nothing was read; a reader and a writer pointed at "
                "two different files measure nothing." % drift
            )

    if args.print_journal_path:
        print(journal)
        return EX_PASS

    print("verify_usage_journal_producers")
    print("journal : %s  (%s)" % (journal, resolved_by))

    # -- the roster and its floor -------------------------------------------
    try:
        producers = load_roster(Path(args.roster))
    except (OSError, ValueError) as exc:
        return cannot_run(
            "the producer roster could not be read: %s. With no roster there is "
            "no denominator, and a verdict with no denominator cannot be audited."
            % (exc,)
        )
    try:
        floor = load_floor(Path(args.floor))
    except (OSError, ValueError) as exc:
        return cannot_run(
            "the pinned floor could not be read: %s. Without it the roster could "
            "be emptied and this gate would pass over nothing." % (exc,)
        )

    declared = len(producers)
    required = [p for p in producers if p.required]
    dormant = [p for p in producers if not p.required]
    print("roster  : %s" % args.roster)
    print("floor   : %s (declared >= %d, required >= %d)"
          % (args.floor, floor["declared"], floor["required"]))
    print("EXAMINED: %d declared producers, %d of them required, %d dormant"
          % (declared, len(required), len(dormant)))

    if declared < floor["declared"] or len(required) < floor["required"]:
        return cannot_run(
            "THE ROSTER HAS BEEN SHRUNK BELOW ITS PINNED FLOOR: %d declared / %d "
            "required, against a floor of %d / %d. This gate refuses to state a "
            "verdict over a denominator smaller than the one it was pinned to, "
            "because that is how a gate becomes green by inspecting less."
            % (declared, len(required), floor["declared"], floor["required"])
        )

    # -- the journal --------------------------------------------------------
    if not journal.exists():
        return cannot_run(
            "no journal at %s. No producer has ever written here, which is "
            "indistinguishable from 'no compile has run on this box yet'. That "
            "is not a pass and it is not a failure -- run a full compile, then "
            "run this gate." % journal
        )
    try:
        raw = journal.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return cannot_run("the journal at %s could not be read: %s" % (journal, exc))

    total = 0
    unparseable = 0
    bad_purposes = {}
    for line in raw.splitlines():
        if not line.strip():
            continue
        total += 1
        try:
            record = json.loads(line)
        except ValueError:
            # "A reader that cannot parse a line counts it and moves on."
            unparseable += 1
            continue
        if not isinstance(record, dict):
            unparseable += 1
            continue
        purpose = purpose_of(record)
        if purpose is None:
            unparseable += 1
            continue
        if purpose not in VALID_PURPOSES:
            bad_purposes[purpose] = bad_purposes.get(purpose, 0) + 1
            continue
        for p in producers:
            if matches(p, record, purpose):
                p.hits += 1

    parsed = total - unparseable
    print("EXAMINED: %d journal lines, %d parsed, %d unparseable"
          % (total, parsed, unparseable))
    print()
    print("PRODUCER                      REPO    PURPOSE      STATUS    RECORDS")
    for p in producers:
        print("%-29s %-7s %-12s %-9s %d"
              % (p.producer_id, p.repo, p.purpose, p.status, p.hits))
    print()

    # -- CANNOT-RUN: nothing measured ---------------------------------------
    if parsed == 0:
        return cannot_run(
            "the journal at %s holds %d line(s) and NOT ONE of them parsed. "
            "Zero records is zero evidence about any producer -- it is the same "
            "reading a box gives before its first compile. Not a pass."
            % (journal, total)
        )

    # -- FAIL ---------------------------------------------------------------
    missing = [p for p in required if p.hits == 0]
    present_dormant = [p for p in dormant if p.hits > 0]

    if bad_purposes:
        detail = ", ".join(
            "%r x%d" % (k, v) for k, v in sorted(bad_purposes.items())
        )
        print("VERDICT: FAIL -- the journal carries %d record(s) with a purpose "
              "the contract does not define (%s). The daemon REJECTS an unknown "
              "purpose rather than coercing it, so those records are lost on the "
              "read side and the panel's total is silently short."
              % (sum(bad_purposes.values()), detail))
        return EX_FAIL

    if missing:
        names = ", ".join("%s (%s, %s)" % (p.producer_id, p.repo, p.purpose)
                          for p in missing)
        print("VERDICT: FAIL -- %d of %d REQUIRED producers wrote nothing into "
              "%d parsed record(s): %s."
              % (len(missing), len(required), parsed, names))
        print()
        for p in missing:
            print("  MISSING  %s" % p.producer_id)
            print("           matched by %s=%r, purpose %s"
                  % (p.match_kind, p.match_value, p.purpose))
            print("           %s" % p.provenance)
        print()
        print("  A producer that stops writing is invisible in the panel: the "
              "number just gets smaller,")
        print("  which looks like a quiet month. That is why absence here is a "
              "RED and not a note.")
        return EX_FAIL

    # -- PASS ---------------------------------------------------------------
    print("VERDICT: PASS -- all %d required producers wrote into the journal "
          "(%d parsed records; floor %d)."
          % (len(required), parsed, floor["required"]))
    for p in dormant:
        state = "PRESENT (%d records)" % p.hits if p.hits else "absent, as declared"
        print("  dormant  %s: %s -- %s" % (p.producer_id, state, p.provenance))
    if present_dormant:
        print("  NOTE: a dormant producer is now writing. Promote its roster row "
              "to `required` and raise the pinned floor, or the day it stops "
              "again nothing will notice.")
    if unparseable:
        print("  NOTE: %d unparseable line(s). Every count above is a FLOOR."
              % unparseable)
    return EX_PASS


if __name__ == "__main__":
    sys.exit(main())
