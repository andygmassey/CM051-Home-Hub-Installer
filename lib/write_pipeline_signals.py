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
        "imessage_chat_db_fda_needed": bool,    # CX-60, load-bearing for the
                                                # Doctor iMessage FDA card
        "notes_has_fetched": bool,              # Apple Notes store has rows;
                                                # also refreshed hourly by
                                                # ostler-fda
        "notes_checked_ts": int                 # when notes_has_fetched was
                                                # last measured
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
import re
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


VALID_ENRICHMENT_DECISIONS = ("accepted", "declined", "unknown")


# Consumer webmail. Mirrors _OWNER_WEBMAIL_DOMAINS in install.sh; a test
# (test_shell_and_python_webmail_lists_do_not_drift) keeps the two equal.
WEBMAIL_DOMAINS = frozenset({
    "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com",
    "hotmail.com", "live.com", "msn.com", "yahoo.com", "ymail.com", "proton.me",
    "protonmail.com", "pm.me", "fastmail.com", "aol.com", "gmx.com", "gmx.net",
    "mail.com", "yandex.com", "zoho.com", "qq.com", "163.com",
})
# Passed by the installer when the mail store could not be read: unknown, so
# the prior value stands. Not a domain (no dot), so it cannot collide.
UNKNOWN_SENTINEL = "__unknown__"
_DOMAIN_RE = re.compile(r"^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$")


def normalise_owner_mail_domains(raw: str) -> list[str]:
    """Owner's work mail domains from a comma list. Domains only, webmail dropped.

    An address is refused, never reduced to its domain here: the installer is
    the place that reads addresses, and it must emit domains. Empty input is
    'no domains' (an answer), distinct from UNKNOWN_SENTINEL.
    """
    out: set[str] = set()
    for part in raw.split(","):
        d = part.strip().lower()
        if not d:
            continue
        if "@" in d:
            raise ValueError("owner mail: addresses are refused, domains only")
        if not _DOMAIN_RE.match(d):
            raise ValueError(f"owner mail: not a domain: {d!r}")
        if d in WEBMAIL_DOMAINS:
            continue
        out.add(d)
    return sorted(out)


def build_payload(
    accounts: int | None,
    has_fetched: bool | None,
    install_ts: int,
    existing: dict[str, Any],
    imessage_fda_needed: bool | None = None,
    enrichment_decision: str | None = None,
    notes_has_fetched: bool | None = None,
    owner_mail_domains: list[str] | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "install_completed_ts": install_ts,
    }

    # Owner mail domains: None means the probe could not read the store, so the
    # prior value stands. A list (possibly empty) is a known answer.
    if owner_mail_domains is not None:
        payload["owner_mail_domains"] = list(owner_mail_domains)
    else:
        prior_domains = existing.get("owner_mail_domains")
        if isinstance(prior_domains, list):
            payload["owner_mail_domains"] = prior_domains

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

    # Background-enrichment consent decision (#794 / CM051 #889).
    #
    # ⚠️ WHY IT IS HERE AND NOT ONLY IN posture/. The authoritative consent
    # RECORD is ~/.ostler/posture/enrichment-decision.json, alongside the other
    # consent artefacts, and that is the right home for a support bundle.
    # But the wiki compiler runs in a container and reaches the host through
    # ONE bind-mount: ~/.ostler/state, the directory this sidecar lives in.
    # It cannot see posture/ at all. So the value is mirrored here, written
    # from the same shell variable on an adjacent line, for the CM044
    # settling panel to read. Two files, one source, no room to drift.
    if enrichment_decision is not None:
        payload["enrichment_decision"] = enrichment_decision
    else:
        prior_enrich = existing.get("enrichment_decision")
        if prior_enrich in VALID_ENRICHMENT_DECISIONS:
            payload["enrichment_decision"] = prior_enrich

    # Apple Notes half: explicit arg wins; otherwise preserve, so an
    # installer rewrite never drops what the hourly fda-rerun measured.
    if notes_has_fetched is not None:
        payload["notes_has_fetched"] = notes_has_fetched
        payload["notes_checked_ts"] = install_ts
    else:
        prior_notes = existing.get("notes_has_fetched")
        if isinstance(prior_notes, bool):
            payload["notes_has_fetched"] = prior_notes
        prior_notes_ts = existing.get("notes_checked_ts")
        if isinstance(prior_notes_ts, int):
            payload["notes_checked_ts"] = prior_notes_ts

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
        "--enrichment-decision",
        default=None,
        choices=list(VALID_ENRICHMENT_DECISIONS),
        help=(
            "The customer's background-enrichment consent answer. Mirrored "
            "here from posture/enrichment-decision.json because the wiki "
            "compiler can only reach ~/.ostler/state. Omit to preserve."
        ),
    )
    parser.add_argument(
        "--notes-has-fetched",
        default=None,
        help=(
            '"true" or "false" -- does the Apple Notes store hold any note '
            "rows? Omit to preserve."
        ),
    )
    parser.add_argument(
        "--install-ts",
        default="",
        help="Override install timestamp (epoch seconds). Defaults to now.",
    )
    parser.add_argument(
        "--owner-mail-domains",
        default=None,
        help=(
            "Comma list of the owner's own mail account DOMAINS (never addresses). "
            "'' means none; '__unknown__' means the store could not be read and "
            "the prior value stands. Omit to preserve."
        ),
    )
    args = parser.parse_args(argv)

    owner_domains: list[str] | None = None
    if args.owner_mail_domains is not None and args.owner_mail_domains != UNKNOWN_SENTINEL:
        try:
            owner_domains = normalise_owner_mail_domains(args.owner_mail_domains)
        except ValueError as exc:
            print(f"write_pipeline_signals: {exc}", file=sys.stderr)
            return 2

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

    notes_has_fetched: bool | None = None
    if args.notes_has_fetched is not None:
        raw = args.notes_has_fetched.strip().lower()
        if raw not in ("true", "false"):
            print(
                f"write_pipeline_signals: --notes-has-fetched must be "
                f"'true' or 'false', got {args.notes_has_fetched!r}",
                file=sys.stderr,
            )
            return 2
        notes_has_fetched = raw == "true"

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
        enrichment_decision=args.enrichment_decision,
        notes_has_fetched=notes_has_fetched,
        owner_mail_domains=owner_domains,
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
