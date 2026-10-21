"""``ostler-slack-import``: the owner-initiated Slack importer.

Default-off: nothing in the installer, a LaunchAgent or the Doctor invokes
this (UNWIRED). The owner runs it, or a future wiring PR does.

    ostler-slack-import export <zip-or-folder> [--json] [--dry-run]
    ostler-slack-import token-set            # token read from stdin, never argv
    ostler-slack-import sync [--team T...] [--rescan-days 7] [--json] [--dry-run]

Exit codes:
    0  ran; every conversation recorded or unchanged (0 found is a true 0)
    1  ran; at least one conversation failed or was paused (retried next
       run), or an export day file was unreadable (skipped and counted in
       ``bad_day_files``; the rest of the export was imported)
    2  configuration: CM052_USER_EMAIL unset, no token stored, bad token, or
       the export route cannot tell which account is the owner's (it
       refuses rather than import the owner as a contact)
    3  CANNOT-RUN: export unreadable, Slack auth/scope error, rate limit
       exhausted. Never reported as a pass.
    5  PAUSED, NOT PRO (``first_import.EXIT_PAUSED_NOT_PRO``, the shared
       contract): Andy's refusal text is printed. Nothing is read or posted;
       conversations already imported are untouched and stay readable.
       (3 is also used when the free-import ledger cannot be read: "Try
       again", never a refusal.)

Pro gate (``first_import.entry_gate``, at the entry point, before any export
is opened or any Slack call is made): the FIRST export import is free
without Pro (Andy, 19 Oct) and is recorded only once it lands; re-imports
and ``sync`` need Pro. ``token-set`` is not gated: storing a token reads and
posts nothing.

``--json`` prints one counts-only line (no names, no text, no ids).
"""
from __future__ import annotations

import argparse
import getpass
import json
import logging
import os
import sys
from pathlib import Path

from .. import first_import, wire
from . import importer, keychain
from .api import SlackApiError, SlackClient, SlackRateLimited
from .export_zip import ExportError

log = logging.getLogger("cm052.slack")


def _emit(args, counts: dict) -> None:
    if args.json:
        print(json.dumps(counts, sort_keys=True))
    else:
        print(
            f"conversations={counts.get('conversations', 0)} "
            f"posted={counts.get('posted', 0)} unchanged={counts.get('unchanged', 0)} "
            f"l3_files_only={counts.get('l3_files_only', 0)} failed={counts.get('failed', 0)} "
            f"paused={counts.get('paused', 0)}"
            + (f" bad_day_files={counts['bad_day_files']}" if counts.get("bad_day_files") else "")
        )


def _cannot_run(args, reason: str) -> int:
    log.error("CANNOT-RUN: %s", reason)
    if args.json:
        print(json.dumps({"status": "cannot_run", "reason": reason}))
    return 3


SOURCE_LABEL = "Slack"
EXPORT_SOURCE = "slack_export"   # the one-off free import is per source
API_SOURCE = "slack_api"         # token sync: always Pro


def _gate(args, *, export_import: bool):
    """The entry gate, before anything is read. Returns (decision, rc):
    rc is None when the run may go ahead."""
    decision = first_import.entry_gate(
        EXPORT_SOURCE if export_import else API_SOURCE, export_import=export_import,
    )
    if decision.allowed:
        if decision.is_free_import:
            # Andy: said before the first import, so it is never a surprise.
            print(first_import.pre_import_notice(SOURCE_LABEL), file=sys.stderr)
        return decision, None
    if decision.reason == "could_not_check":
        print(first_import.COULD_NOT_CHECK_TEXT, file=sys.stderr)
        if args.json:
            print(json.dumps({"status": "cannot_run", "reason": "could_not_check"}))
        return decision, first_import.EXIT_COULD_NOT_CHECK
    print(first_import.refusal_text(SOURCE_LABEL), file=sys.stderr)
    if args.json:
        print(json.dumps({"status": "paused_not_pro", "reason": "pro_required"}))
    return decision, first_import.EXIT_PAUSED_NOT_PRO


def _rc(counts: dict) -> int:
    # A skipped bad day file is data the owner did not get: ran, but not clean.
    return 1 if counts.get("failed") or counts.get("paused") or counts.get("bad_day_files") else 0


