#!/usr/bin/env python3
"""ledger_newest_daemon.py -- resolve dmg_cuts[newest].contains_daemon HONESTLY.

WHY THIS FILE EXISTS (the defect it replaces)
---------------------------------------------
verify_branch_truth.sh used to resolve "the daemon the last cut shipped" with:

    awk '/^dmg_cuts:/ {inseg=1; next}
         inseg && /^[A-Za-z_]/ {inseg=0}
         inseg && $1=="contains_daemon:" {print $2; exit}'

That takes the FIRST contains_daemon in FILE ORDER and labels it
`dmg_cuts[newest]`. File order is not recency in SHIPPING_LEDGER.yaml and never
was. Measured 2026-08-19 against the live ledger (8433 lines, 19 dmg_cuts rows):

    first contains_daemon in file order  -> row v1.0.18  -> hub-v0.4.54
    newest row that actually shipped     -> row v1.0.35  -> hub-v0.4.58

Four daemon releases apart. The gate compared each candidate pin against a
baseline four releases stale and reported GREEN, which is exactly the shape of
the v1.0.12 regression it was written to stop. The first nine rows are written
newest-first; every row after that is APPENDED (the ledger header mandates
"append an entry HERE in the SAME TURN"), so neither direction of file order
holds across the whole list.

THE ORDERING THIS USES (measured, not assumed)
----------------------------------------------
The ledger records recency in per-row date fields, but not consistently:
`published_date`, `tagged_at`, `tag_pushed`, `walked_at`, and several rows carry
a `<PENDING ...>` placeholder instead of a date. Ten of nineteen rows carried a
parseable timestamp when this was written, so timestamps alone cannot order the
list either.

So version order is used -- but only after it is PROVEN against this specific
file, every run:

    CONTROL: for every PAIR of rows that both carry a parseable timestamp AND a
    parseable version, check that version order and timestamp order agree.
    Zero inversions -> version order reproduces the recorded chronology exactly,
    and is used to place the undated rows too.
    One or more inversions -> version order is NOT a proven ordering here. Rows
    without a timestamp become UNPLACEABLE and the resolver exits CANNOT-RUN.

That control is the difference between "semver ordering is assumed" and "semver
ordering was measured against N dated rows in this exact file and reproduced
them". It also decays safely: the day someone writes a row out of version order
with a date on it, the control finds the inversion and the gate stops rather
than quietly picking a wrong baseline.

WHAT COUNTS AS "THE LAST SHIP"
------------------------------
A row is a candidate only if BOTH hold:
  * it names a daemon tag -- `contains_daemon:` or `daemon:` (both spellings are
    in the live file), first hub-v*/v* token of the value;
  * it evidences an artefact -- `dmg_sha256` is a 64-char hex digest.
A BURNT cut shipped nothing, so its daemon is not a baseline. v1.0.27, v1.0.28,
v1.0.29 and v1.0.34 are burnt rows in the live ledger; v1.0.29 names
hub-v0.4.57 and no DMG of it has ever existed.

DENOMINATORS
------------
Every count is printed. A zero denominator is never a pass: zero candidate rows
exits 3 (CANNOT-RUN), never 0.

READ-ONLY. This never writes YAML. `yaml.safe_dump` would destroy every comment
in SHIPPING_LEDGER.yaml, and the comments are half the register.

EXIT CODES
  0  resolved   -- the tag is on stdout, the report is on stderr
  1  the ledger is unreadable or has no dmg_cuts list
  3  CANNOT-RUN -- PyYAML missing, zero candidate rows, or rows that cannot be
     placed in any proven order. Distinct, still non-zero, never a false safe.

British English; " -- " not em-dashes.
"""

import argparse
import datetime as _dt
import os
import re
import sys

RC_OK = 0
RC_BAD_LEDGER = 1
RC_CANNOT_RUN = 3

# Date fields seen in dmg_cuts rows, in the order they are trusted. Measured
# from the live ledger 2026-08-19; extend deliberately, never speculatively.
RECENCY_FIELDS = ("published_date", "tagged_at", "tag_pushed", "walked_at")

# Both spellings appear in live rows. v1.0.33 uses `daemon:`, v1.0.35 uses
# `contains_daemon:`, and they mean the same thing.
DAEMON_FIELDS = ("contains_daemon", "daemon")

