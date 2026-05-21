"""Migrate Keychain items from the legacy ``ai.creativemachines.lifeline``
service identifier to the new ``ai.creativemachines.ostler`` identifier.

Background
----------

Ostler's Swift helper writes wrapped DEKs (and recovery DEKs) to the
macOS Keychain under ``service = ai.creativemachines.lifeline``. The
service string is the primary key Apple's Keychain uses to look items
up. Renaming the constant in code without first migrating data leaves
every existing install permanently locked – the user's Touch ID can
still answer the PRF challenge but the wrapped DEK is invisible to
the new code path.

This CLI does the data half of the rename: drains every item under
the old service ID, copies it to the new service ID with the same
account name, verifies the round trip, then deletes the source. The
constant flip in ``keychain.py`` happens *after* this CLI reports
green – see ``flip_constants.py`` for that step.

Safety contract
---------------

* Default mode is ``--dry-run``. Without flags this CLI enumerates
  what it would do and exits with code 0. Nothing destructive runs
  unless ``--execute`` is passed.
* ``--execute`` is idempotent. Running it twice is a no-op the
  second time: items already at the new service ID with the same
  payload are skipped.
* Round-trip verification is mandatory. Each item is read back from
  the new service ID and byte-compared to the source value before
  the source is deleted.
* ``--rollback`` reverses the migration (writes old-service items
  back from the new-service copies). Survives until the user runs
  the constants flip.
* Every operation is logged with timestamps to
  ``~/.ostler/security/keychain_migration.log``.

Usage
-----

::

    ostler-migrate-keychain --dry-run     # default: enumerate
    ostler-migrate-keychain --execute     # actually migrate
    ostler-migrate-keychain --verify      # round-trip check
    ostler-migrate-keychain --rollback    # reverse

Item discovery
--------------

The Swift helper exposes ``keychain_get`` / ``keychain_set`` /
``keychain_exists`` / ``keychain_delete`` but no enumeration
primitive. Item discovery therefore probes the well-known account
templates from ``ostler_security.keychain``:

* ``wrapped_dek:<thread_id>``
* ``wrapped_recovery:<thread_id>``

In v1 the only valid thread_id is ``"default"``. The CLI accepts
``--thread-id`` (repeatable) so future multi-thread installs can
migrate cleanly.

Exit codes
----------

::

    0   Success (or dry-run completed cleanly)
    1   At least one item failed migration / verification
    2   Bad arguments / mutually exclusive flags
    3   Unexpected internal failure
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sys
from pathlib import Path
from typing import Iterable, Optional, TextIO

from ostler_security import keychain as _kc


# ── Constants ────────────────────────────────────────────────────────

OLD_SERVICE = "ai.creativemachines.lifeline"
NEW_SERVICE = "ai.creativemachines.ostler"

DEFAULT_LOG_PATH = Path.home() / ".ostler" / "security" / "keychain_migration.log"


# Exit codes
EXIT_OK = 0
EXIT_PARTIAL_FAILURE = 1
EXIT_BAD_ARGS = 2
EXIT_INTERNAL = 3


# ── Logging ──────────────────────────────────────────────────────────


def _now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat()


class MigrationLogger:
    """Append-only log of every migration operation.

    Writes JSON lines. Each entry carries timestamp, op, account,
    services involved, and outcome. Used both for live runs and
    after-the-fact audit when something goes wrong.

    The log file is created with mode 0600 and its parent dir with
    0700 – Keychain account names are not secrets but knowing they
    exist is a fingerprint, and the log lives in the same security
    dir as other sensitive metadata.
    """

    def __init__(self, log_path: Path):
        self.log_path = log_path
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        # 0700 dir, 0600 file – consistent with passphrase.py layout.
        try:
            self.log_path.parent.chmod(0o700)
        except OSError:
            # Don't fail the migration just because chmod errored
            # on a network home dir. The log content itself isn't
            # secret – it's audit trail.
            pass
        if not self.log_path.exists():
            self.log_path.touch(mode=0o600)
        else:
            try:
                self.log_path.chmod(0o600)
            except OSError:
                pass

    def log(self, **fields) -> None:
        record = {"ts": _now_iso(), **fields}
        with self.log_path.open("a", encoding="utf-8") as fp:
            fp.write(json.dumps(record, sort_keys=True) + "\n")


# ── Item discovery ───────────────────────────────────────────────────


def candidate_accounts(thread_ids: Iterable[str]) -> list[str]:
    """Return the list of well-known account names for the given
    thread IDs.

    The legacy code paths only ever use ``account_wrapped_dek`` and
    ``account_wrapped_recovery``. If new account templates appear
    in ``keychain.py``, this function must be updated in lockstep.
    """
    accounts: list[str] = []
    for thread_id in thread_ids:
        accounts.append(_kc.account_wrapped_dek(thread_id))
        accounts.append(_kc.account_wrapped_recovery(thread_id))
    return accounts


# ── Per-item operations ──────────────────────────────────────────────


def _read_item(service: str, account: str) -> Optional[bytes]:
    """Read a Keychain item. Returns bytes or None if not found.

    Distinguishes "absent" from "denied" by error code – callers
    that need to know the difference should use the lower-level
    keychain.get_item directly.
    """
    result = _kc.get_item(service=service, account=account)
    if result.ok:
        return result.value
    if result.error_code == "KEYCHAIN_NOT_FOUND":
        return None
    # Anything else – KEYCHAIN_DENIED, INTERNAL – is a hard error.
    # Bubble up via exception so callers can log and continue.
    raise RuntimeError(
        f"Keychain read failed: service={service!r} account={account!r} "
        f"code={result.error_code} message={result.message}"
    )


def _write_item(service: str, account: str, value: bytes) -> None:
    result = _kc.set_item(service=service, account=account, value=value)
    if not result.ok:
        raise RuntimeError(
            f"Keychain write failed: service={service!r} account={account!r} "
            f"code={result.error_code} message={result.message}"
        )


def _delete_item(service: str, account: str) -> bool:
    """Returns True if an item was deleted, False if it wasn't there."""
    result = _kc.delete_item(service=service, account=account)
    if not result.ok:
        raise RuntimeError(
            f"Keychain delete failed: service={service!r} account={account!r} "
            f"code={result.error_code} message={result.message}"
        )
    return bool(result.deleted)


