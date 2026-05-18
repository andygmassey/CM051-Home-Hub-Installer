#!/usr/bin/env python3
"""Write the install-time half of ~/.ostler/state/pipeline_signals.json.

Called by install.sh's mail-content probe (#259). The sidecar's
schema is the contract between this writer and the Doctor reader at
HR015 doctor/agent/status_collector.py::collect_pipeline_signals.

Schema:
    {
        "mail_accounts_found": int,        # informational only
        "mail_has_fetched": bool,          # load-bearing for #259 banner
        "install_completed_ts": int,       # epoch seconds at install time
        "first_ingest_complete_ts": int    # optional, written by tick (#260)
    }

The first_ingest_complete_ts key is preserved across runs (reinstall
case): if the file exists and carries a previous tick-written value,
we keep it. Other unknown keys are dropped on rewrite.

Atomic-write contract:
    - Writes to <output>.tmp first
    - chmods 0600 on the tmp file
    - os.replace to the final path (POSIX-atomic on same filesystem)

Exit codes:
    0  success
    2  unusable inputs (non-int accounts, etc.)
    3  unwritable output path
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
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    return data


def _parse_has_fetched(raw: str) -> bool:
    return raw.strip().lower() == "true"


def build_payload(
    accounts: int,
    has_fetched: bool,
    install_ts: int,
    existing: dict[str, Any],
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "mail_accounts_found": accounts,
        "mail_has_fetched": has_fetched,
        "install_completed_ts": install_ts,
    }
    prior_first = existing.get("first_ingest_complete_ts")
    if isinstance(prior_first, int):
        payload["first_ingest_complete_ts"] = prior_first
    return payload


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
        description="Write install-time half of pipeline_signals.json (#259).",
    )
    parser.add_argument("--output", required=True, help="Sidecar JSON path.")
    parser.add_argument(
        "--accounts",
        required=True,
        help="Mail accounts visible at install time (informational).",
    )
    parser.add_argument(
        "--has-fetched",
        required=True,
        help='"true" or "false" -- has Mail.app cached any messages?',
    )
    parser.add_argument(
        "--install-ts",
        default="",
        help="Override install timestamp (epoch seconds). Defaults to now.",
    )
    args = parser.parse_args(argv)

    try:
        accounts = int(args.accounts)
    except ValueError:
        print(
            f"write_pipeline_signals: --accounts must be int, got {args.accounts!r}",
            file=sys.stderr,
        )
        return 2

    has_fetched = _parse_has_fetched(args.has_fetched)

    if args.install_ts:
        try:
            install_ts = int(args.install_ts)
        except ValueError:
            print(
                f"write_pipeline_signals: --install-ts must be int, got {args.install_ts!r}",
                file=sys.stderr,
            )
            return 2
    else:
        install_ts = int(time.time())

    existing = _load_existing(args.output)
    payload = build_payload(accounts, has_fetched, install_ts, existing)

    try:
        atomic_write(args.output, payload)
    except OSError as exc:
        print(
            f"write_pipeline_signals: could not write {args.output}: {exc}",
            file=sys.stderr,
        )
        return 3

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