HEX64 = re.compile(r"^[0-9a-f]{64}$")
TAG_TOKEN = re.compile(r"^(hub-v[0-9][0-9A-Za-z.\-]*|v[0-9][0-9A-Za-z.\-]*)$")
VERSION_NUMS = re.compile(r"^v?([0-9]+(?:\.[0-9]+)*)(.*)$")


def emit(msg=""):
    """Human report -> stderr, so stdout stays a single machine-readable tag."""
    sys.stderr.write(msg + "\n")


def parse_ts(value):
    """Return an aware UTC datetime, or None if the value is not a date.

    Rejects the ledger's `<PENDING -- ...>` / `<NOT REACHED ...>` placeholders
    by simply failing to parse them. A placeholder is not a date and must never
    be silently ordered as one.
    """
    if value is None:
        return None
    if isinstance(value, _dt.datetime):
        dt = value
    elif isinstance(value, _dt.date):
        dt = _dt.datetime(value.year, value.month, value.day)
    elif isinstance(value, str):
        text = value.strip()
        if not text or text.startswith("<"):
            return None
        text = text.replace("Z", "+00:00")
        dt = None
        for candidate in (text, text.replace(" ", "T", 1)):
            try:
                dt = _dt.datetime.fromisoformat(candidate)
                break
            except ValueError:
                continue
        if dt is None:
            try:
                dt = _dt.datetime.strptime(text[:10], "%Y-%m-%d")
            except ValueError:
                return None
    else:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=_dt.timezone.utc)
    return dt.astimezone(_dt.timezone.utc)


def row_ts(row):
    """(datetime, field_name) for the first parseable recency field, or (None, None)."""
    for field in RECENCY_FIELDS:
        if field in row:
            parsed = parse_ts(row.get(field))
            if parsed is not None:
                return parsed, field
    return None, None


def version_key(value):
    """Sortable key for a ledger version string, or None if it is not one.

    'v1.0.13' -> (1, 0, 13); 'v1.0.13.1' -> (1, 0, 13, 1); so v1.0.13 sorts
    below v1.0.13.1, which is what the ledger means. A trailing suffix such as
    '-recut3' is kept as a tie-breaker string rather than discarded.
    """
    if not isinstance(value, str):
        return None
    match = VERSION_NUMS.match(value.strip())
    if not match:
        return None
    nums = tuple(int(part) for part in match.group(1).split("."))
    return (nums, match.group(2))


def row_daemon(row):
    """(tag, field_name) for the daemon this row names, or (None, None).

    Values are not always bare tags. v1.0.29 records
    'hub-v0.4.57, tarball f311519a...' and v1.0.33 records
    'hub-v0.4.58 5b7efb00a541 signed+notarised+stapled'. Take the first token
    that looks like a tag and nothing else.
    """
    for field in DAEMON_FIELDS:
        raw = row.get(field)
        if not isinstance(raw, str):
            continue
        first = raw.strip().split()[0].rstrip(",") if raw.strip() else ""
        if TAG_TOKEN.match(first):
            return first, field
    return None, None


def has_artefact(row):
    """True when the row evidences a real DMG (64-hex dmg_sha256)."""
    sha = row.get("dmg_sha256")
    return isinstance(sha, str) and bool(HEX64.match(sha.strip().lower()))


