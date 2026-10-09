"""CI seed: the shared fictional graph (scripts/box_walk_probes/lib/meeting_brief_seed.py)
loaded into the in-memory store behind the real Hub. One definition, two users:
this and the walk probe, so the CI graph and the box graph cannot drift apart."""
import pathlib
import sys

_LIB = pathlib.Path(__file__).resolve().parents[2] / "scripts/box_walk_probes/lib"
sys.path.insert(0, str(_LIB))
import meeting_brief_seed as _s  # noqa: E402

RICH, NONE, THIN = _s.RICH, _s.NONE, _s.THIN
ANCHOR = _s.ANCHOR
calendar_events = _s.calendar_events


def seed(hub):
    default, named = _s.sparql()
    hub.update(default)
    if named:
        hub.update(named)
