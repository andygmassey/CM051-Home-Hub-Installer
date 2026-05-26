#!/usr/bin/env python3
"""Write the install-time half of ~/.ostler/state/pipeline_signals.json.

Called by install.sh's mail-content probe (#259) and assistant-FDA
probe (#501 / CX-60). The sidecar's schema is the contract between
this writer and the Doctor reader at HR015
doctor/agent/status_collector.py::collect_pipeline_signals.

Schema:
    {
        "mail_accounts_found": int,             # #259, informational
        "mail_has_fetched": bool,               # #259, load-bearing
        "install_completed_ts": int,            # epoch seconds at install
        "first_ingest_complete_ts": int,        # optional, set by tick (#260)
        "imessage_chat_db_fda_needed": bool     # CX-60, load-bearing for the
                                                # Doctor iMessage FDA card
    }

Existing keys are preserved across re-writes (additive schema):
if the file already carries a tick-written first_ingest_complete_ts
or a prior install-written imessage_chat_db_fda_needed and this
invocation doesn't supply the matching arg, the old value stays.
Unknown keys are dropped on rewrite.

The mail-half (--accounts + --has-fetched) and the iMessage half
(--imessage-fda-needed) are optional and independent. Either set
may be supplied alone, both together, or neither (a no-op write
that just refreshes install_completed_ts -- useful in tests).

Atomic-write contract:
    - Writes to <output>.tmp first
    - chmods 0600 on the tmp file
    - os.replace to the final path (POSIX-atomic on same filesystem)

Exit codes:
    0  success
    2  unusable inputs (non-int accounts, bad bool string, partial
       mail args)
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


def _parse_bool(raw: str) -> bool:
    return raw.strip().lower() == "true"


# Back-compat alias for tests / callers that still import the old name.
_parse_has_fetched = _parse_bool


def build_payload(
    accounts: int | None,
    has_fetched: bool | None,
    install_ts: int,
    existing: dict[str, Any],
    imessage_fda_needed: bool | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "install_completed_ts": install_ts,
    }

    # Mail half: only overwrite when the caller passed both args
    # (validated by main()). Otherwise preserve prior values.
    if accounts is not None and has_fetched is not None:
        payload["mail_accounts_found"] = accounts
        payload["mail_has_fetched"] = has_fetched
    else:
        prior_accounts = existing.get("mail_accounts_found")
        if isinstance(prior_accounts, int):
            payload["mail_accounts_found"] = prior_accounts
        prior_fetched = existing.get("mail_has_fetched")
        if isinstance(prior_fetched, bool):
            payload["mail_has_fetched"] = prior_fetched

    # First-ingest sentinel: written by the email-ingest tick (#260).
    # Always preserved across installer rewrites.
    prior_first = existing.get("first_ingest_complete_ts")
    if isinstance(prior_first, int):
        payload["first_ingest_complete_ts"] = prior_first

    # iMessage FDA half (CX-60): explicit arg wins; otherwise preserve.
    if imessage_fda_needed is not None:
        payload["imessage_chat_db_fda_needed"] = imessage_fda_needed
    else:
        prior_imessage = existing.get("imessage_chat_db_fda_needed")
        if isinstance(prior_imessage, bool):
            payload["imessage_chat_db_fda_needed"] = prior_imessage

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
        description=(
            "Write install-time half of pipeline_signals.json "
            "(#259 mail probe + CX-60 iMessage FDA probe)."
        ),
    )
    parser.add_argument("--output", required=True, help="Sidecar JSON path.")
    parser.add_argument(
        "--accounts",
        default=None,
        help=(
            "Mail accounts visible at install time (informational). "
            "When set, --has-fetched is required."
        ),
    )
    parser.add_argument(
        "--has-fetched",
        default=None,
        help=(
            '"true" or "false" -- has Mail.app cached any messages? '
            "When set, --accounts is required."
        ),
    )
    parser.add_argument(
        "--imessage-fda-needed",
        default=None,
        help=(
            '"true" or "false" -- did the install-time probe find the '
            "ostler-assistant daemon unable to read ~/Library/Messages/"
            "chat.db (i.e. FDA not granted to the daemon binary)?"
        ),
    )
    parser.add_argument(
        "--install-ts",
        default="",
        help="Override install timestamp (epoch seconds). Defaults to now.",
    )
    args = parser.parse_args(argv)

    if (args.accounts is None) != (args.has_fetched is None):
        print(
            "write_pipeline_signals: --accounts and --has-fetched must be "
            "supplied together (or both omitted to leave the mail half "
            "untouched).",
            file=sys.stderr,
        )
        return 2

    accounts: int | None = None
    if args.accounts is not None:
        try:
            accounts = int(args.accounts)
        except ValueError:
            print(
                f"write_pipeline_signals: --accounts must be int, got {args.accounts!r}",
                file=sys.stderr,
            )
            return 2

    has_fetched: bool | None = None
    if args.has_fetched is not None:
        has_fetched = _parse_bool(args.has_fetched)

    imessage_fda_needed: bool | None = None
    if args.imessage_fda_needed is not None:
        raw = args.imessage_fda_needed.strip().lower()
        if raw not in ("true", "false"):
            print(
                f"write_pipeline_signals: --imessage-fda-needed must be "
                f"'true' or 'false', got {args.imessage_fda_needed!r}",
                file=sys.stderr,
            )
            return 2
        imessage_fda_needed = raw == "true"

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
    payload = build_payload(
        accounts,
        has_fetched,
        install_ts,
        existing,
        imessage_fda_needed=imessage_fda_needed,
    )

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