def cmd_export(args) -> int:
    decision, rc = _gate(args, export_import=True)
    if rc is not None:
        return rc
    post_fn = (
        (lambda conv: wire.post(conv, free_import=True))
        if decision.is_free_import else wire.post
    )
    state_file = importer.state_path()
    state = importer.load_state(state_file)
    try:
        counts = importer.import_export(
            Path(args.path), self_email=os.environ.get("CM052_USER_EMAIL"),
            state=state, dry_run=args.dry_run, post_fn=post_fn,
            self_user_id=args.self_user_id, extra_emails=args.self_email or [],
        )
    except ExportError as exc:
        return _cannot_run(args, str(exc))
    except importer.OwnerUnknown as exc:
        # Refuse rather than import the owner as a stranger. Nothing posted.
        print(
            f"Couldn't tell which Slack account is yours ({exc}). Nothing was "
            "imported. Run again with --self-email <the email you use in "
            "Slack>, or --self-user-id <your Slack member ID, from your Slack "
            "profile>.",
            file=sys.stderr,
        )
        if args.json:
            print(json.dumps({"status": "config", "reason": "owner_unknown"}))
        return 2
    if not args.dry_run:
        importer.save_state(state_file, state)
        # The taster is used only by an import that actually landed: a run
        # where something failed or paused keeps it for the retry.
        if decision.is_free_import and not counts.get("failed") and not counts.get("paused"):
            first_import.mark_first_import(EXPORT_SOURCE)
    _emit(args, counts)
    return _rc(counts)


def _read_token() -> str:
    if sys.stdin.isatty():
        return getpass.getpass("Paste your Slack user token (starts xoxp-): ").strip()
    return sys.stdin.readline().strip()


def cmd_token_set(args) -> int:
    token = _read_token()
    if not keychain.valid_token(token):
        log.error("That does not look like a Slack user token (expected xoxp-...).")
        return 2
    client = SlackClient(token, pace_secs=0)
    try:
        me = client.auth_test()
    except (SlackApiError, SlackRateLimited) as exc:
        return _cannot_run(args, str(exc))
    finally:
        client.close()
    team = str(me.get("team_id") or "")
    try:
        keychain.store_token(team, token)
    except keychain.SecretStoreError as exc:
        log.error("%s", exc)
        return 2
    state_file = importer.state_path()
    state = importer.load_state(state_file)
    state["workspaces"][team] = {"team": me.get("team"), "user_id": me.get("user_id")}
    importer.save_state(state_file, state)
    print(f"Saved to Keychain for workspace {me.get('team') or team}.")
    return 0


def cmd_sync(args) -> int:
    _decision, rc = _gate(args, export_import=False)
    if rc is not None:
        return rc
    state_file = importer.state_path()
    state = importer.load_state(state_file)
    teams = args.team or sorted(state["workspaces"])
    if not teams:
        log.error("No Slack workspace connected. Run: ostler-slack-import token-set")
        return 2
    total = importer.new_counts()
    per_team = {}
    rc = 0
    for team in teams:
        token = keychain.load_token(team)
        if not token:
            log.error("No token in Keychain for one connected workspace.")
            return 2
        client = SlackClient(token)
        try:
            counts = importer.sync_api(
                client, state=state, rescan_days=args.rescan_days, dry_run=args.dry_run,
                save=lambda s: importer.save_state(state_file, s),
            )
        except SlackRateLimited as exc:
            return _cannot_run(args, str(exc))
        except SlackApiError as exc:
            return _cannot_run(args, str(exc))
        finally:
            client.close()
        per_team[team] = counts
        for k in total:
            total[k] += counts.get(k, 0)
        rc = max(rc, _rc(counts))
    if not args.dry_run:
        importer.save_state(state_file, state)
    total["workspaces"] = len(per_team)
    total["route"] = "api"
    _emit(args, total)
    return rc


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="ostler-slack-import", description="Import your own Slack history into Ostler, on this Mac.")
    p.add_argument("-v", "--verbose", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export", help="Import a workspace export ZIP (or its unpacked folder).")
    e.add_argument("path")
    e.add_argument("--self-email", action="append", help="Your email in this Slack workspace, if it is not CM052_USER_EMAIL (repeatable).")
    e.add_argument("--self-user-id", help="Your Slack member ID (U...), when the export hides emails.")
    e.add_argument("--json", action="store_true")
    e.add_argument("--dry-run", action="store_true")
    e.set_defaults(fn=cmd_export)
    t = sub.add_parser("token-set", help="Store your own Slack app's user token in the Keychain (read from stdin).")
    t.add_argument("--json", action="store_true")
    t.set_defaults(fn=cmd_token_set)
    s = sub.add_parser("sync", help="Backfill, then incrementally sync, with your stored token.")
    s.add_argument("--team", action="append")
    s.add_argument("--rescan-days", type=int, default=7)
    s.add_argument("--json", action="store_true")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_sync)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr,
    )
    if args.cmd != "token-set" and not os.environ.get("CM052_USER_EMAIL"):
        log.error("CM052_USER_EMAIL is not set; the wire needs it.")
        return 2
    return args.fn(args)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
