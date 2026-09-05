#!/usr/bin/env python3
"""The install-completeness CLASS GATE (A2, #616-family successor).

WHAT THIS IS, AND WHY IT IS NOT ANOTHER ONE-OFF.

For a month the same shape of defect kept shipping: a thing a finished install is
supposed to CONTAIN was silently absent, and nothing counted it. Each instance
was filed on its own -- an empty [[cron.jobs]] block (#619), a usage-journal
directory that is never created (#482), a kinship guard with no importer on a
write path (#617), a set of LaunchAgents whose full expected roster nobody had
ever written down. Every one was found by a human noticing, never by a gate.

The reason there was no gate is that every attempt derived the expectation FROM
install.sh -- and a check that reads the producer to decide what the producer
should have produced is green by construction: delete the line that installs a
thing and you also delete the expectation that it be installed. So this gate's
first rule is:

  THE MANIFEST IS A SEPARATE, HAND-DECLARED FILE. It is NOT generated from
  install.sh and must never be. install.sh is the PRODUCER; the manifest is the
  independent statement of what a finished install must contain. They are
  compared, never derived one from the other.

THE TWO-SIDED CHECK. A gate that only asks "is every expected thing present"
misses the new thing nobody declared. So both directions are enforced, for every
type whose present-set can be enumerated:

  MISSING     a `required` manifest row whose subject is NOT present.  -> FAIL
  UNDECLARED  a present subject that appears in NO manifest row.       -> FAIL
              (declare it as required/conditional, or mark it excluded.)

A count is not enough and is explicitly rejected: "23 LaunchAgents present" tells
you nothing about WHICH 23, and the whole failure mode is a specific one going
missing while the count stays plausible. So every difference is NAMED.

TYPES. Minimum four, each seeded from a real measurement (see install_manifest.tsv):
  launch_agent   enumerable present-set (plists under ~/Library/LaunchAgents)
  cron_job       enumerable present-set ([[cron.jobs]] ids in the live config)
  artefact_dir   per-row presence (a declared directory exists or does not)
  import_wire    per-row presence (a write-path module imports a named guard)

SCOPE, STATED HONESTLY. The UNDECLARED (produced-but-not-declared) direction is
enforced only for the two enumerable types (launch_agent, cron_job); for
artefact_dir and import_wire the present-set is not open-endedly enumerable, so
those are checked required-present only. That is a strictly weaker claim for
those two, and it is named rather than hidden.

TARGETING. The enumerators read a target install, not this repo's assumptions:
  --home         the install's home dir     (default: $HOME) -- launch_agent, artefact_dir
  --config       the assistant config.toml  (default: resolved under --home) -- cron_job
  --source-root  the installed source tree   (default: this repo) -- import_wire
This is what makes the gate hermetically testable: point it at a synthetic home
that is missing exactly one required subject and it must NAME that subject. That
self-test is the control that must fail, and the box-walk runner enforces it.

EXIT: 0 clean | 1 a difference was found (missing or undeclared) | 2 CANNOT-RUN
(a prerequisite -- the manifest, the config, a readable home -- was absent).
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import sys

EXIT_CLEAN = 0
EXIT_DIFFERENCE = 1
EXIT_CANNOT_RUN = 2

REQUIRED, CONDITIONAL, EXCLUDED = "required", "conditional", "excluded"
VALID_EXPECT = {REQUIRED, CONDITIONAL, EXCLUDED}
# The types whose full present-set can be enumerated, so the UNDECLARED
# (produced-but-not-declared) direction is meaningful.
ENUMERABLE = {"launch_agent", "cron_job", "qdrant_collection"}


class CannotRun(Exception):
    pass


# --------------------------------------------------------------------------
# Manifest.
# --------------------------------------------------------------------------
class Row:
    __slots__ = ("type", "subject", "expectation", "locator", "ticket", "note", "lineno")

    def __init__(self, t, subject, expectation, locator, ticket, note, lineno):
        self.type = t
        self.subject = subject
        self.expectation = expectation
        self.locator = locator
        self.ticket = ticket
        self.note = note
        self.lineno = lineno


def load_manifest(path):
    if not os.path.isfile(path):
        raise CannotRun("manifest not found at %s -- the gate has nothing to check against" % path)
    rows = []
    with open(path, encoding="utf-8") as fh:
        for i, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 6:
                raise CannotRun(
                    "manifest line %d has %d tab-separated fields, expected 6 "
                    "(type, subject, expectation, locator, ticket, note). A stray "
                    "space where a tab belongs is the usual cause." % (i, len(parts))
                )
            t, subject, expectation, locator, ticket, note = (p.strip() for p in parts[:6])
            if expectation not in VALID_EXPECT:
                raise CannotRun(
                    "manifest line %d: expectation %r is not one of %s"
                    % (i, expectation, sorted(VALID_EXPECT))
                )
            rows.append(Row(t, subject, expectation, locator, ticket, note, i))
    if not rows:
        raise CannotRun("manifest %s declares zero rows -- an empty manifest passes everything" % path)
    return rows


# --------------------------------------------------------------------------
# Present-set enumerators. Each returns a set of PRESENT subject names.
# --------------------------------------------------------------------------
def present_launch_agents(home):
    d = os.path.join(home, "Library", "LaunchAgents")
    if not os.path.isdir(d):
        raise CannotRun(
            "no LaunchAgents directory at %s -- cannot enumerate installed agents "
            "(is --home pointing at a real install?)" % d
        )
    present = set()
    for p in glob.glob(os.path.join(d, "*.plist")):
        label = _plist_label(p)
        if label:
            present.add(label)
    return present


def _plist_label(path):
    """The <key>Label</key><string>NAME</string> value, else the filename stem.

    Ostler plists are named by label, so the stem is a reliable fallback, but a
    real Label key wins when present -- a file could in principle be renamed.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        m = re.search(r"<key>\s*Label\s*</key>\s*<string>\s*([^<]+?)\s*</string>", text)
        if m:
            return m.group(1).strip()
    except OSError:
        pass
    base = os.path.basename(path)
    return base[:-6] if base.endswith(".plist") else base


