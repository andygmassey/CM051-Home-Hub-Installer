#!/usr/bin/env python3
"""The export watcher's high-water store and the Doctor reader agree.

WRITER: the REAL install.sh functions (_es_mark_get, _es_mark_raise and their
helpers, extracted from install.sh and run under bash with a scratch
_ES_STATE). Nothing is re-implemented here.

READER: vendor/doctor/agent/export_status.py read_high_water, the function the
Doctor snapshot calls.

Proves, end to end through both real sides:
  1. a LinkedIn and a Facebook import written by the watcher read back with the
     right epoch and date source;
  2. the mark only moves UP: a later raise to an older date is refused;
  3. a never-imported platform is absent, and reads as "Never imported";
  4. a corrupt store reads as "unreadable", never as "no imports";
  5. a failing read (store is a directory) is "unreadable", not "absent".
Controls: check 1 is the positive control (the reader must see the writer's
rows); check 2 is the mutant control (a writer that lowered the mark would be
caught by it).

Synthetic only. Run bare: python3 tests/test_export_status_contract.py
Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""

import datetime as dt
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INSTALL = REPO / "install.sh"
AGENT = REPO / "vendor" / "doctor" / "agent"
sys.path.insert(0, str(AGENT))

try:
    import export_status as es  # noqa: E402
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT-RUN: export_status did not import: {exc}", file=sys.stderr)
    sys.exit(2)

FAILS = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def epoch(y, m, d):
    return int(dt.datetime(y, m, d, tzinfo=dt.timezone.utc).timestamp())


def extract_writer() -> str:
    """The watcher's high-water block, verbatim from install.sh."""
    lines = INSTALL.read_text(encoding="utf-8").splitlines()
    start = next((i for i, l in enumerate(lines) if l.startswith("_ES_MARK=")), None)
    end = next((i for i, l in enumerate(lines) if l.startswith("if [[ ${#FOUND[@]} -gt 0 ]]; then")), None)
    if start is None or end is None or end <= start:
        raise RuntimeError("could not find the high-water block in install.sh")
    return "\n".join(lines[start:end])


def run_writer(state_dir: str, calls: list[str]) -> None:
    script = f'_ES_STATE="{state_dir}"\n' + extract_writer() + "\n" + "\n".join(calls) + "\n"
    r = subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"writer failed rc={r.returncode}: {r.stderr.strip()[:300]}")


def main() -> int:
    if shutil.which("/bin/bash") is None:
        print("CANNOT-RUN: no /bin/bash", file=sys.stderr)
        return 2
    base = tempfile.mkdtemp(prefix="export-contract.")
    try:
        state = os.path.join(base, "export-scan")
        os.makedirs(state)
        store = Path(state) / "high_water.tsv"

        li = epoch(2026, 10, 2)
        fb = epoch(2026, 9, 1)
        run_writer(state, [
            f"_es_mark_raise LinkedIn {li} name",
            f"_es_mark_raise Facebook {fb} mtime",
        ])
        r = es.read_high_water(store)
        print("1. positive control: watcher rows read back")
        check(r["status"] == "ok", f"status is ok (got {r['status']})")
        check(r["marks"].get("LinkedIn") == (li, "name"), "LinkedIn reads back epoch and name source")
        check(r["marks"].get("Facebook") == (fb, "mtime"), "Facebook reads back epoch and mtime source")
        check("Discord" not in r["marks"], "a never-imported platform has no row")

        print("2. mutant control: the mark only moves up")
        run_writer(state, [f"_es_mark_raise LinkedIn {epoch(2026, 1, 5)} mtime"])
        r = es.read_high_water(store)
        check(r["marks"].get("LinkedIn") == (li, "name"),
              "an older raise is refused: LinkedIn still at 2 Oct 2026")

        print("3. a never-imported platform renders as Never imported, with its link")
        html = es.render_export_section(r)
        check("Never imported" in html, "Never imported appears for the platforms with no row")
        check('href="https://support.discord.com/' in html, "the never-imported row carries its request link")

        print("4. a corrupt store is unreadable, never 'no imports'")
        bad = Path(base) / "bad.tsv"
        bad.write_text("LinkedIn\tnot-a-number\tname\n", encoding="utf-8")
        r = es.read_high_water(bad)
        check(r["status"] == "unreadable", f"malformed row reads as unreadable (got {r['status']})")
        check("Never imported" not in es.render_export_section(r),
              "no row says Never imported when the store is unreadable")

        print("5. a store that cannot be read is unreadable, not absent")
        dirstore = Path(base) / "dirstore"
        dirstore.mkdir()
        r = es.read_high_water(dirstore)
        check(r["status"] == "unreadable", f"a directory in place of the file is unreadable (got {r['status']})")
        check(es.read_high_water(Path(base) / "missing.tsv")["status"] == "absent",
              "a missing file is absent (nothing imported yet), which is not an error")
    finally:
        shutil.rmtree(base, ignore_errors=True)

    print()
    if FAILS:
        print(f"RESULT: {len(FAILS)} FAIL")
        return 1
    print("RESULT: all checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
