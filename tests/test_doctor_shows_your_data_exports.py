#!/usr/bin/env python3
"""The Doctor shows "Your data exports": last import, a request link, honest states.

CONSUMER SIDE. Drives the shipped code that a customer's Doctor page runs:
  - export_status.read_high_water on a store file (the same file the watcher writes),
  - export_status.render_export_section (the HTML section web_ui.render_dashboard emits),
  - diagnostic_rules.check_gdpr_export_age on a snapshot built by the collector's
    own field (snapshot.export_imports).

Proves:
  1. a synthetic LinkedIn export imported on a known date shows that date and its
     source, in the section;
  2. a never-imported platform (Discord here) shows "Never imported" and a
     "Request your data" link that opens in a new tab;
  3. an unreadable store shows "couldn't check" on every row, and never "Never imported";
  4. the section is separate from the always-on "Where your data came from" table;
  5. the stale-import rule fires for a LinkedIn import over 90 days old, with the
     request link in its detail, and fires "couldn't check" for an unreadable store;
  6. web_ui.py renders the section (import and placeholder both present).

Control: check 1 is the positive control; check 3 is the unreadable control. A
section that said "Never imported" for everything would fail check 1.

Synthetic only. Run bare: python3 tests/test_doctor_shows_your_data_exports.py
Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""

import html as htmllib
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

REPO = Path(__file__).resolve().parent.parent
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


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="doctor-exports."))
    try:
        platforms = es.load_platforms()
        ids = [p["id"] for p in platforms]
        check(len(platforms) == 12, f"the shared table lists 12 platforms (got {len(platforms)})")

        # A synthetic LinkedIn export, dated 2 Oct 2026 from its file name.
        li_epoch = int(datetime(2026, 10, 2, tzinfo=timezone.utc).timestamp())
        store = tmp / "high_water.tsv"
        store.write_text(f"LinkedIn\t{li_epoch}\tname\n", encoding="utf-8")
        state = es.read_high_water(store)

        print("1. a LinkedIn import shows its date and source")
        section = es.render_export_section(state, platforms)
        check("2 Oct 2026" in section, "the LinkedIn row shows 2 Oct 2026")
        check("from the export's file name" in htmllib.unescape(section),
              "and says the date came from the file name")

        print("2. a never-imported platform shows Never imported and its link in a new tab")
        check("Never imported" in section, "Never imported appears")
        discord_url = next(p["request_url"] for p in platforms if p["id"] == "Discord")
        discord_row = re.search(r"<tr><td>Discord</td>.*?</tr>", section)
        check(discord_row is not None, "a Discord row exists")
        row = discord_row.group(0) if discord_row else ""
        check("Never imported" in row, "the Discord row says Never imported")
        check(f'href="{discord_url}"' in row, "and links to the Discord request page")
        check('target="_blank"' in row and 'rel="noopener noreferrer"' in row,
              "the link opens in a new tab with noopener")
        check("Save it to Downloads and Ostler imports it automatically." in row,
              "the how-it-arrives line says where to save the export")
        check("Arrives by email when it's ready." in htmllib.unescape(row),
              "with no official wait quoted, it says Arrives by email when it's ready")

        print("3. an unreadable store shows couldn't check on every row")
        bad = tmp / "bad.tsv"
        bad.write_text("LinkedIn\tnope\tname\n", encoding="utf-8")
        bad_state = es.read_high_water(bad)
        bad_section = es.render_export_section(bad_state, platforms)
        shown = htmllib.unescape(bad_section).count("couldn't check")
        check(shown >= len(platforms), f"every row says couldn't check (found {shown})")
        check("Never imported" not in bad_section, "and no row says Never imported")
        check("could not read its record" in bad_section, "the section says the store could not be read")

        print("4. the section is separate from the always-on sources table")
        check('<h2>Your data exports</h2>' in section, "its own heading")
        check("Where your data came from" not in section, "it is not inside the sources table")

        print("5. the stale-import rule")
        now = datetime(2026, 11, 14, tzinfo=timezone.utc)
        old_epoch = int((now - timedelta(days=120)).timestamp())
        stale_state = {"status": "ok", "marks": {"LinkedIn": (old_epoch, "mtime")}, "error": None}
        import diagnostic_rules as dr  # noqa: E402  (imports status_collector; CANNOT-RUN if deps are absent)

        findings = dr.check_gdpr_export_age(SimpleNamespace(export_imports=stale_state))
        check(len(findings) == 1, f"one finding for a LinkedIn import 120 days old (got {len(findings)})")
        if findings:
            f = findings[0]
            check("LinkedIn" in f["title"] and "120 days" in f["title"], "the title names LinkedIn and the age")
            check("linkedin.com" in f["detail"], "the detail carries the LinkedIn request link")
            check("ostler-import" not in str(f) and "--verbose" not in str(f),
                  "the dev-CLI fix command is gone")
        check(dr.check_gdpr_export_age(SimpleNamespace(export_imports=None)) == [],
              "a snapshot with no store read is silence, not a finding")
        unread = dr.check_gdpr_export_age(SimpleNamespace(export_imports=bad_state))
        check(len(unread) == 1 and "couldn't check" in unread[0]["title"],
              "an unreadable store is a couldn't-check finding, never a clean pass")

        print("7. the full Doctor dashboard renders the section (web_ui.render_dashboard)")
        import status_collector as sc
        import web_ui as wui  # noqa: E402
        snap = sc.SystemSnapshot(export_imports=state)
        page = wui.render_dashboard(snap, [])
        plain = htmllib.unescape(page)
        check("<h2>Your data exports</h2>" in page, "the dashboard HTML carries the section heading")
        check("2 Oct 2026" in plain, "and the LinkedIn import date")
        check(f'href="{discord_url}"' in page, "and the Discord request link")
        check("Where your data came from" in page, "beside the always-on sources table, which is still there")

        print("6. web_ui.py renders the section")
        web = (AGENT / "web_ui.py").read_text(encoding="utf-8")
        check("from export_status import collect_import_state, render_export_section" in web, "web_ui imports the renderer")
        check("{export_section}" in web and "render_export_section(" in web,
              "and places it in the dashboard")
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)

    print()
    if FAILS:
        print(f"RESULT: {len(FAILS)} FAIL")
        return 1
    print("RESULT: all checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
