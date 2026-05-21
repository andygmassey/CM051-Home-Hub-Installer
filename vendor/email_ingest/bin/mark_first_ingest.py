#!/usr/bin/env python3
"""Mark the first successful non-empty ingest in pipeline_signals.json.

Called by email-ingest-tick.sh after pwg-email-ingest exits 0 on a
non-empty mbox. Idempotent: only writes ``first_ingest_complete_ts``
if it is not already set; otherwise exits 0 without touching the
sidecar.

The sidecar is shared with #259's install-time probe (written by
CM051 install.sh via lib/write_pipeline_signals.py). Per the
2026-05-17 findings, the consolidated file lets the Doctor agent
serve both the empty-Mail banner (#259) and the backfill-progress
banner (#260) from a single state location.

Schema (extends #259):
    {
        "mail_accounts_found": int,
        "mail_has_fetched": bool,
        "install_completed_ts": int,
        "first_ingest_complete_ts": int   <- this writer owns this key
    }

Exit codes:
    0  success or already-set (idempotent no-op)
    2  bad argv
    3  sidecar exists but unreadable / unparseable
    4  unwritable output path

Failure-isolation contract:
    The tick script must not fail when this helper fails. The
    LaunchAgent log captures the diagnostic and the next tick retries.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any


def _load_existing(path: str) -> dict[str, Any]:
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"sidecar root must be object, got {type(data).__name__}")
    return data


def atomic_write(path: str, payload: dict[str, Any]) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    tmp_path = f"{path}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, path)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Idempotently mark first_ingest_complete_ts in pipeline_signals.json.",
    )
    parser.add_argument(
        "--sidecar",
        required=True,
        help="Path to pipeline_signals.json.",
    )
    parser.add_argument(
        "--ts",
        default="",
        help="Override timestamp (epoch seconds). Defaults to now.",
    )
    args = parser.parse_args(argv)

    try:
        existing = _load_existing(args.sidecar)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"mark_first_ingest: cannot read {args.sidecar}: {exc}", file=sys.stderr)
        return 3

    prior = existing.get("first_ingest_complete_ts")
    if isinstance(prior, int):
        # Already set on a previous tick. Idempotent no-op.
        return 0

    if args.ts:
        try:
            now_ts = int(args.ts)
        except ValueError:
            print(f"mark_first_ingest: --ts must be int, got {args.ts!r}", file=sys.stderr)
            return 2
    else:
        now_ts = int(time.time())

    existing["first_ingest_complete_ts"] = now_ts

    try:
        atomic_write(args.sidecar, existing)
    except OSError as exc:
        print(
            f"mark_first_ingest: could not write {args.sidecar}: {exc}",
            file=sys.stderr,
        )
        return 4

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
