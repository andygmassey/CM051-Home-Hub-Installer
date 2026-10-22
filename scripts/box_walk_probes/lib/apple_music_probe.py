#!/usr/bin/env python3
"""Judge for probes/apple_music_library_reaches_preferences.sh (CM051 walk #27).

Pure: facts JSON in, assertion lines and an exit code out, so --self-test can
drive every branch from fixtures. Counts only; no title, artist or name is
ever read or printed.

FACTS (assembled by the probe from the box):
    summary_present   bool   ~/.ostler/imports/fda/extraction_summary.json read
    apple_music       dict   that summary's sources.apple_music, or null
    library_bundles   int    Music Library.musiclibrary bundles under ~/Music/Music,
                             or null when the ls itself could not run
    prefs_total       int|str  points_count of the preferences collection, or
                             AUTH / ABSENT / TRANSPORT / UNPARSED:<code>
    prefs_apple       int|str  points with payload source == apple_music, same
                             vocabulary

EXIT  0 PASS   1 FAIL   78 CANNOT-RUN (the line says which: TCC, or empty library)
"""
from __future__ import annotations

import json
import sys

PASS, FAIL, CANNOT = 0, 1, 78


def judge(f: dict) -> tuple[int, list[str]]:
    out: list[str] = []

    def line(kind: str, msg: str) -> None:
        out.append(f"  {kind:<6} {msg}")

    if not f.get("summary_present"):
        line("CANNOT", "no FDA extraction summary on the box (~/.ostler/imports/fda/extraction_summary.json); the install never ran the extractor, so nothing about Apple Music was measured")
        return CANNOT, out
    am = f.get("apple_music")
    if not isinstance(am, dict):
        line("FAIL", "the extraction summary has no apple_music entry: the extractor that shipped does not know the source")
        return FAIL, out
    status = am.get("status")
    if status == "disabled_by_user":
        line("FAIL", "apple_music was not requested (status disabled_by_user); it is in the default preset, so either the preset regressed or this walk picked Customise and unticked it")
        return FAIL, out
    if status == "not_tried":
        line("CANNOT", f"the apple_music arm was skipped by the {am.get('writer', '?')} run and no earlier read is recorded ({am.get('reason', '')}); nothing about Apple Music was measured")
        return CANNOT, out
    if status != "ok":
        line("FAIL", f"the apple_music arm reported status {status!r} (error: {am.get('error', '')!s}); a refused permission or an empty library is status ok with 0 tracks, so this is a crash")
        return FAIL, out

    tracks = int(am.get("total_tracks") or 0)
    reader = am.get("reader", "?")
    native = am.get("native_status", "?")
    detail = am.get("native_detail", "")
    bundles = f.get("library_bundles")
    writer = am.get("writer") or "unrecorded"
    line("note", f"writer={writer} reader={reader} native_status={native}{(' (' + detail + ')') if detail else ''} tracks={tracks} library_bundles={bundles}")

    if tracks == 0:
        if native == "unavailable":
            if bundles == 0:
                line("CANNOT", "EMPTY LIBRARY: no Music Library.musiclibrary under ~/Music/Music and the framework found nothing; there is no Apple Music to read on this box")
            else:
                line("CANNOT", f"TCC: Media & Apple Music not granted to the installer ({detail or 'framework refused'}); the library exists ({bundles} bundle), so only a console walk that clicks Allow on the Apple Music prompt can measure this")
            return CANNOT, out
        if native == "empty":
            line("CANNOT", "EMPTY LIBRARY: the Music framework answered and the library holds no songs; nothing to count")
            return CANNOT, out
        if native == "not_tried":
            line("FAIL", "the native helper was never run (native_status not_tried): install.sh did not find ${SCRIPT_DIR}/ostler-music-library, so the reader fell back to the XML export only, which is the walk #27 defect")
            return FAIL, out
        line("FAIL", f"the native helper broke (native_status {native}, {detail}); read 0 tracks")
        return FAIL, out

    line("ok", f"the Apple Music reader saw {tracks} track(s) via the {reader} reader")
    total, apple = f.get("prefs_total"), f.get("prefs_apple")
    if not isinstance(total, int):
        line("CANNOT", f"the preferences collection did not answer with a count ({total}); the store half was not measured")
        return CANNOT, out
    if not isinstance(apple, int):
        line("CANNOT", f"the apple_music count query did not answer ({apple}) although the collection did ({total}); not measured")
        return CANNOT, out
    if apple <= 0:
        line("FAIL", f"{tracks} track(s) read, 0 apple_music preference points in the store (collection holds {total}): the library never reached preferences")
        return FAIL, out
    line("ok", f"{apple} apple_music preference point(s) in the store (collection holds {total})")
    return PASS, out


