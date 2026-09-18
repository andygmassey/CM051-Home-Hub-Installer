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
    1   FAIL         records exist, and a required producer that HAD AN
                     OPPORTUNITY has none of them
    2   CANNOT-RUN   nothing was measured, or the only producers missing are
                     ones the caller measured had no opportunity

CANNOT-RUN is not FAIL and is not PASS. It is returned when:

    * the roster or the floor file cannot be read
    * the roster carries fewer rows than the pinned floor -- the gate cannot
      state a denominator, so it has not measured anything
    * the journal does not exist
    * the journal exists and holds ZERO parseable records
    * every missing required producer was declared --no-opportunity

The empty-journal one is the one that matters at a box walk. An empty journal
means no producer has EVER written, which is indistinguishable from "no compile
has run yet" -- and calling that a FAIL would train an operator to ignore a red
that fires before they have done the thing being measured. Calling it a PASS
would be worse. It gets its own code.

============================================================================
"A PRODUCER NOBODY ASKED" AND "A PRODUCER THAT BROKE" ARE DIFFERENT (#1634)
============================================================================

The paragraph above used to end: "Once ANY record exists, the pipeline has
demonstrably produced something, and a producer with no record is a genuine
absence rather than an unstarted run."

That is false, and it was the only opportunity test in this file. It is a
GLOBAL test: one producer having written was taken as proof that EVERY producer
had an opportunity. The reading it gets wrong is the one that matters:

    cm051_ostler_fda_ingest   439 records     <- makes parsed > 0
    oa_daemon_chat              0 records     <- therefore FAIL

`oa_daemon_chat` is matched on `purpose=answering`, which the daemon writes when
somebody sends it a channel message. A box that has ingested and compiled but
where nobody has talked to the assistant produces exactly this reading, and the
daemon has behaved perfectly. So `hits == 0` there means EITHER the daemon
answered and failed to record, OR nobody asked it anything -- and this gate
reported the first with no way to see the second.

So opportunity is now PER PRODUCER, and it is DECLARED BY THE CALLER, because
only the caller can see the box:

    --no-opportunity oa_daemon_chat

means "I measured that this producer had no chance to write on this box". The
caller must have measured it; this flag is not a place to put a hunch.

THREE RULES THAT KEEP THIS A NARROWING AND NOT A SILENCER:

  1. A producer with no opportunity is CANNOT-RUN, NEVER PASS. Coverage lost is
     not a clean bill. The point is not to soften the red, it is to stop the red
     naming the wrong cause.
  2. A FAIL BEATS A CANNOT-RUN. If any missing producer was NOT excused, the
     verdict is FAIL and names it -- with the excused ones listed separately, so
     a genuinely dead producer can never hide inside somebody else's excuse.
  3. UNKNOWN IS NOT EXCUSED. A producer the caller says nothing about keeps the
     FAIL. The safe direction is the loud one.

An id that is not in the roster, or is in it as `dormant`, is CANNOT-RUN: an
excuse aimed at nothing is a typo, and a typo that silently excuses nothing
while looking like it excused something is how this class of defect returns.

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
    scripts/verify_usage_journal_producers.py --no-opportunity oa_daemon_chat

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


# ---------------------------------------------------------------------------
# A LEFTOVER STAGING TREE IS NOT THE BOX (#1774), AND THE READER MUST SAY SO.
#
# The probe wrapper already refuses a staging path. This is the SAME refusal in
# the ADJUDICATOR, because the wrapper is not the only caller: the workflow
# invokes this file directly as `python3 scripts/verify_usage_journal_producers.py
# --journal "$F"`, and so could OS003 or a person at a terminal. A guard that
# lives only in one of several callers guards only that caller.
#
# Measured on this branch before the change, with a control of the same shape in
# the same file: `prelaunch|staging` matched 0 lines here, against 55 for
# `journal`, so the reader worked and the absence was real.
#
# REFUSED, NEVER FAILED. A staging path means the live journal was not found,
# which is coverage lost. Calling it a FAIL accuses the producers of a silence
# nobody looked for. That is exit 2, the third state, not exit 1.
#
# TWO SCOPES, deliberately, because the two ways in mean different things:
#
#   resolved from the environment  the full set the probe refuses. Nobody chose
#                                  this path, so any temp-looking prefix means
#                                  the resolver landed on residue.
#   named with --journal           ONLY the unambiguous staging signature,
#                                  `ostler-prelaunch-`. A caller who names a
#                                  path means it, and test fixtures legitimately
#                                  live under /tmp and /var/folders. Refusing
#                                  those would make every fixture CANNOT-RUN,
#                                  which is how a guard gets removed.
_STAGING_SIGNATURE = "ostler-prelaunch-"
_TEMP_PREFIXES = ("/tmp/", "/private/tmp/", "/var/folders/")


def journal_path_is_staging(path, explicitly_named):
    """True when this path is a staging tree rather than the customer's box."""
    text = str(path)
    if _STAGING_SIGNATURE in text:
        return True
    if explicitly_named:
        return False
    return text.startswith(_TEMP_PREFIXES)


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    ap.add_argument("--journal", default=None,
                    help="journal file; default is the resolved workspace path")
    ap.add_argument("--roster", default=str(DEFAULT_ROSTER))
    ap.add_argument("--floor", default=str(DEFAULT_FLOOR))
    ap.add_argument("--print-journal-path", action="store_true",
                    help="print the resolved journal path and exit 0")
    ap.add_argument("--no-opportunity", action="append", default=[],
                    metavar="PRODUCER_ID",
                    help="the caller MEASURED that this producer had no chance "
                         "to write on this box. Its absence becomes CANNOT-RUN "
                         "rather than FAIL. Repeatable. Never turns a verdict "
                         "into a PASS, and never suppresses a FAIL on a "
                         "producer that was not named here.")
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

    if journal_path_is_staging(journal, explicitly_named=bool(args.journal)):
        return cannot_run(
            "the journal path names a STAGING tree, not the customer's box: %s. "
            "A leftover prelaunch tree holds whatever the installer wrote while "
            "OSTLER_DIR still pointed at staging, so adjudicating it measures "
            "the install and not the box. Refused rather than failed: the "
            "producers were never given a chance to be silent here. (#1774)"
            % (journal,)
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

    # -- the caller's per-producer opportunity declarations (#1634) ----------
    #
    # Validated against the roster BEFORE anything is read, and a bad id is
    # CANNOT-RUN rather than a shrug. An excuse aimed at a name nobody declares
    # excuses nothing, which is the safe direction -- but it LOOKS like it
    # excused something, and a caller who mistypes an id would read the
    # resulting FAIL as "the producer really is broken" when in fact its
    # opportunity was never considered. Loud, not clever.
    by_id = {}
    for p in producers:
        by_id[p.producer_id] = p
    no_opportunity = []
    for raw_id in args.no_opportunity:
        pid = raw_id.strip()
        target = by_id.get(pid)
        if target is None:
            return cannot_run(
                "--no-opportunity names %r, which is not a producer in %s. An "
                "excuse aimed at a name nobody declares excuses nothing, and a "
                "mistyped id would leave a real absence reading as a break. "
                "Declared ids: %s" % (pid, args.roster,
                                      ", ".join(sorted(by_id)))
            )
        if not target.required:
            return cannot_run(
                "--no-opportunity names %r, which the roster carries as "
                "%r rather than `required`. A producer that is never failed on "
                "cannot be excused from failing; naming it here means the "
                "caller and the roster disagree about what is being measured."
                % (pid, target.status)
            )
        if pid not in no_opportunity:
            no_opportunity.append(pid)
    if no_opportunity:
        print("NO-OPPORTUNITY declared by the caller: %s"
              % ", ".join(no_opportunity))
        print("  (their absence is CANNOT-RUN, never PASS; every other "
              "producer still FAILs on absence)")

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
    # Counted for the ATTRIBUTION diagnosis below (#1163), not for the verdict.
    purpose_counts = {}
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
        purpose_counts[purpose] = purpose_counts.get(purpose, 0) + 1
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
    # THREE STATES FOR A ZERO, NOT TWO (#1634). `broke` had an opportunity, or
    # nobody said otherwise -- that is still a FAIL. `unasked` was measured by
    # the caller to have had none.
    broke = [p for p in missing if p.producer_id not in no_opportunity]
    unasked = [p for p in missing if p.producer_id in no_opportunity]
    # An excuse for a producer that DID write is not a fault, but it is a sign
    # the caller's opportunity signal and the journal disagree, and a reader
    # comparing two runs should see it rather than infer it.
    excused_but_present = [p.producer_id for p in required
                           if p.producer_id in no_opportunity and p.hits > 0]
    if excused_but_present:
        print("  NOTE: %s wrote a record despite being declared "
              "--no-opportunity. The" % ", ".join(excused_but_present))
        print("  caller's opportunity signal and the journal disagree; the "
              "journal wins here,")
        print("  and the signal is worth re-reading before it is trusted to "
              "excuse anything.")
        print()

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

    def _detail(producers_):
        for p in producers_:
            print("  MISSING  %s" % p.producer_id)
            print("           matched by %s=%r, purpose %s"
                  % (p.match_kind, p.match_value, p.purpose))
            print("           %s" % p.provenance)
            _attribution_note(p)

    def _attribution_note(p):
        """#1163: 'wrote nothing' and 'wrote without attributing' differ.

        A purpose-matched producer is invisible to this gate when the writer
        recorded the call but did not declare what it was for: the record lands
        in the journal's `unattributed` bucket, the panel's total is right and
        its breakdown is short, and this gate says the producer 'wrote
        nothing'. That is a DIFFERENT defect with a DIFFERENT owner, and the
        verdict must not assert the wrong one.

        MEASURED against the writer rather than assumed, because a fixture that
        carries a field the box never emits proves nothing (ostler-assistant
        crates/zeroclaw-config/src/cost/types.rs): `TokenUsage.purpose` carries
        `#[serde(default)]` and NO `skip_serializing_if`, so the key is always
        serialised; `Purpose::Unattributed` is the `#[default]`, and
        agent/loop_.rs sets it for every non-interactive run. So an
        `unattributed` record is a shape the shipped daemon really does write,
        and a record with the key absent is one written before the field
        existed.
        """
        if p.match_kind != "purpose" or p.match_value == "unattributed":
            return
        unattributed = purpose_counts.get("unattributed", 0)
        if unattributed <= 0:
            return
        print("           ⚠️ THE JOURNAL CARRIES %d `unattributed` RECORD(S). "
              "A writer that" % unattributed)
        print("           recorded the call without declaring what it was for "
              "lands there, and is")
        print("           invisible to a purpose-matched row. 'Wrote nothing' "
              "and 'wrote without")
        print("           attributing' are two findings with two owners -- "
              "read the unattributed")
        print("           bucket before concluding this producer is silent.")

    if broke:
        names = ", ".join("%s (%s, %s)" % (p.producer_id, p.repo, p.purpose)
                          for p in broke)
        # The wording of this line is load-bearing for readers, not for
        # programs. It USED TO BE parsed by
        # scripts/box_walk_probes/probes/usage_journal_producers.sh, which
        # matched the prefix, the phrase and one producer name to turn a single
        # case into a refusal. That pattern-match is gone: opportunity is now
        # declared with --no-opportunity, which is a contract instead of a
        # coincidence of phrasing.
        print("VERDICT: FAIL -- %d of %d REQUIRED producers wrote nothing into "
              "%d parsed record(s): %s."
              % (len(broke), len(required), parsed, names))
        print()
        _detail(broke)
        if unasked:
            print()
            print("  ALSO UNMEASURED, and NOT part of the failure above: %s."
                  % ", ".join(p.producer_id for p in unasked))
            print("  The caller declared these had no opportunity on this box. "
                  "They are coverage")
            print("  lost, not defects -- and the FAIL above stands on its own "
                  "producers, so a")
            print("  dead producer can never hide inside somebody else's "
                  "excuse.")
        print()
        print("  A producer that stops writing is invisible in the panel: the "
              "number just gets smaller,")
        print("  which looks like a quiet month. That is why absence here is a "
              "RED and not a note.")
        return EX_FAIL

    if unasked:
        # EVERY missing producer was measured to have had no opportunity. There
        # is no red to report and there is no clean bill to give either.
        print("EXAMINED: %d of %d required producers had no opportunity on "
              "this box" % (len(unasked), len(required)))
        _detail(unasked)
        print()
        return cannot_run(
            "%d of %d REQUIRED producers wrote nothing, and the caller "
            "measured that every one of them had NO OPPORTUNITY to write on "
            "this box: %s. Nothing about them was measured, so this is "
            "coverage lost -- not a pass, and not the accusation that they "
            "broke. Every other required producer wrote."
            % (len(unasked), len(required),
               ", ".join(p.producer_id for p in unasked))
        )

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