def present_cron_jobs(config_path):
    """The cron job ids the live config declares, READ WITH A TOML PARSER.

    🔴 THIS USED TO BE A LINE SCANNER LOOKING FOR THE LITERAL `[[cron.jobs]]`
    HEADER, AND IT REPORTED A HEALTHY INSTALL AS BROKEN. Measured on the
    v1.0.68 walk, archie@.240, 2026-09-05: the same box PASSED this check at
    08:10Z and FAILED it at 08:25Z with "2 required subject(s) MISSING:
    morning-brief, evening-wrap". Nothing had removed them. Both were present
    and enabled throughout. The daemon rewrote config.toml at 08:19:47Z and
    serialised the same two jobs as an INLINE TABLE ARRAY:

        jobs = [{ id = "morning-brief", ... }, { id = "evening-wrap", ... }]

    `[[cron.jobs]]` headers and an inline `jobs = [...]` array are two
    spellings of one TOML value. A scanner that knows only the first reads the
    second as ZERO.

    ⚠️ THE FALSE FAIL IS THE LESS DANGEROUS HALF. cron_job is an ENUMERABLE
    type with BOTH directions enforced, so a zero present-set also makes the
    "present but undeclared" arm vacuous: it reports nothing because it can
    see nothing. A ZERO DENOMINATOR READS AS SUCCESS in that direction.

    No parser -> CANNOT-RUN. The line scanner is deliberately NOT kept as a
    fallback, because its zero is indistinguishable from an empty config.
    Same discipline as present_qdrant_collections below, for the same reason.
    """
    if not config_path or not os.path.isfile(config_path):
        raise CannotRun(
            "assistant config not found at %r -- cannot read the cron jobs. "
            "A missing config is itself the #619 symptom, but it is CANNOT-RUN "
            "here, not a pass." % config_path
        )

    try:
        import tomllib as _toml          # 3.11+
    except ImportError:
        try:
            import tomli as _toml        # backport, if the environment has it
        except ImportError:
            raise CannotRun(
                "no TOML parser available under %s (python %s) -- cannot read "
                "the cron jobs. The old line-scanner is deliberately NOT used "
                "as a fallback: it cannot see an inline-table array and "
                "reported a healthy install as broken on 2026-09-05. Run this "
                "under the interpreter the install ships "
                "(~/.ostler/python/bin/python3, 3.11+), which has tomllib."
                % (sys.executable,
                   ".".join(str(n) for n in sys.version_info[:3]))
            )

    try:
        with open(config_path, "rb") as fh:
            doc = _toml.load(fh)
    except Exception as exc:                      # noqa: BLE001
        raise CannotRun(
            "could not parse %r as TOML (%s). An unparseable config is "
            "CANNOT-RUN, not an empty job list." % (config_path, exc)
        )

    jobs = (doc.get("cron") or {}).get("jobs")
    if jobs is None:
        return set()                              # a real absence: none declared
    if not isinstance(jobs, list):
        raise CannotRun(
            "cron.jobs is %s, not a list, in %r. An unexpected shape is "
            "CANNOT-RUN, not an empty job list."
            % (type(jobs).__name__, config_path)
        )

    ids = set()
    for job in jobs:
        if isinstance(job, dict) and isinstance(job.get("id"), str):
            ids.add(job["id"])
    return ids