# ── Migration core ───────────────────────────────────────────────────


def plan_migration(
    accounts: Iterable[str],
    *,
    old_service: str = OLD_SERVICE,
    new_service: str = NEW_SERVICE,
) -> list[dict]:
    """Enumerate what would happen for each candidate account.

    Returns a list of dicts with keys::

        account     – the account name
        status      – "would_migrate" | "already_migrated" | "absent"
                      | "conflict" | "error"
        message     – human-readable detail for "conflict" / "error"

    "conflict" means the account exists at *both* services with
    *different* values. That's an integrity error: someone has
    written to the new service ID without coming through this
    migration. ``--execute`` refuses to clobber.
    """
    plan: list[dict] = []
    for account in accounts:
        try:
            old_value = _read_item(old_service, account)
        except RuntimeError as exc:
            plan.append({
                "account": account,
                "status": "error",
                "message": f"reading old: {exc}",
            })
            continue

        try:
            new_value = _read_item(new_service, account)
        except RuntimeError as exc:
            plan.append({
                "account": account,
                "status": "error",
                "message": f"reading new: {exc}",
            })
            continue

        if old_value is None and new_value is None:
            plan.append({"account": account, "status": "absent"})
        elif old_value is None and new_value is not None:
            plan.append({"account": account, "status": "already_migrated"})
        elif old_value is not None and new_value is None:
            plan.append({"account": account, "status": "would_migrate"})
        else:
            # Both exist – compare values. Equal = idempotent re-run
            # finishing the source-delete step. Unequal = conflict.
            if old_value == new_value:
                plan.append({
                    "account": account,
                    "status": "would_finalise",
                    "message": "both copies present and identical; "
                               "execute will delete old",
                })
            else:
                plan.append({
                    "account": account,
                    "status": "conflict",
                    "message": "different values at old and new "
                               "service IDs; refusing to clobber",
                })
    return plan


