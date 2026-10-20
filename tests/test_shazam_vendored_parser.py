#!/usr/bin/env python3
"""The SHIPPED (vendored) Shazam importer, end to end up to the stores.

Shazam history only arrives as an owner export (the MyShazam library CSV).
This runs the VENDORED pipeline and parser, not the upstream copy, and the
VENDORED CM059 privacy rules over what it produces:

  1. The vendored dispatcher routes a Shazam library file to ShazamParser, and
     routes a Netflix ViewingActivity.csv and an Apple TV file elsewhere
     (the control: the claim is not widened).
  2. Rows come out as category=music, source=shazam, with the documented
     columns only: no latitude/longitude, no URL.
  3. CM059 treats them as OBSERVED media: they keep L2 or tighter and are
     never widened to L1 without the owner's consent (is_observed_media is
     true, classify_privacy is not L1). Control: source "linkedin" is declared.
  4. An unknown shape is refused, the pipeline reports it in ``errors`` and
     the vendored ``ingest-dir`` prints it (CANNOT-RUN if click is absent).

Synthetic fixtures only. THREE OUTCOMES: 0 pass, 1 fail, 2 CANNOT-RUN.
"""
import asyncio
import importlib
import importlib.util
import sys
import tempfile
import types
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INGEST = REPO / "vendor" / "cm019_preferences" / "services" / "ingest"
CM059 = REPO / "vendor" / "cm059_editor"
sys.path.insert(0, str(INGEST))
sys.path.insert(0, str(CM059))

st = types.ModuleType("sentence_transformers")
st.SentenceTransformer = lambda *a, **k: types.SimpleNamespace(
    get_sentence_embedding_dimension=lambda: 8)
sys.modules["sentence_transformers"] = st

PASS = FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print("  [PASS] " + m)


def bad(m):
    global FAIL
    FAIL += 1
    print("  [FAIL] " + m)


def cannot(m):
    print("CANNOT-RUN: " + m, file=sys.stderr)
    sys.exit(2)


try:
    pipeline_mod = importlib.import_module("src.pipeline")
    from compiler import interest_profile as ip
except ImportError as e:
    cannot("import failed: %s" % e)
try:
    from src.parsers import ShazamExportShapeError, ShazamParser  # noqa: F401
except ImportError as e:
    # The vendored tree has no Shazam importer: that is the defect, not a
    # missing dependency.
    print("FAIL: vendored tree has no ShazamParser: %s" % e, file=sys.stderr)
    sys.exit(1)

TMP = Path(tempfile.mkdtemp(prefix="shazam-vendored."))
GOOD = (
    "Shazam Library\n"
    "Index,TagTime,Title,Artist,URL,TrackKey,Latitude,Longitude\n"
    "1,2024-06-13,Example Song One,Example Artist A,https://www.example.com/t/1,100001,51.501234,-0.141234\n"
    "2,2024-06-11,Example Song Two,Example Artist B,https://www.example.com/t/2,100002,51.501234,-0.141234\n"
)
good = TMP / "shazamlibrary.csv"
good.write_text(GOOD)
bad_shape = TMP / "drop" / "shazamlibrary.csv"
bad_shape.parent.mkdir()
bad_shape.write_text("Shazam Library\nSong,When\nX,2024-01-01\n")
netflix = TMP / "ViewingActivity.csv"
netflix.write_text("Profile Name,Start Time,Duration,Title\nA,2024-03-15 20:30:00,1:00:00,Example Show\n")

pipe = pipeline_mod.IngestPipeline()

print("=== VENDORED SHAZAM IMPORTER ===")
print("-- 1. dispatch --")
got = pipe._get_parser(good)
if got is not None and got.source_name == "shazam":
    ok("shazamlibrary.csv -> shazam")
else:
    bad("shazamlibrary.csv routed to %r" % (got and got.source_name))
got = pipe._get_parser(netflix)
if got is not None and got.source_name != "shazam":
    ok("CONTROL: ViewingActivity.csv -> %s, not shazam" % got.source_name)
else:
    bad("CONTROL: ViewingActivity.csv routed to %r" % (got and got.source_name))

print("-- 2. what comes out --")

async def _collect():
    return [p async for p in ShazamParser().parse(good)]


prefs = asyncio.run(_collect())
if len(prefs) == 2 and all(p.category == "music" and p.source == "shazam" for p in prefs):
    ok("2 tracks, category=music, source=shazam")
else:
    bad("prefs: %r" % [(p.subject, p.category, p.source) for p in prefs])
blob = repr([(p.subject, p.extra, p.to_payload("u")) for p in prefs])
if "51.501234" not in blob and "-0.141234" not in blob and "example.com/t/" not in blob:
    ok("no location, no URL anywhere in the payload")
else:
    bad("location or URL leaked into the payload")

print("-- 3. CM059 treats it as observed, local-only --")
p = prefs[0]
if ip.is_observed_media(p.category, p.source):
    ok("is_observed_media(music, shazam) is True")
else:
    bad("shazam is not observed media to CM059: it would be treated as declared")
lvl = ip.classify_privacy(p.category, p.source, [], subject=p.subject)
if lvl != "L1":
    ok("classify_privacy -> %s (never L1)" % lvl)
else:
    bad("shazam row classified L1, so a title could reach an external look-up")
if not ip.is_observed_media("music", "linkedin"):
    ok("CONTROL: a declared source (linkedin) is not observed, so the predicate discriminates")
else:
    bad("CONTROL broken: linkedin counted as observed")

print("-- 4. a refused shape is said, not swallowed --")
res = asyncio.run(pipe.ingest_file(bad_shape, "test-user"))
if res["preferences_created"] == 0 and any("Unrecognised Shazam export" in e for e in res["errors"]):
    ok("pipeline.ingest_file reports the refusal in errors")
else:
    bad("refusal not reported: %r" % res)

try:
    from click.testing import CliRunner
except ImportError:
    print("CANNOT-RUN (limb 4b): click is not installed, so the vendored ingest-dir "
          "output was not exercised", file=sys.stderr)
    print("\n== %d pass / %d fail (4b CANNOT-RUN) ==" % (PASS, FAIL))
    sys.exit(1 if FAIL else 2)

cli_mod = importlib.import_module("src.cli")


async def _init_ok(self):
    return True


pipeline_mod.IngestPipeline.initialize = _init_ok
cli_mod.IngestPipeline = pipeline_mod.IngestPipeline
out = CliRunner().invoke(cli_mod.cli, ["ingest-dir", str(bad_shape.parent), "-u", "test-user"])
if "Unrecognised Shazam export" in out.output and "ERROR:" in out.output:
    ok("vendored ingest-dir prints the refusal")
else:
    bad("vendored ingest-dir output hid the refusal: %r" % out.output[-400:])

print("\n== %d pass / %d fail / %d total ==" % (PASS, FAIL, PASS + FAIL))
sys.exit(1 if FAIL else 0)
