#!/usr/bin/env python3
"""#657: synthetic parse-layer verification harness for the 21 vendored
CM019 social-archive parsers.

Goal: convert "vendored + import-clean but UNTESTED against real formats"
into a real pass/fail verdict per parser, WITHOUT touching any real archive
(PRODUCTISATION_CHECKLIST.md Rule 0). For each parser we ship a SYNTHETIC
fixture in the parser's expected export format under
``tests/parser_verify/fixtures/<source_name>/`` and assert the real vendored
parser:
  - recognises the fixture (``can_parse`` True for at least one file), and
  - yields >= 1 ``ParsedPreference`` with a non-empty subject from it.

This is the PARSE layer only (export bytes -> ParsedPreference objects). The
WRITE layer (ParsedPreference -> Qdrant/Oxigraph via the loaders + Ollama
embed) is a separate harness; a green parse layer is necessary-but-not-
sufficient for "this source works end to end".

Run:  <venv-with-cm019-deps>/bin/python tests/parser_verify/verify_parsers.py
Deps: aiofiles pydantic pydantic-settings beautifulsoup4 lxml openpyxl
      msoffcrypto-tool  (the vendored cm019 requirements.txt set).

Exit 0 only if every parser that HAS a fixture passes. Parsers with no
fixture yet are reported as TODO (not a failure) so the list can grow
incrementally -- but they are listed loudly (no silent omission).
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
CM019_ROOT = REPO / "vendor" / "cm019_preferences"
FIXTURES = HERE / "fixtures"

sys.path.insert(0, str(CM019_ROOT))

from services.ingest.src.parsers import __all__ as PARSER_NAMES  # noqa: E402
from services.ingest.src import parsers as parsers_mod  # noqa: E402


def parser_classes():
    """Every concrete BaseParser subclass exported by the package."""
    from services.ingest.src.parsers import BaseParser
    out = []
    for name in PARSER_NAMES:
        obj = getattr(parsers_mod, name)
        if isinstance(obj, type) and issubclass(obj, BaseParser) and obj is not BaseParser:
            out.append(obj)
    return out


async def collect(parser, file_path: Path):
    prefs = []
    async for pref in parser.parse(file_path):
        prefs.append(pref)
    return prefs


async def verify_one(parser_cls):
    parser = parser_cls()
    source = getattr(parser, "source_name", parser_cls.__name__)
    fixture_dir = FIXTURES / source
    if not fixture_dir.is_dir() or not any(fixture_dir.rglob("*")):
        return source, "TODO", "no fixture yet", 0
    matched_files = []
    all_prefs = []
    errors = []
    for f in sorted(fixture_dir.rglob("*")):
        if not f.is_file():
            continue
        try:
            if not parser.can_parse(f):
                continue
        except Exception as e:  # noqa: BLE001
            errors.append(f"can_parse({f.name}): {e!r}")
            continue
        matched_files.append(f.name)
        try:
            all_prefs.extend(await collect(parser, f))
        except Exception as e:  # noqa: BLE001
            errors.append(f"parse({f.name}): {e!r}")
    if errors:
        return source, "FAIL", "; ".join(errors)[:160], len(all_prefs)
    if not matched_files:
        return source, "FAIL", "fixture present but can_parse matched no file", 0
    nonempty = [p for p in all_prefs if (getattr(p, "subject", "") or "").strip()]
    if not nonempty:
        return source, "FAIL", f"matched {matched_files} but yielded 0 non-empty prefs", len(all_prefs)
    cats = sorted({getattr(p, "category", "") for p in nonempty if getattr(p, "category", "")})
    return source, "PASS", f"{matched_files} -> cats={cats[:4]}", len(nonempty)


async def main():
    rows = []
    for cls in parser_classes():
        rows.append(await verify_one(cls))
    rows.sort(key=lambda r: (r[1] != "FAIL", r[1] != "PASS", r[0]))

    print(f"{'SOURCE':18} {'STATUS':6} {'PREFS':>6}  DETAIL")
    print("-" * 100)
    npass = nfail = ntodo = 0
    for source, status, detail, n in rows:
        print(f"{source:18} {status:6} {n:>6}  {detail}")
        npass += status == "PASS"
        nfail += status == "FAIL"
        ntodo += status == "TODO"
    print("-" * 100)
    print(f"PASS={npass}  FAIL={nfail}  TODO(no fixture)={ntodo}  total={len(rows)}")
    if ntodo:
        todo = [r[0] for r in rows if r[1] == "TODO"]
        print(f"TODO parsers (need a synthetic fixture): {todo}")
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