def execute_migration(
    accounts: Iterable[str],
    *,
    logger: MigrationLogger,
    old_service: str = OLD_SERVICE,
    new_service: str = NEW_SERVICE,
    out: TextIO = sys.stdout,
) -> tuple[int, int, int]:
    """Run the actual migration. Idempotent.

    Returns a (migrated, skipped, errored) tuple. Caller decides
    the exit code.

    Per-item flow::

        1. read old; if absent and new present → already done, skip
        2. read new; if equal to old → delete old (finalise) and skip
        3. read new; if differs from old → conflict, ABORT this item
        4. write old → new service
        5. read new back; assert byte-equal to old
        6. delete old service item
    """
    migrated = 0
    skipped = 0
    errored = 0

    for account in accounts:
        try:
            old_value = _read_item(old_service, account)
            new_value = _read_item(new_service, account)
        except RuntimeError as exc:
            errored += 1
            logger.log(op="execute", account=account, outcome="read_error",
                       error=str(exc))
            print(f"  [ERR ] {account}: {exc}", file=out)
            continue

        # Case 1: nothing to do.
        if old_value is None and new_value is None:
            skipped += 1
            logger.log(op="execute", account=account, outcome="absent")
            print(f"  [skip] {account}: not present at either service", file=out)
            continue

        # Case 2: already migrated.
        if old_value is None and new_value is not None:
            skipped += 1
            logger.log(op="execute", account=account, outcome="already_migrated")
            print(f"  [skip] {account}: already on new service", file=out)
            continue

        # Case 3 / 4: both present. Equal → finalise. Unequal → conflict.
        if old_value is not None and new_value is not None:
            if old_value == new_value:
                # Idempotent finalise: delete the source.
                try:
                    _delete_item(old_service, account)
                except RuntimeError as exc:
                    errored += 1
                    logger.log(op="execute", account=account,
                               outcome="finalise_delete_failed", error=str(exc))
                    print(f"  [ERR ] {account}: delete-old failed: {exc}",
                          file=out)
                    continue
                migrated += 1
                logger.log(op="execute", account=account,
                           outcome="finalised")
                print(f"  [ok  ] {account}: finalised (deleted old copy)",
                      file=out)
                continue
            else:
                errored += 1
                logger.log(op="execute", account=account,
                           outcome="conflict",
                           old_size=len(old_value), new_size=len(new_value))
                print(f"  [ERR ] {account}: CONFLICT – different values at "
                      f"old and new services; refusing to clobber",
                      file=out)
                continue

        # Case 5: standard migration. old present, new absent.
        assert old_value is not None and new_value is None
        try:
            _write_item(new_service, account, old_value)
        except RuntimeError as exc:
            errored += 1
            logger.log(op="execute", account=account,
                       outcome="write_new_failed", error=str(exc))
            print(f"  [ERR ] {account}: write-new failed: {exc}", file=out)
            continue

        # Round-trip verify before deleting the source.
        try:
            roundtrip = _read_item(new_service, account)
        except RuntimeError as exc:
            errored += 1
            logger.log(op="execute", account=account,
                       outcome="verify_read_failed", error=str(exc))
            print(f"  [ERR ] {account}: verify read failed: {exc}", file=out)
            continue

        if roundtrip != old_value:
            errored += 1
            logger.log(op="execute", account=account,
                       outcome="verify_mismatch")
            print(f"  [ERR ] {account}: verify mismatch – DID NOT delete old",
                  file=out)
            continue

        try:
            _delete_item(old_service, account)
        except RuntimeError as exc:
            # Verified copy already at new service, but the old still
            # lingers. Mark as errored so the user re-runs and we
            # finish via the Case-3-equal branch above.
            errored += 1
            logger.log(op="execute", account=account,
                       outcome="delete_old_failed", error=str(exc))
            print(f"  [ERR ] {account}: copy ok but delete-old failed: {exc}",
                  file=out)
            continue

        migrated += 1
        logger.log(op="execute", account=account, outcome="migrated",
                   bytes=len(old_value))
        print(f"  [ok  ] {account}: migrated ({len(old_value)} bytes)",
              file=out)

    return migrated, skipped, errored