# ── self-test: every branch, from fixtures ───────────────────────────────
_OK_AM = {"status": "ok", "total_tracks": 120, "reader": "native", "native_status": "ok", "native_detail": ""}
_CASES = [
    ("writer in detail", {"summary_present": True, "apple_music": {**_OK_AM, "writer": "install"}, "library_bundles": 1, "prefs_total": 900, "prefs_apple": 120}, PASS, "writer=install"),
    ("writer unrecorded", {"summary_present": True, "apple_music": _OK_AM, "library_bundles": 1, "prefs_total": 900, "prefs_apple": 120}, PASS, "writer=unrecorded"),
    ("skipped, nothing carried", {"summary_present": True, "apple_music": {"status": "not_tried", "reason": "owned by music-refresh", "writer": "fda-rerun"}}, CANNOT, "skipped by the fda-rerun run"),
    ("ladder skipped, nothing carried", {"summary_present": True, "apple_music": {"status": "not_tried", "reason": "owned by music-refresh", "writer": "backfill-ladder"}}, CANNOT, "skipped by the backfill-ladder run"),
    ("pass", {"summary_present": True, "apple_music": _OK_AM, "library_bundles": 1, "prefs_total": 900, "prefs_apple": 120}, PASS, "ok"),
    ("no summary", {"summary_present": False}, CANNOT, "no FDA extraction summary"),
    ("no entry", {"summary_present": True, "apple_music": None}, FAIL, "no apple_music entry"),
    ("not requested", {"summary_present": True, "apple_music": {"status": "disabled_by_user"}}, FAIL, "disabled_by_user"),
    ("arm crashed", {"summary_present": True, "apple_music": {"status": "error", "error": "boom"}}, FAIL, "crash"),
    ("tcc refused", {"summary_present": True, "apple_music": {**_OK_AM, "total_tracks": 0, "native_status": "unavailable", "native_detail": "NSCocoaErrorDomain:4097"}, "library_bundles": 1}, CANNOT, "TCC: Media & Apple Music"),
    ("no library at all", {"summary_present": True, "apple_music": {**_OK_AM, "total_tracks": 0, "native_status": "unavailable"}, "library_bundles": 0}, CANNOT, "EMPTY LIBRARY"),
    ("empty library", {"summary_present": True, "apple_music": {**_OK_AM, "total_tracks": 0, "native_status": "empty"}, "library_bundles": 1}, CANNOT, "EMPTY LIBRARY"),
    ("helper never run", {"summary_present": True, "apple_music": {**_OK_AM, "total_tracks": 0, "reader": "none", "native_status": "not_tried"}, "library_bundles": 1}, FAIL, "never run"),
    ("walk #27 after an install read: native_status not_tried stays FAIL", {"summary_present": True, "apple_music": {**_OK_AM, "total_tracks": 0, "reader": "none", "native_status": "not_tried", "writer": "install"}, "library_bundles": 1}, FAIL, "never run"),
    ("helper hung", {"summary_present": True, "apple_music": {**_OK_AM, "total_tracks": 0, "native_status": "timeout"}, "library_bundles": 1}, FAIL, "helper broke"),
    ("read but not stored", {"summary_present": True, "apple_music": _OK_AM, "library_bundles": 1, "prefs_total": 900, "prefs_apple": 0}, FAIL, "never reached preferences"),
    ("store auth", {"summary_present": True, "apple_music": _OK_AM, "library_bundles": 1, "prefs_total": "AUTH", "prefs_apple": "AUTH"}, CANNOT, "did not answer"),
    ("count query broke", {"summary_present": True, "apple_music": _OK_AM, "library_bundles": 1, "prefs_total": 900, "prefs_apple": "UNPARSED:400"}, CANNOT, "count query did not answer"),
]


def self_test() -> int:
    """Exit 1 when EVERY case lands on its expected verdict (the negative
    controls were caught), 0 when any case leaked: the probe convention is
    that a self-test reports FAIL when its known-bad fixtures behave."""
    leaked = 0
    for name, facts, want_rc, want_text in _CASES:
        rc, lines = judge(facts)
        text = "\n".join(lines)
        good = rc == want_rc and want_text in text
        print(f"  {'caught' if good else 'LEAKED'}  {name}: rc={rc} want={want_rc}")
        if not good:
            leaked += 1
            print("        | " + text.replace("\n", "\n        | "))
    print(f"self-test: {len(_CASES)} cases, {leaked} leaked")
    return 0 if leaked else 1


def main(argv: list[str]) -> int:
    if argv[:1] == ["--self-test"]:
        return self_test()
    if len(argv) == 2 and argv[0] == "judge":
        with open(argv[1]) as fh:
            facts = json.load(fh)
        rc, lines = judge(facts)
        print("\n".join(lines))
        return rc
    print("usage: apple_music_probe.py --self-test | judge <facts.json>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
