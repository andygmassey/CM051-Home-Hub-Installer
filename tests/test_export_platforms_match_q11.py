#!/usr/bin/env python3
"""One table, three readers: the watcher's ids, installer Q11 and the Doctor.

vendor/doctor/agent/export_platforms.tsv is the one list of export platforms.
This test fails when any of these drift apart:

  1. the table's ids are exactly the platforms the watcher detects (the SIGS
     labels in lib/ostler-detect-exports.sh), in both directions;
  2. every request_url in the table appears in installer Q11 (the "Request these
     (click to open)" block of install.sh), and Q11 has no request link for a
     watcher platform that is not in the table;
  3. every row carries a source_url, a url_status and a date_checked.

Control: check 2 is run against the table as shipped; a mutant table with one
URL changed is then checked and must be reported as drift.

Synthetic-free: all values are public platform URLs. Run bare:
python3 tests/test_export_platforms_match_q11.py
Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TABLE = REPO / "vendor" / "doctor" / "agent" / "export_platforms.tsv"
INSTALL = REPO / "install.sh"
DETECT = REPO / "lib" / "ostler-detect-exports.sh"

FAILS = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def read_table(path: Path) -> list[dict]:
    lines = [l for l in path.read_text(encoding="utf-8").splitlines() if l and not l.startswith("#")]
    header = lines[0].split("\t")
    rows = []
    for l in lines[1:]:
        cells = l.split("\t")
        if len(cells) != len(header):
            raise ValueError(f"row has {len(cells)} cells, want {len(header)}: {cells[0]!r}")
        rows.append(dict(zip(header, cells)))
    return rows


def watcher_ids(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    block = text[text.index("SIGS=("): text.index("\n)", text.index("SIGS=("))]
    return re.findall(r"\$'([A-Za-z]+)\\x1f", block)


def q11_urls(install_text: str) -> set[str]:
    start = install_text.index('echo "  Request these (click to open):"')
    end = install_text.index('echo "  When your exports arrive', start)
    return set(re.findall(r"_link '(https://[^']+)'", install_text[start:end]))


def main() -> int:
    if not (TABLE.exists() and INSTALL.exists() and DETECT.exists()):
        print("CANNOT-RUN: table, install.sh or detector missing", file=sys.stderr)
        return 2
    rows = read_table(TABLE)
    ids = [r["id"] for r in rows]
    install = INSTALL.read_text(encoding="utf-8")
    urls = q11_urls(install)

    print("1. the table is the watcher's platform list")
    detected = watcher_ids(DETECT)
    check(len(detected) == 13, f"the watcher detects 13 platforms (found {len(detected)})")
    check(sorted(ids) == sorted(detected), "table ids equal the watcher's SIGS labels, both ways")

    print("2. every table URL is in installer Q11")
    missing = [r["id"] for r in rows if r["request_url"] not in urls]
    check(not missing, f"every request_url appears in Q11 (missing: {missing})")
    extra = urls - {r["request_url"] for r in rows}
    check(extra == {"https://privacy.apple.com/"},
          f"the only Q11 link outside the table is the Apple one (extra: {sorted(extra)})")

    print("3. every row carries its provenance")
    for r in rows:
        ok = bool(r["source_url"]) and bool(r["url_status"]) and bool(r["date_checked"])
        check(ok, f"{r['id']}: source_url, url_status and date_checked are set")

    print("4. control: a changed URL is reported as drift")
    mutant = [dict(r) for r in rows]
    mutant[0]["request_url"] = mutant[0]["request_url"] + "x"
    drift = [r["id"] for r in mutant if r["request_url"] not in urls]
    check(drift == [mutant[0]["id"]], f"the mutant is caught as drift on {drift}")

    print()
    if FAILS:
        print(f"RESULT: {len(FAILS)} FAIL")
        return 1
    print("RESULT: all checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