def verify_migration(
    accounts: Iterable[str],
    *,
    logger: MigrationLogger,
    old_service: str = OLD_SERVICE,
    new_service: str = NEW_SERVICE,
    out: TextIO = sys.stdout,
) -> tuple[int, int]:
    """Confirm round-trip on the new service for every account.

    Reads each account from the new service. Any error is reported.
    If the old service still has a value, that's an integrity warning
    (migration didn't finalise) but counts as a verify failure so
    Andy notices.

    Returns (verified_ok, failed).
    """
    verified = 0
    failed = 0
    for account in accounts:
        try:
            new_value = _read_item(new_service, account)
        except RuntimeError as exc:
            failed += 1
            logger.log(op="verify", account=account, outcome="read_error",
                       error=str(exc))
            print(f"  [ERR ] {account}: {exc}", file=out)
            continue

        try:
            old_value = _read_item(old_service, account)
        except RuntimeError as exc:
            # Don't flunk verify just because old lookup hiccupped –
            # but log it so Andy can investigate.
            logger.log(op="verify", account=account,
                       outcome="old_read_error", error=str(exc))
            old_value = None

        if new_value is None and old_value is None:
            # Nothing to verify; treat as benign.
            logger.log(op="verify", account=account, outcome="absent")
            print(f"  [skip] {account}: not present", file=out)
            continue

        if new_value is None and old_value is not None:
            failed += 1
            logger.log(op="verify", account=account,
                       outcome="missing_on_new")
            print(f"  [ERR ] {account}: present on OLD but missing on NEW",
                  file=out)
            continue

        if old_value is not None:
            failed += 1
            logger.log(op="verify", account=account,
                       outcome="old_still_present")
            print(f"  [WARN] {account}: old copy still present – run "
                  f"--execute again to finalise", file=out)
            continue

        # new_value present, old absent – healthy state.
        verified += 1
        logger.log(op="verify", account=account, outcome="ok",
                   bytes=len(new_value))
        print(f"  [ok  ] {account}: verified ({len(new_value)} bytes)",
              file=out)

    return verified, failed