def present_qdrant_collections(qdrant_url, conf_path):
    """The collection names Qdrant actually holds, read over its REST API.

    A store that is DOWN, unreachable, or refuses the credential is CANNOT-RUN,
    NOT "no collections" -- exactly the false zero that read the v1.0.60 index as
    empty when it was 401 (up, unauthenticated). So a non-JSON body, a missing
    result.collections list, or status != ok all raise CannotRun rather than
    returning an empty set.

    TEST SEAM: OSTLER_MANIFEST_QDRANT_OVERRIDE lets the hermetic test inject a
    present-set (comma-separated) or the sentinel `__unreachable__` without a live
    Qdrant. It is read ONLY here and named so its presence is obvious.
    """
    import json
    import subprocess

    override = os.environ.get("OSTLER_MANIFEST_QDRANT_OVERRIDE")
    if override is not None:
        if override == "__unreachable__":
            raise CannotRun("Qdrant marked unreachable by the test seam (OSTLER_MANIFEST_QDRANT_OVERRIDE)")
        return {c.strip() for c in override.split(",") if c.strip()}

    cmd = ["curl", "-s", "--noproxy", "*", "--max-time", "5"]
    if conf_path and os.path.isfile(conf_path):
        cmd += ["-K", conf_path]
    cmd += [qdrant_url.rstrip("/") + "/collections"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=8)
    except FileNotFoundError:
        raise CannotRun("curl not on PATH; cannot query Qdrant at %s" % qdrant_url)
    except Exception as e:
        raise CannotRun("could not query Qdrant at %s: %s" % (qdrant_url, e))
    body = (proc.stdout or "").strip()
    if not body:
        raise CannotRun(
            "Qdrant at %s returned no body -- unreachable or down. That is CANNOT-RUN, "
            "not 'no collections'." % qdrant_url
        )
    try:
        doc = json.loads(body)
    except ValueError:
        raise CannotRun(
            "Qdrant at %s did not return JSON -- most likely a 401/403 (up but the "
            "credential was refused). CANNOT-RUN, not absence: %s" % (qdrant_url, body[:120])
        )
    if not isinstance(doc, dict) or doc.get("status") != "ok":
        raise CannotRun("Qdrant at %s did not return status=ok (auth or error): %s" % (qdrant_url, body[:120]))
    colls = (doc.get("result") or {}).get("collections")
    if not isinstance(colls, list):
        raise CannotRun("Qdrant at %s returned no result.collections list -- unexpected shape" % qdrant_url)
    return {c.get("name") for c in colls if isinstance(c, dict) and c.get("name")}


def dir_present(home, locator):
    """artefact_dir: locator is a path, ~ and $HOME resolved against --home."""
    path = locator.replace("$HOME", home)
    if path.startswith("~/"):
        path = os.path.join(home, path[2:])
    elif path == "~":
        path = home
    elif not os.path.isabs(path):
        path = os.path.join(home, path)
    return os.path.isdir(path), path