def find_line_numbers(path):
    """version -> {'version': lineno, <daemon field>: lineno} inside dmg_cuts.

    Best-effort only: it exists so the failure message can name the LINE it
    read, not just the file. Never load-bearing -- a miss prints '?'.
    """
    out = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except OSError:
        return out
    inseg = False
    current = None
    for idx, line in enumerate(lines, start=1):
        if re.match(r"^dmg_cuts:\s*$", line):
            inseg = True
            continue
        if inseg and re.match(r"^[A-Za-z_]", line):
            break
        if not inseg:
            continue
        stripped = line.strip()
        vmatch = re.match(r"^-\s+version:\s*(\S+)", stripped)
        if vmatch:
            current = vmatch.group(1)
            out.setdefault(current, {})["version"] = idx
            continue
        if current is None:
            continue
        for field in DAEMON_FIELDS:
            if stripped.startswith(field + ":"):
                out.setdefault(current, {}).setdefault(field, idx)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("ledger", help="path to SHIPPING_LEDGER.yaml")
    ap.add_argument(
        "--quiet",
        action="store_true",
        help="suppress the per-row table (the summary counts still print)",
    )
    args = ap.parse_args(argv)

    try:
        import yaml  # noqa: PLC0415 -- deliberate: absence must be CANNOT-RUN
    except ImportError as exc:
        emit("  CANNOT-RUN  PyYAML is not importable for %s (%s)" % (sys.executable, exc))
        emit("        the ledger is YAML and the old awk parser was the defect -- there is no")
        emit("        safe text fallback. Install PyYAML on the cut host, or point")
        emit("        BRANCH_TRUTH_PYTHON at an interpreter that has it, and re-run.")
        return RC_CANNOT_RUN

    path = args.ledger
    if not os.path.isfile(path):
        emit("  FAIL  ledger not a readable file: %s" % path)
        return RC_BAD_LEDGER
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            doc = yaml.safe_load(handle)
    except Exception as exc:  # noqa: BLE001 -- any parse failure is fail-closed
        emit("  FAIL  %s does not parse as YAML: %s" % (path, exc))
        return RC_BAD_LEDGER

    if not isinstance(doc, dict) or not isinstance(doc.get("dmg_cuts"), list):
        emit("  FAIL  %s has no top-level `dmg_cuts:` list" % path)
        emit("        read: top-level keys = %s"
             % (sorted(doc.keys()) if isinstance(doc, dict) else type(doc).__name__))
        return RC_BAD_LEDGER

    rows = [r for r in doc["dmg_cuts"] if isinstance(r, dict)]
    total_rows = len(doc["dmg_cuts"])
    linenos = find_line_numbers(path)

    facts = []
    for idx, row in enumerate(rows):
        version = row.get("version")
        tag, tag_field = row_daemon(row)
        ts, ts_field = row_ts(row)
        facts.append(
            {
                "idx": idx,
                "version": version if isinstance(version, str) else None,
                "vkey": version_key(version),
                "tag": tag,
                "tag_field": tag_field,
                "ts": ts,
                "ts_field": ts_field,
                "artefact": has_artefact(row),
            }
        )

    n_daemon = sum(1 for f in facts if f["tag"])
    n_artefact = sum(1 for f in facts if f["artefact"])
    n_dated = sum(1 for f in facts if f["ts"])
    n_versioned = sum(1 for f in facts if f["vkey"])
    candidates = [f for f in facts if f["tag"] and f["artefact"]]

    emit("        ledger file:        %s" % path)
    emit("        dmg_cuts rows read: %d (%d parsed as mappings)" % (total_rows, len(rows)))
    emit("        rows naming a daemon tag:      %d" % n_daemon)
    emit("        rows evidencing a DMG sha256:  %d" % n_artefact)
    emit("        rows that are BOTH (candidates): %d" % len(candidates))
    emit("        rows with a parseable date:    %d  (fields tried: %s)"
         % (n_dated, ", ".join(RECENCY_FIELDS)))
    emit("        rows with a parseable version: %d" % n_versioned)

    # ---- ORDERING CONTROL -------------------------------------------------
    # Prove version order reproduces the recorded chronology BEFORE using it.
    comparable = [f for f in facts if f["ts"] and f["vkey"]]
    inversions = []
    pairs = 0
    for i in range(len(comparable)):
        for j in range(i + 1, len(comparable)):
            a, b = comparable[i], comparable[j]
            if a["ts"] == b["ts"] or a["vkey"] == b["vkey"]:
                continue
            pairs += 1
            v_first = a["vkey"] < b["vkey"]
            t_first = a["ts"] < b["ts"]
            if v_first != t_first:
                inversions.append((a["version"], b["version"]))
    version_order_proven = pairs > 0 and not inversions
    emit("        ordering control:   %d dated+versioned rows, %d comparable pairs, "
         "%d inversions -> version order %s"
         % (len(comparable), pairs, len(inversions),
            "PROVEN against the recorded dates" if version_order_proven else "NOT PROVEN"))
    for a, b in inversions[:5]:
        emit("            inversion: %s vs %s (version order and date order disagree)" % (a, b))

    # Exclusion is never silent. Dropping a row makes the baseline OLDER, which
    # is the same direction as the original defect, so every drop is named.
    excluded = [f for f in facts if f["tag"] and not f["artefact"]]
    if excluded:
        emit("        %d row(s) name a daemon but evidence NO DMG -- excluded as never-shipped:"
             % len(excluded))
        for f in excluded:
            emit("            %-16s %-14s (dmg_sha256 absent or not a 64-hex digest)"
                 % (f["version"], f["tag"]))
    no_daemon = [f for f in facts if not f["tag"]]
    if no_daemon:
        emit("        %d row(s) record NO daemon tag at all: %s"
             % (len(no_daemon), ", ".join(str(f["version"]) for f in no_daemon)))

    if not candidates:
        emit("  CANNOT-RUN  0 candidate rows in %s" % path)
        emit("        a row is a candidate only if it names a daemon tag "
             "(contains_daemon:/daemon:) AND carries a 64-hex dmg_sha256.")
        emit("        %d of %d rows named a daemon; %d of %d evidenced a DMG; %d were both."
             % (n_daemon, len(rows), n_artefact, len(rows), 0))
        emit("        zero examined is not zero problems -- refusing to report a baseline.")
        return RC_CANNOT_RUN

    # ---- PLACE THE CANDIDATES --------------------------------------------
    if version_order_proven:
        unplaceable = [f for f in candidates if not f["vkey"]]
        basis = "version order (proven against %d dated rows, 0 inversions)" % len(comparable)
    else:
        unplaceable = [f for f in candidates if not f["ts"]]
        basis = "recorded timestamp only (version order unproven in this file)"

    if unplaceable:
        emit("  CANNOT-RUN  %d candidate row(s) cannot be placed in any proven order in %s"
             % (len(unplaceable), path))
        for f in unplaceable:
            emit("            row version=%s daemon=%s  (no usable %s)"
                 % (f["version"], f["tag"],
                    "version string" if version_order_proven else "date field"))
        emit("        ordering basis attempted: %s" % basis)
        emit("        refusing to guess which cut is newest -- that guess is the original defect.")
        return RC_CANNOT_RUN

    if version_order_proven:
        candidates.sort(key=lambda f: (f["vkey"], f["ts"] or _dt.datetime.min.replace(
            tzinfo=_dt.timezone.utc)))
        all_placed = sorted(
            [f for f in facts if f["vkey"]],
            key=lambda f: f["vkey"],
        )
    else:
        candidates.sort(key=lambda f: f["ts"])
        all_placed = sorted([f for f in facts if f["ts"]], key=lambda f: f["ts"])

    newest = candidates[-1]

    if not args.quiet:
        emit("        --- candidate rows, oldest to newest by %s ---" % basis)
        for f in candidates:
            marker = "  <== NEWEST" if f is newest else ""
            emit("            %-16s %-14s %s=%s%s"
                 % (f["version"], f["tag"], f["ts_field"] or "no-date",
                    f["ts"].isoformat() if f["ts"] else "-", marker))

    # If the newest row in the whole list is not the chosen candidate, say why.
    if all_placed and all_placed[-1]["version"] != newest["version"]:
        skipped = all_placed[-1]
        emit("  WARN  the newest row in %s is %s, which is NOT the baseline:" % (path, skipped["version"]))
        emit("            %s: daemon tag=%s, dmg_sha256 present=%s"
             % (skipped["version"], skipped["tag"] or "ABSENT", skipped["artefact"]))
        if not skipped["tag"]:
            emit("        that row does not record the daemon it shipped, so it cannot be a")
            emit("        non-regression baseline. Add contains_daemon: to it.")
        else:
            emit("        that row records no 64-hex dmg_sha256, so on this register it shipped")
            emit("        nothing. If it DID ship, add its dmg_sha256 -- the baseline moves.")

    line_info = linenos.get(newest["version"], {})
    daemon_line = line_info.get(newest["tag_field"], "?")
    emit("        chosen baseline:    %s -> %s"
         % (newest["version"], newest["tag"]))
    emit("        read from:          %s line %s, key `%s:` of dmg_cuts row `version: %s`"
         % (path, daemon_line, newest["tag_field"], newest["version"]))

    sys.stdout.write(newest["tag"] + "\n")
    return RC_OK


if __name__ == "__main__":
    sys.exit(main())
