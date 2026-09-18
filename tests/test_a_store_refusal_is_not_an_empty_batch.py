#!/usr/bin/env python3
"""A store that REFUSED a write must not report as a batch with nothing to write (#953).

THE DEFECT, MEASURED ON THE BOX WITH A CONTROL BEFORE IT WAS FIXED. The ingest
pipeline's _process_batch called two loaders that are both declared `-> bool`
and both return False rather than raising on a store failure. It recorded an
error only in the `except` arm, so a refusal produced:

    endpoint 500 -> {"preferences": 3, "triples": 0, "vectors": 3, "errors": []}
    endpoint 204 -> {"preferences": 3, "triples": 3, "vectors": 3, "errors": []}

The control writes 3, so the 0 in the first arm means REFUSED and not "the
harness never works". `triples: 0, errors: []` is byte-identical to a batch that
genuinely had nothing to add.

IT IS WORSE THAN A SILENT ZERO. `vectors` is 3 in BOTH arms, so the run reports
"3 preferences, 3 vectors, 0 triples, no errors" and a reader concludes the
graph had nothing to add while the vectors landed. That is a SPLIT BRAIN
reported as health: Qdrant holds the preferences, Oxigraph does not, and nothing
says so. It is the same shape as a wiki showing a person the graph cannot answer
for, and row 953 predicted the "Ostler has spotted 0 interests" card that the
v1.0.100 walk then rendered.

AND IT PROPAGATED. ingest_file does errors.extend(batch_result["errors"]) and
self.stats["errors"] += len(result["errors"]), so a whole file, and then the
whole run, reported zero errors too.

WHY THE FIX IS IN THE CALLER AND NOT THE LOADER. Both loaders behave exactly as
documented: they log the status and return False. A census of the module found
33 functions declared `-> bool`, 7 call sites discarding the value, 28 testing
it with no negative branch, and a CONTROL of 22 sites where the negative case
does something. Most of the 28 are predicates where False is legitimately a
no-op. The ones naming a store operation are four, and the same module handles
the return value at pipeline.py:117, cli.py:185/308 and main.py:45/128. So
checking the return IS the local convention and _process_batch is where it
lapsed. A control of 22 rather than 0 is what makes this a defect and not a
house style.

WHAT THIS TEST DRIVES: the SHIPPED vendor/cm019_preferences pipeline.py, loaded
with its siblings stubbed, so the code under test is the file that installs.
Only the loaders' return values differ between the arms.

Exit 0 all arms pass, 1 any arm fails, 2 the subject could not be loaded.
"""
from __future__ import annotations

import asyncio
import importlib.util
import pathlib
import sys
import types

ROOT = pathlib.Path(__file__).resolve().parent.parent
SUBJECT = ROOT / "vendor/cm019_preferences/services/ingest/src/pipeline.py"

PASS = 0
FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print(f"  ok    {m}")


def bad(m, d=""):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {m}")
    if d:
        print(f"        | {d}")


def cannot_run(m):
    print(f"CANNOT-RUN: {m}", file=sys.stderr)
    return 2


class _Any:
    """Stands in for anything a sibling module exports. It never decides."""

    def __init__(self, *a, **k):
        pass

    def __call__(self, *a, **k):
        return _Any()

    def __getattr__(self, n):
        return _Any()


_STUB_SRC = (
    "class _Any:\n"
    "    def __init__(self, *a, **k): pass\n"
    "    def __call__(self, *a, **k): return _Any()\n"
    "    def __getattr__(self, n): return _Any()\n"
    "    def __iter__(self): return iter(())\n"
    "    def __getitem__(self, k): return _Any()\n"
    "    def __contains__(self, k): return False\n"
    "    def __bool__(self): return False\n"
    "def __getattr__(name): return _Any()\n"
)

PKG = "_cm019_ingest_src"
SUBJECT_MODULE = f"{PKG}.pipeline"
FABRICATED: list[str] = []


class _StubLoader:
    """Every stub module is also a PACKAGE, and that is the repair.

    The first version of this file listed six sibling names and built a plain
    module for each. A plain module has no ``__path__``, so the import
    machinery asks the module-level ``__getattr__`` for one, gets a stand-in
    object, and tries to ITERATE it. ``__path__ = []`` makes each stub a
    package whose children this finder then answers for.
    """

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        module.__path__ = []
        exec(compile(_STUB_SRC, f"<stub {module.__name__}>", "exec"),
             module.__dict__)
        FABRICATED.append(module.__name__)