def rollback_migration(
    accounts: Iterable[str],
    *,
    logger: MigrationLogger,
    old_service: str = OLD_SERVICE,
    new_service: str = NEW_SERVICE,
    out: TextIO = sys.stdout,
) -> tuple[int, int, int]:
    """Reverse the migration. Writes new-service values back to the
    old service ID and deletes the new copies after round-trip
    verify.

    Returns (rolled_back, skipped, errored).

    Useful only until the constants flip in ``keychain.py`` lands.
    Once the code reads from ``ai.creativemachines.ostler``, rolling
    back means re-locking the user out via the next code path that
    runs.
    """
    rolled_back = 0
    skipped = 0
    errored = 0

    for account in accounts:
        try:
            new_value = _read_item(new_service, account)
            old_value = _read_item(old_service, account)
        except RuntimeError as exc:
            errored += 1
            logger.log(op="rollback", account=account, outcome="read_error",
                       error=str(exc))
            print(f"  [ERR ] {account}: {exc}", file=out)
            continue

        if new_value is None:
            # Nothing to roll back from.
            skipped += 1
            logger.log(op="rollback", account=account, outcome="absent_on_new")
            print(f"  [skip] {account}: not present on new service", file=out)
            continue

        if old_value is not None:
            if old_value == new_value:
                # Both equal – just delete the new copy.
                try:
                    _delete_item(new_service, account)
                except RuntimeError as exc:
                    errored += 1
                    logger.log(op="rollback", account=account,
                               outcome="delete_new_failed", error=str(exc))
                    print(f"  [ERR ] {account}: delete-new failed: {exc}",
                          file=out)
                    continue
                rolled_back += 1
                logger.log(op="rollback", account=account,
                           outcome="rolled_back_finalise")
                print(f"  [ok  ] {account}: rolled back (deleted new copy)",
                      file=out)
                continue
            else:
                errored += 1
                logger.log(op="rollback", account=account,
                           outcome="conflict")
                print(f"  [ERR ] {account}: CONFLICT – different values; "
                      f"refusing to clobber old", file=out)
                continue

        # Standard rollback: write new back to old, verify, delete new.
        try:
            _write_item(old_service, account, new_value)
        except RuntimeError as exc:
            errored += 1
            logger.log(op="rollback", account=account,
                       outcome="write_old_failed", error=str(exc))
            print(f"  [ERR ] {account}: write-old failed: {exc}", file=out)
            continue

        try:
            roundtrip = _read_item(old_service, account)
        except RuntimeError as exc:
            errored += 1
            logger.log(op="rollback", account=account,
                       outcome="verify_read_failed", error=str(exc))
            print(f"  [ERR ] {account}: verify read failed: {exc}", file=out)
            continue

        if roundtrip != new_value:
            errored += 1
            logger.log(op="rollback", account=account,
                       outcome="verify_mismatch")
            print(f"  [ERR ] {account}: verify mismatch – DID NOT delete new",
                  file=out)
            continue

        try:
            _delete_item(new_service, account)
        except RuntimeError as exc:
            errored += 1
            logger.log(op="rollback", account=account,
                       outcome="delete_new_failed", error=str(exc))
            print(f"  [ERR ] {account}: copy ok but delete-new failed: {exc}",
                  file=out)
            continue

        rolled_back += 1
        logger.log(op="rollback", account=account, outcome="rolled_back",
                   bytes=len(new_value))
        print(f"  [ok  ] {account}: rolled back ({len(new_value)} bytes)",
              file=out)

    return rolled_back, skipped, errored


# ── CLI ──────────────────────────────────────────────────────────────


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ostler-migrate-keychain",
        description=(
            "Migrate Ostler Keychain items from the legacy "
            f"{OLD_SERVICE!r} service to {NEW_SERVICE!r}. "
            "Defaults to dry-run; pass --execute to perform "
            "destructive operations."
        ),
    )
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true",
                      help="(default) enumerate items and show what would "
                           "migrate. No writes.")
    mode.add_argument("--execute", action="store_true",
                      help="Actually migrate. Idempotent.")
    mode.add_argument("--verify", action="store_true",
                      help="Confirm round-trip on the new service ID after "
                           "a previous --execute.")
    mode.add_argument("--rollback", action="store_true",
                      help="Reverse the migration. Useful only before the "
                           "source constant is flipped in keychain.py.")

    p.add_argument(
        "--thread-id", action="append", default=None,
        help="Thread ID(s) to migrate. Repeatable. Default: 'default'.",
    )
    p.add_argument(
        "--old-service", default=OLD_SERVICE,
        help=argparse.SUPPRESS,  # Test-only override; normal users never set it.
    )
    p.add_argument(
        "--new-service", default=NEW_SERVICE,
        help=argparse.SUPPRESS,  # Test-only override.
    )
    p.add_argument(
        "--log-path", type=Path, default=None,
        help=f"Path to migration log (default: {DEFAULT_LOG_PATH}).",
    )
    return p


