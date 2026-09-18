#!/usr/bin/env python3
"""verify_register_agreement.py: two registers must not answer one question twice.

============================================================================
WHAT THIS GATE ASSERTS, AND THE DEFECT IT CLOSES
============================================================================

CM051 #1772, part 2. Two tracked registers grade the SAME box-walk probe and
they disagree, and neither one knows the other exists:

  * scripts/walk_promote_scope.tsv says which probes can REFUSE A PROMOTE.
    It is genuinely enforced: verify_walk_record.sh reads it at :53, branches
    on `advisory` at :469, makes an UNDECLARED probe blocking at :474, and
    fails closed when the file is missing at :52.

  * cut-manifests/*.yaml declare rows titled "box-walk probe must PASS",
    graded by verify_cut_manifest.py::check_box_walk_probe, where a non-PASS
    is a FAIL or a CANNOT-RUN and BOTH count toward the blocking total.

MEASURED on origin/main 923c5067, and the number is bigger than the row said:
FOUR probes are graded `advisory` by the promote register while the cut
register declares they must PASS.

    converge_kill_is_recorded
    ingest_coverage
    no_store_port_is_tcp_reachable
    usage_journal_producers

Nothing anywhere reconciles them, and nothing ever printed the pair. The grep
that proves the escape is genuinely absent from the cut gate resolves:

    advisory       in verify_cut_manifest.py   0
    promote_scope  in verify_cut_manifest.py   0
    CONTROL box_walk_probe in the same file   39
    CONTROL blocking       in the same file    3

so the zeros are a real absence and not a broken predicate.

WHICH REGISTER SHOULD WIN IS NOT THIS GATE'S QUESTION, AND NOT AN AGENT'S.
One of them has to change and choosing is a policy decision about what stops
a cut. What this gate refuses is holding the disagreement SILENTLY, and
holding it FOREVER.

============================================================================
THE RULE
============================================================================

Every box-walk probe named by the current cut register must either

  (a) be graded `blocking` by the promote register, which is agreement, or
  (b) carry an explicit, dated, owned ACKNOWLEDGEMENT on the manifest entry
      that makes the claim.

An acknowledgement looks like this, on the entry itself, because that is
where a reader meets the contradicting claim:

    - id: probe-usage-journal-producers
      title: "box-walk probe must PASS: usage_journal_producers"
      proof:
        kind: box_walk_probe
        probe: "usage_journal_producers"
      promote_scope_disagreement:
        promote_scope: advisory
        until_cut: "v1.0.100"
        decided_by: "..."
        reason: "..."

`until_cut` IS THE POINT AND IT IS NOT DECORATION. #1772's own words:
"Recording a defect must not be a way of shipping past it forever." The same
row measured that no expiry machinery exists for this register at all:
expir|until_cut|deadline over walk_promote_scope.tsv returns 0, against a
control of 720 in cut-deferrals.yaml. So an acknowledgement here DIES at the
named cut and the disagreement has to be re-argued rather than inherited.

============================================================================
THREE OUTCOMES, THREE EXIT CODES
============================================================================

    0   PASS         every probe agrees, or its disagreement is acknowledged
                     and the acknowledgement is still live
    1   FAIL         a disagreement is unacknowledged, expired, malformed, or
                     acknowledged when there is nothing to acknowledge
    2   CANNOT-RUN   a register could not be read, so nothing was compared

CANNOT-RUN IS NOT A PASS. A missing promote register means this gate has not
found the registers in agreement, it has failed to look, and the thing it
would have caught is a silent contradiction. It fails closed for the same
reason verify_walk_record.sh:52 does.

============================================================================
WHY A STALE ACKNOWLEDGEMENT IS ALSO A FAILURE
============================================================================

An acknowledgement for a pair that is no longer in disagreement is not
harmless. It is a written claim that the registers conflict, sitting next to
registers that agree, and the next reader believes the file rather than
re-measuring. It also survives the thing it was written for, which is exactly
how a temporary exception becomes permanent. So it is a FAIL, and the remedy
printed is to delete it.

USAGE

    scripts/verify_register_agreement.py
    scripts/verify_register_agreement.py --cm051-dir /path/to/CM051
    scripts/verify_register_agreement.py --self-test

Written for python3.8+, which is what every runner in this repo carries. The
only third-party import is PyYAML, which verify_cut_manifest.py already
requires to read the same files.
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover: exercised by the CANNOT-RUN arm below
    yaml = None

EX_PASS = 0
EX_FAIL = 1
EX_CANNOT_RUN = 2

#: The promote register's vocabulary. verify_walk_record.sh understands these
#: two words and nothing else.
SCOPES = ("blocking", "advisory")

#: verify_walk_record.sh:474 makes an UNDECLARED probe blocking. This gate
#: mirrors that rather than inventing its own default, because two readers of
#: one register that disagree about its default is the defect being fixed.
UNDECLARED_SCOPE = "blocking"

ACK_KEY = "promote_scope_disagreement"
ACK_REQUIRED_FIELDS = ("promote_scope", "until_cut", "decided_by", "reason")

_VERSION_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def cannot_run(msg: str) -> int:
    print()
    print("VERDICT: CANNOT-RUN: %s" % msg)
    return EX_CANNOT_RUN


def fail(msgs) -> int:
    print()
    print("VERDICT: FAIL: %d register disagreement problem(s)." % len(msgs))
    for m in msgs:
        print()
        for line in m.splitlines():
            print("  %s" % line)
    return EX_FAIL


def version_key(stem: str):
    """Integer tuple, never a string sort.

    'v1.0.99' sorts AFTER 'v1.0.100' under a text sort, which is the boundary
    tests/test_the_manifest_selector_survives_v1_0_100.sh exists for. A gate
    about registers picking the wrong register would be a poor joke.
    """
    m = _VERSION_RE.match(stem)
    if not m:
        return None
    return tuple(int(g) for g in m.groups())


def load_promote_scope(path: Path):
    """{probe: scope} from the promote register, or an exception.

    Four tab-separated columns, comments on '#', and a header row whose first
    field is literally 'probe'. Parsed the same way tests/
    test_promote_scope_only_ever_grows.sh parses it, so the two cannot
    disagree about what a row is.
    """
    scope = {}
    text = path.read_text(encoding="utf-8")
    for lineno, line in enumerate(text.splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if fields[0] == "probe":
            continue
        if len(fields) < 2:
            raise ValueError(
                "%s:%d has %d tab-separated field(s); a scope row needs at "
                "least the probe and its scope" % (path, lineno, len(fields))
            )
        probe, word = fields[0].strip(), fields[1].strip()
        if word not in SCOPES:
            raise ValueError(
                "%s:%d grades %r as %r, which is not one of %s. A word this "
                "file does not define is not a scope, and a reader that "
                "guesses at it is the defect."
                % (path, lineno, probe, word, " or ".join(SCOPES))
            )
        if probe in scope and scope[probe] != word:
            raise ValueError(
                "%s:%d grades %r as %r, having already graded it %r. One "
                "register cannot contradict itself."
                % (path, lineno, probe, word, scope[probe])
            )
        scope[probe] = word
    if not scope:
        raise ValueError(
            "%s declares no probes at all. An empty register is not a register "
            "that agrees with everything; it is one this gate cannot compare "
            "against." % path
        )
    return scope


def load_cut_register(manifest_dir: Path):
    """Every box_walk_probe row in permanent.yaml plus the CURRENT cut.

    Historical cut manifests are RECORDS OF PAST CUTS and are deliberately not
    examined: they are not editable and a contradiction inside one is a fact
    about a cut that already happened. Which files were read is printed, so
    the scope of the answer is visible rather than assumed.
    """
    permanent = manifest_dir / "permanent.yaml"
    if not permanent.is_file():
        raise FileNotFoundError(
            "%s is not present. It carries the box-walk probe rows that are "
            "not specific to one cut, so without it this gate would compare a "
            "fraction of the register and report agreement over what it never "
            "read." % permanent
        )
    versioned = []
    for p in manifest_dir.glob("v*.yaml"):
        key = version_key(p.stem)
        if key is not None:
            versioned.append((key, p))
    if not versioned:
        raise FileNotFoundError(
            "no v<major>.<minor>.<patch>.yaml in %s, so there is no current "
            "cut register to compare." % manifest_dir
        )
    versioned.sort()
    current_path = versioned[-1][1]
    current_cut = current_path.stem

    rows = []
    for path in (permanent, current_path):
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for entry in (doc.get("entries") or []):
            proof = entry.get("proof") or {}
            if proof.get("kind") != "box_walk_probe":
                continue
            rows.append({
                "file": path.name,
                "id": entry.get("id", "<no id>"),
                "probe": proof.get("probe"),
                "ack": entry.get(ACK_KEY),
            })
    return current_cut, [permanent.name, current_path.name], rows


def adjudicate(scope: dict, current_cut: str, rows: list):
    """Every problem found, as printable text. Empty means the registers agree."""
    problems = []
    current_key = version_key(current_cut)
    agreed = 0
    acknowledged = 0
    for row in rows:
        probe = row["probe"]
        where = "%s entry %s (probe=%s)" % (row["file"], row["id"], probe)
        if not probe:
            problems.append(
                "%s declares a box_walk_probe proof with no probe name.\n"
                "A row that names no probe cannot be compared against any "
                "register." % where
            )
            continue
        declared = scope.get(probe)
        effective = declared if declared is not None else UNDECLARED_SCOPE
        ack = row["ack"]

        if effective == "blocking":
            # The registers agree. An acknowledgement here is a written claim
            # that they do not.
            if ack is not None:
                problems.append(
                    "%s carries a %s acknowledgement, but the promote register "
                    "grades this probe %r.\nThere is nothing to acknowledge. A "
                    "stale acknowledgement is a written claim that two "
                    "registers conflict, sitting\nnext to registers that "
                    "agree, and it outlives the thing it was written for.\n"
                    "REMEDY: delete the %s block from that entry."
                    % (where, ACK_KEY, effective, ACK_KEY)
                )
            else:
                agreed += 1
            continue

        # effective == "advisory": the cut register says must PASS and the
        # promote register says a red here does not refuse. That is the
        # disagreement.
        if ack is None:
            problems.append(
                "%s is a REGISTER DISAGREEMENT with no acknowledgement.\n"
                "  scripts/walk_promote_scope.tsv grades it  : advisory\n"
                "  %-41s: must PASS\n"
                "The same red is non-blocking for the promote and blocking for "
                "the cut, and neither\nregister knows the other exists.\n"
                "REMEDY: either change one of the registers, which is a policy "
                "decision about what\nstops a cut, or record the "
                "disagreement on this entry with an expiry:\n"
                "    %s:\n"
                "      promote_scope: advisory\n"
                "      until_cut: \"<the cut at which this must be re-argued>\"\n"
                "      decided_by: \"<who, and where they wrote it>\"\n"
                "      reason: \"<why it is held open>\""
                % (where, row["file"] + " declares it", ACK_KEY)
            )
            continue

        if not isinstance(ack, dict):
            problems.append(
                "%s has a %s that is %s, not a mapping.\nAn acknowledgement "
                "that cannot be read is not an acknowledgement."
                % (where, ACK_KEY, type(ack).__name__)
            )
            continue
        missing = [f for f in ACK_REQUIRED_FIELDS if not str(ack.get(f, "")).strip()]
        if missing:
            problems.append(
                "%s has a %s missing: %s.\nAn acknowledgement with no decider "
                "or no expiry cannot be audited, only obeyed."
                % (where, ACK_KEY, ", ".join(missing))
            )
            continue
        if str(ack["promote_scope"]).strip() != effective:
            problems.append(
                "%s acknowledges promote_scope=%r while the promote register "
                "grades it %r.\nThe acknowledgement describes a disagreement "
                "that is not the one on disk."
                % (where, ack["promote_scope"], effective)
            )
            continue
        until = str(ack["until_cut"]).strip()
        until_key = version_key(until)
        if until_key is None:
            problems.append(
                "%s has until_cut=%r, which is not a v<major>.<minor>.<patch> "
                "version.\nWITHOUT A CUT VERSION, NOTHING CAN EXPIRE, AND THAT "
                "IS NOT THE SAME AS NOTHING HAVING EXPIRED."
                % (where, until)
            )
            continue
        if current_key is not None and current_key >= until_key:
            problems.append(
                "%s has an EXPIRED acknowledgement: until_cut=%s, current cut "
                "register=%s.\nIt was recorded to be re-argued at that cut, and "
                "that cut is here. It must be\nre-decided rather than "
                "inherited.\ndecided_by: %s\nreason: %s"
                % (where, until, current_cut, ack["decided_by"], ack["reason"])
            )
            continue
        acknowledged += 1
    return problems, agreed, acknowledged


def run(cm051_dir: Path) -> int:
    print("verify_register_agreement")
    if yaml is None:
        return cannot_run(
            "PyYAML is not importable, so the cut register could not be read. "
            "Nothing was compared; that is coverage lost, not agreement."
        )
    scope_path = cm051_dir / "scripts" / "walk_promote_scope.tsv"
    manifest_dir = cm051_dir / "cut-manifests"
    print("promote register : %s" % scope_path)
    print("cut register dir : %s" % manifest_dir)

    try:
        scope = load_promote_scope(scope_path)
    except (OSError, ValueError) as exc:
        return cannot_run(
            "the promote register could not be read: %s. verify_walk_record.sh "
            "fails closed on exactly this, and so does this gate: an "
            "unreadable register has not been found to agree with anything."
            % exc
        )
    try:
        current_cut, files, rows = load_cut_register(manifest_dir)
    except (OSError, ValueError) as exc:
        return cannot_run("the cut register could not be read: %s" % exc)

    blocking = sum(1 for v in scope.values() if v == "blocking")
    advisory = sum(1 for v in scope.values() if v == "advisory")
    print("EXAMINED: %d probe(s) in the promote register, %d blocking, %d advisory"
          % (len(scope), blocking, advisory))
    print("EXAMINED: %d box_walk_probe row(s) across %s (current cut %s)"
          % (len(rows), " + ".join(files), current_cut))
    print("          historical cut manifests are records of past cuts and are "
          "NOT examined")
    print()

    problems, agreed, acknowledged = adjudicate(scope, current_cut, rows)
    print("PROBE                              PROMOTE    CUT REGISTER   ACK")
    for row in sorted(rows, key=lambda r: (r["probe"] or "", r["file"])):
        probe = row["probe"] or "<unnamed>"
        declared = scope.get(probe)
        effective = declared if declared is not None else UNDECLARED_SCOPE
        shown = effective if declared is not None else effective + "*"
        ack = row["ack"]
        ack_s = "none"
        if isinstance(ack, dict):
            ack_s = "until %s" % ack.get("until_cut", "?")
        elif ack is not None:
            ack_s = "MALFORMED"
        print("%-34s %-10s %-14s %s" % (probe[:34], shown, "must PASS", ack_s))
    if any(scope.get(r["probe"]) is None for r in rows):
        print("  * not declared in the promote register, so BLOCKING by its "
              "fail-closed default")
    print()
    print("EXAMINED: %d row(s) agree, %d disagreement(s) acknowledged and live, "
          "%d problem(s)" % (agreed, acknowledged, len(problems)))

    if problems:
        return fail(problems)
    print()
    print("VERDICT: PASS: every box-walk probe the current cut register names "
          "is either blocking in the")
    print("promote register, or carries a live, dated, owned acknowledgement "
          "of the disagreement.")
    return EX_PASS


# ---------------------------------------------------------------------------
# NEGATIVE CONTROL. A gate that has never been watched to refuse is a gate
# nobody can trust to refuse. Every arm builds a REAL pair of registers in a
# temporary tree and drives the REAL adjudicator over them.
# ---------------------------------------------------------------------------
_SCOPE_HEADER = "# probe\tscope\towner\treason\n"


def _write_registers(root: Path, scope_rows, entries, version="v1.0.99"):
    (root / "scripts").mkdir(parents=True, exist_ok=True)
    (root / "cut-manifests").mkdir(parents=True, exist_ok=True)
    body = _SCOPE_HEADER + "".join(
        "%s\t%s\towner\treason\n" % (p, s) for p, s in scope_rows
    )
    (root / "scripts" / "walk_promote_scope.tsv").write_text(body, encoding="utf-8")
    (root / "cut-manifests" / "permanent.yaml").write_text(
        yaml.safe_dump({"entries": entries}, sort_keys=False), encoding="utf-8"
    )
    (root / "cut-manifests" / ("%s.yaml" % version)).write_text(
        yaml.safe_dump({"entries": []}, sort_keys=False), encoding="utf-8"
    )


def _entry(probe, ack=None):
    e = {"id": "probe-" + probe, "title": "box-walk probe must PASS: " + probe,
         "proof": {"kind": "box_walk_probe", "probe": probe}}
    if ack is not None:
        e[ACK_KEY] = ack
    return e


def _live_ack(until="v1.0.100"):
    return {"promote_scope": "advisory", "until_cut": until,
            "decided_by": "self-test", "reason": "self-test"}


def self_test() -> int:
    if yaml is None:
        print("SELF-TEST CANNOT-RUN: PyYAML is not importable, so no arm could "
              "build a register. Nothing was proven about this gate.")
        return EX_CANNOT_RUN
    arms = []

    def arm(name, scope_rows, entries, want, version="v1.0.99"):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            _write_registers(root, scope_rows, entries, version)
            import io
            import contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = run(root)
        arms.append((name, want, rc, buf.getvalue()))

    # ARM 1, the POSITIVE CONTROL. Without it every arm below is satisfied by
    # a gate that refuses unconditionally.
    arm("a blocking probe with no ack PASSes",
        [("p_block", "blocking")], [_entry("p_block")], EX_PASS)

    # ARM 2: the defect this gate exists for.
    arm("an advisory probe the cut register requires, unacknowledged, FAILs",
        [("p_adv", "advisory")], [_entry("p_adv")], EX_FAIL)

    # ARM 3: the acknowledgement works, so arm 2 measures the absence of one
    # rather than the word `advisory`.
    arm("the same pair WITH a live ack PASSes",
        [("p_adv", "advisory")], [_entry("p_adv", _live_ack())], EX_PASS)

    # ARM 4: the expiry is real. Same ack, named at the CURRENT cut.
    arm("an ack that expires at the current cut FAILs",
        [("p_adv", "advisory")], [_entry("p_adv", _live_ack("v1.0.99"))], EX_FAIL)

    # ARM 5: version comparison is numeric. v1.0.100 is AFTER v1.0.99, and a
    # text sort says the opposite, which is the boundary that has already bitten
    # the manifest selector in this repo.
    arm("an ack until v1.0.100 is EXPIRED once the cut register is v1.0.100",
        [("p_adv", "advisory")], [_entry("p_adv", _live_ack("v1.0.100"))],
        EX_FAIL, version="v1.0.100")

    # ARM 6: an expiry with no version cannot expire, and that is not the same
    # as nothing having expired.
    arm("an ack with a non-version until_cut FAILs",
        [("p_adv", "advisory")], [_entry("p_adv", _live_ack("post-launch"))],
        EX_FAIL)

    # ARM 7: an incomplete ack cannot be audited.
    arm("an ack with no decider FAILs",
        [("p_adv", "advisory")],
        [_entry("p_adv", {"promote_scope": "advisory", "until_cut": "v1.0.100",
                          "decided_by": "", "reason": "r"})], EX_FAIL)

    # ARM 8: a stale ack on a pair that AGREES is a failure, not a shrug.
    arm("an ack on a BLOCKING probe FAILs as stale",
        [("p_block", "blocking")], [_entry("p_block", _live_ack())], EX_FAIL)

    # ARM 9: fail-closed on an undeclared probe, mirroring
    # verify_walk_record.sh:474. It must AGREE, not be excused.
    arm("a probe absent from the promote register is BLOCKING, and agrees",
        [("p_other", "blocking")], [_entry("p_undeclared")], EX_PASS)

    # ARM 10: and an ack on that undeclared probe is stale, so the fail-closed
    # default cannot be used to smuggle an exception in.
    arm("an ack on an UNDECLARED probe FAILs as stale",
        [("p_other", "blocking")], [_entry("p_undeclared", _live_ack())],
        EX_FAIL)

    # ARM 11: a scope word the register does not define is CANNOT-RUN, never a
    # quiet pass and never an invented reading.
    arm("an unknown scope word is CANNOT-RUN",
        [("p_adv", "sort-of")], [_entry("p_adv")], EX_CANNOT_RUN)

    # ARM 12: a dead pair cannot hide behind a live one. Two disagreements,
    # one acknowledged, one not, must still FAIL naming the unacknowledged one.
    arm("one acknowledged disagreement does not excuse another",
        [("p_adv", "advisory"), ("p_adv2", "advisory")],
        [_entry("p_adv", _live_ack()), _entry("p_adv2")], EX_FAIL)

    # ARM 13: an unreadable promote register is CANNOT-RUN, not agreement.
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _write_registers(root, [("p_block", "blocking")], [_entry("p_block")])
        (root / "scripts" / "walk_promote_scope.tsv").unlink()
        import io
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = run(root)
        arms.append(("a MISSING promote register is CANNOT-RUN", EX_CANNOT_RUN,
                     rc, buf.getvalue()))

    # ARM 14: an EMPTY promote register is CANNOT-RUN too. A file that declares
    # nothing would otherwise make every probe blocking-by-default and read as
    # perfect agreement over a register nobody wrote.
    arm("an EMPTY promote register is CANNOT-RUN, not universal agreement",
        [], [_entry("p_block")], EX_CANNOT_RUN)

    bad = [(n, w, g) for n, w, g, _ in arms if w != g]
    print("EXAMINED: %d self-test arm(s), %d behaved as required, %d did not"
          % (len(arms), len(arms) - len(bad), len(bad)))
    for name, want, got, _ in arms:
        print("  %-4s %-62s want rc=%d got rc=%d"
              % ("ok" if want == got else "BAD", name, want, got))
    if bad:
        print()
        print("VERDICT: SELF-TEST BROKEN: %d arm(s) did not behave as required, "
              "so this gate has not demonstrated it can refuse and its real "
              "verdict must not be trusted." % len(bad))
        for name, want, got, out in arms:
            if want != got:
                print()
                print("--- %s ---" % name)
                print(out)
        return EX_FAIL
    print()
    print("VERDICT: SELF-TEST PASS: the gate refuses an unacknowledged "
          "disagreement, an expired one, a")
    print("malformed one and a stale one; it fails closed on an unreadable or "
          "empty register; and it")
    print("still PASSes registers that agree, so the refusals above are not a "
          "stuck needle.")
    return EX_PASS


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(add_help=True,
                                 description=__doc__.splitlines()[0])
    ap.add_argument("--cm051-dir", default=None,
                    help="repo root; default is this script's parent's parent")
    ap.add_argument("--self-test", action="store_true",
                    help="drive every refusal against synthetic registers and "
                         "prove each one fires")
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    root = (Path(args.cm051_dir).expanduser().resolve() if args.cm051_dir
            else Path(__file__).resolve().parents[1])
    return run(root)


if __name__ == "__main__":
    sys.exit(main())