class _StubFinder:
    """Fabricate a stub for ANY module under the stub package.

    🔴 WHY A FINDER AND NOT A LIST OF NAMES, measured rather than preferred.
    This test named its six siblings explicitly. CM051 #2052 then added one
    line to the SHIPPED pipeline.py:

        from .loaders.qdrant_loader import COMPARTMENT_AT_OR_ABOVE as ...

    a SUBMODULE of a stubbed sibling, which no name in that list covered. The
    test went CANNOT-RUN, exit 2, on every pull request AND on main, and main
    stayed red because the only workflow that runs it is path-filtered and
    nothing else reported. A stub list is a second copy of the subject's import
    graph, and it goes stale the first time the subject gains an import.

    🗿 AND THE SCOPE IS THE POINT, because a stub that answers for everything
    hides exactly the defect this file exists to catch. It answers ONLY for
    names under this package's prefix, and never for the subject itself. An
    import of something real and genuinely missing still raises, and there are
    two arms below that prove the finder refuses rather than fabricating.

    WHAT THE STUBS CANNOT DO, said plainly: a stubbed constant is not the real
    constant. The arms in this file assert how a REFUSAL is recorded, and no
    arm depends on a value a sibling would have supplied, so a stand-in is
    honest here. An arm that started depending on one would be measuring the
    stub.
    """

    def find_spec(self, name, path=None, target=None):
        if name == SUBJECT_MODULE or not name.startswith(PKG + "."):
            return None
        return importlib.util.spec_from_loader(name, _StubLoader())


def _load_subject():
    """Import the SHIPPED pipeline.py with its siblings stubbed."""
    pkg = types.ModuleType(PKG)
    pkg.__path__ = [str(SUBJECT.parent)]
    sys.modules[PKG] = pkg
    sys.meta_path.insert(0, _StubFinder())
    spec = importlib.util.spec_from_file_location(SUBJECT_MODULE, SUBJECT)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[SUBJECT_MODULE] = mod
    spec.loader.exec_module(mod)
    return mod


class _Pref:
    """A synthetic preference. No real person, no real store, no real value."""

    def __init__(self, n):
        self.id = f"synthetic-{n}"
        self.embedding_text = f"synthetic taste {n}"

    def to_turtle(self, user_id):
        return f'<urn:synthetic:{self.id}> <urn:synthetic:for> "{user_id}" .'

    def to_payload(self, user_id):
        return {"id": self.id, "user_id": user_id}


class _Loader:
    def __init__(self, answer):
        self.answer = answer
        self.calls = 0

    async def insert_triples(self, _turtle):
        self.calls += 1
        return self.answer

    async def upsert_vectors(self, vectors=None, payloads=None, ids=None):
        self.calls += 1
        return self.answer


class _Vectorizer:
    dimension = 4

    def embed_batch(self, texts):
        return [[0.0] * self.dimension for _ in texts]


def run_arm(mod, graph_ok: bool, vector_ok: bool):
    ox = _Loader(graph_ok)
    qd = _Loader(vector_ok)
    fake_self = types.SimpleNamespace(oxigraph=ox, qdrant=qd)
    prefs = [_Pref(i) for i in range(3)]
    res = asyncio.run(mod.IngestPipeline._process_batch(fake_self, prefs, "synthetic-user"))
    return res, ox, qd


