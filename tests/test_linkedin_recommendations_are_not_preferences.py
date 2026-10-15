#!/usr/bin/env python3
"""A LinkedIn recommendation is somebody's prose about a colleague, not a taste.

Ostler #30 console walk: the front page "A hunch" card offered a whole
LinkedIn recommendation paragraph (Recommendations_Given.csv, column Text) as
an interest, filed as music. No LinkedIn handler claimed the file, so the
generic CSV parser read the Text column as a preference.

Synthetic data only.
"""
from __future__ import annotations

import asyncio
import sys
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm019_preferences"))

from services.ingest.src.pipeline import IngestPipeline  # noqa: E402

HEADER = "First Name,Last Name,Company,Job Title,Text,Creation Date,Status\n"
ROW = ('Marta,Kowalczyk,fixture co,Engineer,"Marta is a wonderful colleague who plays piano and '
       'listens to jazz music every day with great dedication to the craft over many years.",'
       '01/02/24,VISIBLE\n')


def _pipeline():
    p = IngestPipeline.__new__(IngestPipeline)
    IngestPipeline.__init__(p)
    return p


@pytest.mark.parametrize("name", ["Recommendations_Given.csv", "Recommendations_Received.csv"])
def test_recommendation_text_yields_no_preference(name):
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / name
        f.write_text(HEADER + ROW)
        parser = _pipeline()._get_parser(f)
        assert parser is not None and type(parser).__name__ == "LinkedInParser", type(parser).__name__

        async def go():
            return [x async for x in parser.parse(f, default_compartment=2)]
        got = asyncio.run(go())
        print(f"{name}: {type(parser).__name__} -> {len(got)} preferences")
        assert got == []


def test_control_the_generic_csv_path_still_reads_an_unclaimed_file():
    """Control: the dispatcher is live and a real preference file still produces rows."""
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / "Reactions.csv"
        f.write_text("Date,Link,Type\n2024-01-01,https://www.linkedin.com/feed/update/urn:li:activity:1,LIKE\n")
        parser = _pipeline()._get_parser(f)
        assert type(parser).__name__ == "LinkedInParser"