def main(argv: Optional[list[str]] = None,
         out: Optional[TextIO] = None,
         err: Optional[TextIO] = None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    parser = _build_parser()
    args = parser.parse_args(argv)

    thread_ids = args.thread_id or ["default"]
    accounts = candidate_accounts(thread_ids)

    log_path = args.log_path or DEFAULT_LOG_PATH
    try:
        logger = MigrationLogger(log_path)
    except OSError as exc:
        print(f"ERROR: cannot write log to {log_path}: {exc}", file=err)
        return EXIT_INTERNAL

    # Determine mode. Default is dry-run when nothing is set.
    is_dry_run = args.dry_run or not (args.execute or args.verify or args.rollback)

    print(f"Ostler Keychain service migration", file=out)
    print(f"  old service:  {args.old_service}", file=out)
    print(f"  new service:  {args.new_service}", file=out)
    print(f"  thread ids:   {', '.join(thread_ids)}", file=out)
    print(f"  log:          {log_path}", file=out)
    print("-" * 60, file=out)

    if is_dry_run:
        print("Mode: DRY-RUN (no writes)", file=out)
        plan = plan_migration(accounts,
                              old_service=args.old_service,
                              new_service=args.new_service)
        for entry in plan:
            print(f"  [{entry['status']:>16s}] {entry['account']}", file=out)
            if entry.get("message"):
                print(f"    note: {entry['message']}", file=out)
            logger.log(op="dry_run", account=entry["account"],
                       outcome=entry["status"], message=entry.get("message"))

        n_conflicts = sum(1 for e in plan if e["status"] == "conflict")
        n_errors = sum(1 for e in plan if e["status"] == "error")
        n_would = sum(1 for e in plan
                      if e["status"] in ("would_migrate", "would_finalise"))
        print("-" * 60, file=out)
        print(f"  {n_would} would migrate, {n_conflicts} conflicts, "
              f"{n_errors} errors", file=out)
        if n_conflicts or n_errors:
            return EXIT_PARTIAL_FAILURE
        return EXIT_OK

    if args.execute:
        print("Mode: EXECUTE", file=out)
        migrated, skipped, errored = execute_migration(
            accounts, logger=logger,
            old_service=args.old_service,
            new_service=args.new_service, out=out,
        )
        print("-" * 60, file=out)
        print(f"  {migrated} migrated, {skipped} skipped, {errored} errored",
              file=out)
        if errored == 0:
            print("", file=out)
            print("Next steps:", file=out)
            print(f"  1. Run --verify to confirm all items round-trip on "
                  f"{args.new_service}.", file=out)
            print(f"  2. Once verified, flip the constant in "
                  f"ostler_security/keychain.py via "
                  f"`python -m ostler_security.flip_constants --execute`.",
                  file=out)
            print(f"  3. Re-run your security tests; "
                  f"test_keychain.py::test_service_constant will need its "
                  f"expected value updated to the new service ID.", file=out)
        return EXIT_OK if errored == 0 else EXIT_PARTIAL_FAILURE

    if args.verify:
        print("Mode: VERIFY", file=out)
        verified, failed = verify_migration(
            accounts, logger=logger,
            old_service=args.old_service,
            new_service=args.new_service, out=out,
        )
        print("-" * 60, file=out)
        print(f"  {verified} verified, {failed} failed", file=out)
        return EXIT_OK if failed == 0 else EXIT_PARTIAL_FAILURE

    if args.rollback:
        print("Mode: ROLLBACK", file=out)
        rolled_back, skipped, errored = rollback_migration(
            accounts, logger=logger,
            old_service=args.old_service,
            new_service=args.new_service, out=out,
        )
        print("-" * 60, file=out)
        print(f"  {rolled_back} rolled back, {skipped} skipped, "
              f"{errored} errored", file=out)
        return EXIT_OK if errored == 0 else EXIT_PARTIAL_FAILURE

    # Unreachable – argparse mutex group enforces one of the modes.
    return EXIT_BAD_ARGS  # pragma: no cover


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