def import_wire_present(source_root, locator):
    """import_wire: locator is `<path-glob-relative-to-source-root>|<symbol>`.

    Present iff the symbol is referenced (imported or called) in at least one
    file matching the glob. Comments are stripped first, so a module that only
    NAMES the guard in a comment does not count as wiring it.

    The lookbehind is `(?<!\\w)`, NOT `(?<![\\w.])`: a module-qualified call
    `relationship_labels.is_relationship_label(...)` is a genuine use and must
    count (the `.` before the symbol is fine), while a same-named PRIVATE copy
    `_is_relationship_label` (pwg_ingest deliberately carries its own) has a `_`
    -- a word char -- before it and is correctly NOT read as the shared guard.
    """
    if "|" not in locator:
        raise CannotRun("import_wire locator %r is not '<glob>|<symbol>'" % locator)
    rel_glob, symbol = locator.split("|", 1)
    rel_glob, symbol = rel_glob.strip(), symbol.strip()
    matches = glob.glob(os.path.join(source_root, rel_glob))
    matches = [m for m in matches if os.path.isfile(m)]
    if not matches:
        raise CannotRun(
            "import_wire glob %r matched no files under %s -- the write path moved "
            "or --source-root is wrong; refusing to score it present or absent"
            % (rel_glob, source_root)
        )
    for m in matches:
        try:
            with open(m, encoding="utf-8", errors="replace") as fh:
                code = _strip_py_comments(fh.read())
        except OSError:
            continue
        if re.search(r"(?<!\w)" + re.escape(symbol) + r"\b", code):
            return True
    return False


def _strip_py_comments(text):
    out = []
    for line in text.splitlines():
        h = line.find("#")
        out.append(line if h < 0 else line[:h])
    return "\n".join(out)


# --------------------------------------------------------------------------
# The comparison.
# --------------------------------------------------------------------------
def evaluate(rows, home, config_path, source_root, qdrant_url, qdrant_conf):
    """Return (missing, undeclared, notes, cannot_run) lists of human strings.

    CANNOT-RUN is PER TYPE, not global: a store that is down makes
    qdrant_collection unmeasurable, but the LaunchAgent and cron checks still run
    and still report. Collapsing the whole run to CANNOT-RUN because one type
    could not be read would throw away results that were readable -- the opposite
    of the four-state discipline this gate exists to keep.
    """
    missing, undeclared, notes, cannot_run = [], [], [], []

    by_type = {}
    for r in rows:
        by_type.setdefault(r.type, []).append(r)

    for t, trows in sorted(by_type.items()):
        declared = {r.subject for r in trows}
        required = {r.subject for r in trows if r.expectation == REQUIRED}
        excluded = {r.subject for r in trows if r.expectation == EXCLUDED}
        ticket_of = {r.subject: r.ticket for r in trows}

        try:
            if t in ENUMERABLE:
                if t == "launch_agent":
                    present = present_launch_agents(home)
                elif t == "cron_job":
                    present = present_cron_jobs(config_path)
                elif t == "qdrant_collection":
                    present = present_qdrant_collections(qdrant_url, qdrant_conf)
                else:  # pragma: no cover - ENUMERABLE guards this
                    present = set()
                for subj in sorted(required - present):
                    missing.append("%s %s (%s) -- required but NOT present" % (t, subj, ticket_of.get(subj, "?")))
                for subj in sorted(present - declared):
                    undeclared.append(
                        "%s %s -- PRESENT on the install but declared NOWHERE in the "
                        "manifest. Declare it required/conditional, or mark it excluded." % (t, subj)
                    )
                for subj in sorted(present & excluded):
                    notes.append("%s %s -- marked excluded but IS present (%s)" % (t, subj, ticket_of.get(subj, "?")))
            elif t == "artefact_dir":
                for r in trows:
                    if r.expectation != REQUIRED:
                        continue
                    ok, resolved = dir_present(home, r.locator)
                    if not ok:
                        missing.append("%s %s (%s) -- required directory does not exist: %s" % (t, r.subject, r.ticket, resolved))
            elif t == "import_wire":
                for r in trows:
                    if r.expectation != REQUIRED:
                        continue
                    if not import_wire_present(source_root, r.locator):
                        missing.append("%s %s (%s) -- write path does not import the guard [%s]" % (t, r.subject, r.ticket, r.locator))
            else:
                notes.append("type %r has no enumerator; %d row(s) not checked" % (t, len(trows)))
        except CannotRun as e:
            cannot_run.append("%s: %s" % (t, e))

    return missing, undeclared, notes, cannot_run


