"""Stable JSON artefact emitter for the compiled interest profile.

This is the PRODUCER side of the preferences read-path (decision: fork A -
the daemon grows a ``pwg_preferences`` tool). CM059 compiles the interest
profile; this module flattens it into a stable, machine-readable JSON
artefact at a well-known path. CM041's ical-server then serves that artefact
at ``/api/v1/preferences`` and the daemon reads it through the new tool.

The artefact is a thin wrapper:

    {
      "schema_version": "0.1",
      "generated_at": "<ISO8601 UTC>",
      "count": <int>,
      "interests": [ <flat interest record>, ... ]
    }

Each flat interest record is exactly the output of
``interest_profile.build_interest`` / ``aggregate`` / ``finalise_confidence``,
i.e. it carries: id, subject, domain, category, polarity, score,
strength_raw, reliability, confidence, observations, recency_decay,
last_seen, sources (provenance), evidence (and any flags / corrected
markers). ``compile_profile`` groups likes by domain and splits dislikes
out; we flatten both back into one list here because the read-path consumer
(a tool, not a renderer) wants a single sortable list and every record
already carries its own ``domain`` and ``polarity``.

Path convention (honours an env override, mirrors CM059's other artefacts
which live under ``~/.ostler/editor/`` and read OSTLER_* env vars):

  * OSTLER_INTEREST_PROFILE  - full path to the artefact file (wins)
  * OSTLER_PREFERENCES_DIR   - directory; file is <dir>/interest_profile.json
  * default                  - ~/.ostler/preferences/interest_profile.json

The write is atomic (temp file in the same dir + os.replace) so a reader
never sees a half-written file.

CLI:  python3 -m compiler.emit_artefact [--oxigraph URL] [--out PATH]
                                        [--corrections PATH]
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone

from compiler import interest_profile as ip

SCHEMA_VERSION = "0.1"

DEFAULT_PREFERENCES_DIR = os.path.expanduser("~/.ostler/preferences")
DEFAULT_ARTEFACT_NAME = "interest_profile.json"


def artefact_path(path: str | None = None) -> str:
    """Resolve the stable artefact path, honouring env overrides.

    Precedence: explicit arg > OSTLER_INTEREST_PROFILE (full path) >
    OSTLER_PREFERENCES_DIR/interest_profile.json > the default under
    ~/.ostler/preferences/.
    """
    if path:
        return os.path.expanduser(path)
    full = os.environ.get("OSTLER_INTEREST_PROFILE")
    if full:
        return os.path.expanduser(full)
    pref_dir = os.environ.get("OSTLER_PREFERENCES_DIR") or DEFAULT_PREFERENCES_DIR
    return os.path.join(os.path.expanduser(pref_dir), DEFAULT_ARTEFACT_NAME)


def flatten_profile(profile: dict) -> list[dict]:
    """Flatten a compiled profile (grouped domains + dislikes) into one flat
    list of interest records, sorted by score descending. Each record is
    unchanged - it already carries domain and polarity."""
    interests: list[dict] = []
    for block in profile.get("domains", []):
        interests.extend(block.get("interests", []))
    interests.extend(profile.get("dislikes", []))
    interests.sort(key=lambda it: it.get("score", 0.0), reverse=True)
    return interests


def build_artefact(profile: dict, now: datetime | None = None) -> dict:
    """Wrap the flattened interest list with generated_at + count."""
    now = now or datetime.now(timezone.utc)
    interests = flatten_profile(profile)
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": now.isoformat(),
        "count": len(interests),
        "interests": interests,
        # carry the compiler's own stats through for diagnostics; the read
        # path ignores it, but it makes the artefact self-describing.
        "stats": profile.get("stats", {}),
    }


def write_artefact(artefact: dict, path: str | None = None) -> str:
    """Atomically write the artefact JSON to the stable path. Creates parent
    dirs. Returns the resolved path."""
    target = artefact_path(path)
    parent = os.path.dirname(target) or "."
    os.makedirs(parent, exist_ok=True)
    # temp file in the SAME directory so os.replace is atomic (same fs).
    tmp = f"{target}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(artefact, fh, indent=2, ensure_ascii=False)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, target)  # atomic on POSIX
    return target


def emit(oxigraph_url: str | None = None, corrections: dict | None = None,
         path: str | None = None, now: datetime | None = None) -> str:
    """Compile the interest profile from the live graph and write the stable
    artefact. Returns the resolved artefact path."""
    profile = ip.build_from_live(oxigraph_url, corrections=corrections)
    artefact = build_artefact(profile, now=now)
    return write_artefact(artefact, path)


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(
        description="Emit the stable interest-profile JSON artefact.")
    p.add_argument(
        "--oxigraph",
        default=os.environ.get("OSTLER_OXIGRAPH_URL", "http://localhost:7878"))
    p.add_argument(
        "--out", default=None,
        help="artefact path (default: env override or "
             "~/.ostler/preferences/interest_profile.json)")
    p.add_argument("--corrections", default=None,
                   help="path to corrections JSON")
    args = p.parse_args(argv)

    corr = None
    if args.corrections and os.path.exists(args.corrections):
        with open(args.corrections, encoding="utf-8") as fh:
            corr = json.load(fh)

    target = emit(args.oxigraph, corrections=corr, path=args.out)
    # read back the count for the log line without re-compiling
    with open(target, encoding="utf-8") as fh:
        count = json.load(fh).get("count", 0)
    print(f"interest-profile artefact: {count} interests -> {target}",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