def main() -> int:
    if not SUBJECT.is_file():
        return cannot_run(f"{SUBJECT} is not on disk")
    try:
        mod = _load_subject()
    except Exception as exc:
        return cannot_run(f"the shipped pipeline.py could not be loaded: {exc}")
    if not hasattr(mod, "IngestPipeline"):
        return cannot_run("the loaded module has no IngestPipeline, so it is not the subject")
    mod.vectorizer = _Vectorizer()
    print(f"EXAMINED: {SUBJECT.relative_to(ROOT)}")

    print()
    print("ARM 1: THE CONTROL FIRST. Both stores accept, so the harness can write at all.")
    good, ox, qd = run_arm(mod, True, True)
    if good["triples"] == 3 and good["vectors"] == 3 and good["errors"] == []:
        ok(f"(1) accepted: {good['preferences']} preferences, {good['triples']} triples, "
           f"{good['vectors']} vectors, {len(good['errors'])} errors")
    else:
        bad("(1) the control did not write, so every zero below is unreadable", repr(good))
        print(f"\n=== {PASS} passed / {FAIL} failed ===")
        return 1
    if ox.calls == 1 and qd.calls == 1:
        ok("(1b) both loaders were actually called once")
    else:
        bad(f"(1b) loader call counts are ox={ox.calls} qd={qd.calls}, expected 1 and 1")

    print()
    print("ARM 2: THE DEFECT. The graph REFUSES. triples must be 0 AND errors must not be.")
    refused, _, _ = run_arm(mod, False, True)
    if refused["triples"] == 0:
        ok("(2a) triples is 0, as it was before the fix")
    else:
        bad(f"(2a) triples is {refused['triples']}, so the refusal was not honoured")
    if refused["errors"]:
        ok(f"(2b) the refusal is RECORDED: {len(refused['errors'])} error(s)")
    else:
        bad("(2b) triples 0 with errors [] is byte-identical to a batch with nothing to write",
            repr(refused))
    if refused["vectors"] == 3 and refused["errors"]:
        ok("(2c) the SPLIT BRAIN is visible: vectors 3, triples 0, and an error says so")
    else:
        bad(f"(2c) vectors={refused['vectors']} errors={len(refused['errors'])}", repr(refused))

    print()
    print("ARM 3: THE SECOND INSTANCE. The vector store refuses. Same shape, next function down.")
    vrefused, _, _ = run_arm(mod, True, False)
    if vrefused["vectors"] == 0 and vrefused["errors"]:
        ok(f"(3) a refused vector write is recorded too: {len(vrefused['errors'])} error(s)")
    else:
        bad("(3) a refused vector write reported vectors 0 with no error", repr(vrefused))

    print()
    print("ARM 4: BOTH REFUSE. Two failures must not collapse into one.")
    both, _, _ = run_arm(mod, False, False)
    if both["triples"] == 0 and both["vectors"] == 0 and len(both["errors"]) >= 2:
        ok(f"(4) {len(both['errors'])} errors recorded for two refused writes")
    else:
        bad(f"(4) two refusals produced {len(both['errors'])} error(s)", repr(both))

    print()
    print("ARM 5: MUST-MISS. A genuinely EMPTY batch must still report no error.")
    empty = asyncio.run(mod.IngestPipeline._process_batch(
        types.SimpleNamespace(oxigraph=_Loader(True), qdrant=_Loader(True)), [], "synthetic-user"))
    if empty["preferences"] == 0 and empty["triples"] == 0 and empty["errors"] == []:
        ok("(5) nothing to write is still a clean zero, so the guard did not turn empty into failed")
    else:
        bad("(5) an empty batch now reports an error it should not", repr(empty))

    print()
    print("ARM 6: THE STUB MACHINERY ITSELF. A stub that answers for everything")
    print("       would hide the very defect the arms above measure.")
    print(f"       EXAMINED: {len(FABRICATED)} sibling module(s) fabricated: "
          f"{', '.join(sorted(FABRICATED)) or '<none>'}")
    if FABRICATED:
        ok(f"(6a) the finder fabricated {len(FABRICATED)} sibling(s), so it was reached at all")
    else:
        bad("(6a) NO sibling was fabricated, so arms 1 to 5 ran against something "
            "other than the shipped file's import graph and prove nothing")

    # 🔴 THE CONTROL. Outside the package prefix the finder must REFUSE. If it
    # fabricated anything asked of it, an import of something real and missing
    # would succeed and the subject would be tested with a phantom in place of
    # a dependency that has genuinely gone.
    import importlib
    for absent in ("no_such_top_level_xyzzy", "_cm019_ingest_src_not_this_one.thing"):
        try:
            importlib.import_module(absent)
        except ModuleNotFoundError:
            ok(f"(6b) the finder refuses {absent!r}, so its scope is real")
        except Exception as exc:  # pragma: no cover - a surprise is not a pass
            bad(f"(6b) importing {absent!r} raised {type(exc).__name__}, not "
                "ModuleNotFoundError", str(exc))
        else:
            bad(f"(6b) the finder FABRICATED {absent!r}. It answers for names "
                "outside its package, so every arm above may be measuring a "
                "stand-in rather than the shipped file's real dependencies.")

    print()
    print(f"=== {PASS} passed / {FAIL} failed ===")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