def default_config(home):
    """Best-effort resolve of the live assistant config under --home.

    ZEROCLAW_WORKSPACE wins if set (that is what the daemon reads); otherwise the
    documented default path. Returned even if absent -- the enumerator reports
    CANNOT-RUN, which is the honest state for "config not found".
    """
    ws = os.environ.get("ZEROCLAW_WORKSPACE")
    if ws:
        return os.path.join(ws, "config.toml")
    return os.path.join(home, ".ostler", "assistant-config", "config.toml")


def main(argv):
    ap = argparse.ArgumentParser(description="Install-completeness class gate: EXPECTED vs PRESENT, named.")
    ap.add_argument("--manifest", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "install_manifest.tsv"))
    ap.add_argument("--home", default=os.environ.get("HOME", ""))
    ap.add_argument("--config", default=None, help="assistant config.toml (default: resolved under --home)")
    ap.add_argument("--source-root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--only-type", default=None, help="restrict to one type (launch_agent|cron_job|artefact_dir|import_wire)")
    ap.add_argument("--exclude-type", action="append", default=[],
                    help="skip a type; repeatable. The install's closing report passes "
                         "--exclude-type import_wire, since that is a source-tree property, "
                         "not something a customer's finished install exposes.")
    ap.add_argument("--qdrant-url", default="http://127.0.0.1:6333",
                    help="Qdrant REST base for the qdrant_collection type (default: local)")
    ap.add_argument("--qdrant-conf", default=None,
                    help="curl -K config with the Qdrant credential (default: "
                         "<home>/.ostler/secrets/store-curl.conf)")
    args = ap.parse_args(argv)

    if not args.home or not os.path.isdir(args.home):
        print("CANNOT-RUN: --home %r is not a directory" % args.home, file=sys.stderr)
        return EXIT_CANNOT_RUN
    config_path = args.config or default_config(args.home)
    qdrant_conf = args.qdrant_conf or os.path.join(args.home, ".ostler", "secrets", "store-curl.conf")

    try:
        rows = load_manifest(args.manifest)
        if args.only_type:
            rows = [r for r in rows if r.type == args.only_type]
            if not rows:
                raise CannotRun("no rows of type %r in the manifest" % args.only_type)
        if args.exclude_type:
            rows = [r for r in rows if r.type not in set(args.exclude_type)]
            if not rows:
                raise CannotRun("every manifest row was excluded by --exclude-type %s" % args.exclude_type)
    except CannotRun as e:
        print("CANNOT-RUN: %s" % e, file=sys.stderr)
        return EXIT_CANNOT_RUN

    missing, undeclared, notes, cannot_run = evaluate(
        rows, args.home, config_path, args.source_root, args.qdrant_url, qdrant_conf
    )

    examined = len(rows)
    print("install-manifest gate: %d declared row(s) examined; home=%s" % (examined, args.home))
    for n in notes:
        print("  note: %s" % n)
    for c in cannot_run:
        print("  CANNOT-RUN: %s" % c)

    if missing:
        print("FAIL: %d required subject(s) MISSING:" % len(missing))
        for m in missing:
            print("    - %s" % m)
    if undeclared:
        print("FAIL: %d present subject(s) UNDECLARED:" % len(undeclared))
        for u in undeclared:
            print("    - %s" % u)
    if missing or undeclared:
        # A real difference dominates: report it even if a type was also CANNOT-RUN.
        return EXIT_DIFFERENCE
    if cannot_run:
        # Nothing failed, but at least one type could not be measured. That is a
        # coverage statement, not a pass -- a 0-of-0 must never read as clean.
        print("CANNOT-RUN: %d type(s) could not be measured; see above." % len(cannot_run))
        return EXIT_CANNOT_RUN
    print("PASS: every required subject is present and every present subject is declared.")
    return EXIT_CLEAN


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
