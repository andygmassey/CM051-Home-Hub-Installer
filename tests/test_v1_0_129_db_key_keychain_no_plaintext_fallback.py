#!/usr/bin/env python3
"""v1.0.129 hardening: the DB key is not a plaintext file, and no database
silently opens plaintext when the key is missing.

Four changes, each measured at the consumer, each with a matched control:

  K  KEY IN THE KEYCHAIN. A key file is migrated into the login Keychain and
     deleted. Measured by an INDEPENDENT reader (`security find-generic-password`
     run by this test, not by the resolver) and by scanning the security folder
     for the key's bytes. Control: legacy file-only mode leaves the file and
     the scan finds it, so the scan can see a key.
     An unreadable Keychain must NOT fall through to the file or to nothing:
     the resolver returns keychain_unavailable and leaves the file alone.
  R  NO SILENT PLAINTEXT. With no key, ical-server's corrections and
     assert-spool opens must raise and must not create a file.
  A  KEYED audit.db. With no key the default audit log is not created at all;
     with a key the file has no SQLite magic (needs sqlcipher3); an old
     plaintext audit.db is re-keyed in place (needs sqlcipher3).
  C  COPY. The passphrase prompt copy makes no claim the product cannot keep.
  I  INSTALLER WIRING. The installer passes the key to the audit log, moves
     the file key into the Keychain, and no longer sets OSTLER_DB_KEY_FILE in
     the ical-server plist (an explicit file path switches the resolver to
     file-only and the services would never read the Keychain).

Keychain isolation: every Keychain arm uses OSTLER_DB_KEY_KEYCHAIN_SERVICE with
a unique service name and deletes it afterwards. The real item
("Ostler DB Key") is never read, written or deleted.

Exit codes: 0 all arms held, 1 an arm failed, 2 CANNOT-RUN (an arm could not
obtain a verdict; nothing is claimed for it).
"""
from __future__ import annotations

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SQLITE_MAGIC = b"SQLite format 3\x00"
KEY = "3f" * 32
FAILURES: list[str] = []
SKIPPED: list[str] = []


def check(cond: bool, label: str) -> None:
    if cond:
        print(f"  [PASS] {label}")
    else:
        FAILURES.append(label)
        print(f"  [FAIL] {label}", file=sys.stderr)


def skip(label: str, why: str) -> None:
    SKIPPED.append(f"{label}: {why}")
    print(f"  [CANNOT-RUN] {label} ({why})", file=sys.stderr)


ROOT = Path(__file__).resolve().parent.parent


def tree_contains(root: Path, needle: str) -> bool:
    for p in root.rglob("*"):
        if p.is_file() and needle.encode() in p.read_bytes():
            return True
    return False


def kc_read(service: str):
    """Independent reader: the macOS tool, not the resolver."""
    r = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", service,
         "-a", "ostler-db-key", "-w"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def kc_delete(service: str) -> None:
    subprocess.run(
        ["/usr/bin/security", "delete-generic-password", "-s", service,
         "-a", "ostler-db-key"], capture_output=True)


def secdir(base: Path, with_key: bool) -> Path:
    d = base / "security"
    d.mkdir(parents=True, exist_ok=True)
    d.chmod(0o700)
    if with_key:
        f = d / "db_key"
        f.write_text(KEY + "\n")
        f.chmod(0o600)
    return d


def fake_security(path: Path, rc: int) -> str:
    path.write_text(f"#!/bin/sh\nexit {rc}\n")
    path.chmod(0o755)
    return str(path)


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix="ostler-h129-"))
    sec_site = work / "site"
    shutil.copytree(ROOT / "vendor" / "ostler_security",
                    sec_site / "ostler_security",
                    ignore=shutil.ignore_patterns("tests", "bin", "__pycache__"))
    sys.path.insert(0, str(sec_site))
    service = f"Ostler DB Key TEST h129 {os.getpid()}"
    try:
        for k in ("OSTLER_DB_KEY", "OSTLER_DB_KEY_FILE", "OSTLER_HOME",
                  "OSTLER_DB_KEY_KEYCHAIN_SERVICE"):
            os.environ.pop(k, None)
        try:
            from ostler_security import db_key
        except ImportError as exc:
            print(f"CANNOT-RUN: ostler_security not importable ({exc})", file=sys.stderr)
            return 2
        have_kc = hasattr(db_key, "keychain_available") and db_key.keychain_available()

        # ---- K: key in the Keychain -------------------------------------
        print("K. DB key in the Keychain")
        h = work / "k1"
        d = secdir(h, True)
        os.environ["OSTLER_DB_KEY_FILE"] = str(d / "db_key")
        # Control: legacy file-only mode leaves the file, and the scan sees it.
        legacy = db_key.resolve_db_key()
        check(legacy.key == KEY and (d / "db_key").exists() and tree_contains(d, KEY),
              "K control: file-only mode keeps the plaintext key file and the scan finds it")
        if not have_kc or not hasattr(db_key, "migrate_key_file_to_keychain"):
            check(False, "K1: resolver has Keychain support (migrate_key_file_to_keychain)")
        else:
            os.environ["OSTLER_DB_KEY_KEYCHAIN_SERVICE"] = service
            kc_delete(service)
            r1 = db_key.resolve_db_key()
            check(r1.key == KEY and r1.source == "keychain",
                  f"K1: resolver returns the key from the Keychain (source={r1.source!r})")
            check(not (d / "db_key").exists(), "K1: the plaintext key file is deleted after the move")
            check(not tree_contains(d, KEY), "K1: the key's bytes are nowhere in the security folder")
            check(kc_read(service) == KEY, "K1: an independent `security` read returns the key")
            r2 = db_key.resolve_db_key()
            check(r2.key == KEY and r2.source == "keychain",
                  "K2: with no file at all, the reader still gets the key (from the Keychain)")
            # leftover file next to an existing item is removed
            (d / "db_key").write_text(KEY + "\n")
            (d / "db_key").chmod(0o600)
            db_key.resolve_db_key()
            check(not (d / "db_key").exists(), "K3: a leftover key file beside a Keychain item is removed")
            # unreadable Keychain: do not guess, do not touch the file
            (d / "db_key").write_text(KEY + "\n")
            (d / "db_key").chmod(0o600)
            real = db_key._SECURITY_BIN
            db_key._SECURITY_BIN = fake_security(work / "sec51", 51)
            ru = db_key.resolve_db_key()
            check(ru.key is None and ru.reason == db_key.REASON_KEYCHAIN_UNAVAILABLE,
                  f"K4: unreadable Keychain -> no key, reason keychain_unavailable (got {ru.reason!r})")
            check((d / "db_key").exists(), "K4: ...and the key file is left exactly as it was")
            db_key._SECURITY_BIN = real
            kc_delete(service)
            os.environ.pop("OSTLER_DB_KEY_KEYCHAIN_SERVICE", None)
            # safety: the real item was never ours to touch
            check(db_key.keychain_service() == "Ostler DB Key",
                  "K5: default service name is 'Ostler DB Key'")
            check(not db_key.keychain_enabled(),
                  "K5: explicit OSTLER_DB_KEY_FILE keeps file-only mode (no Keychain access from tests)")
        os.environ.pop("OSTLER_DB_KEY_FILE", None)
        os.environ.pop("OSTLER_DB_KEY_KEYCHAIN_SERVICE", None)

        # ---- R: no silent plaintext --------------------------------------
        print("R. corrections.db / assert_spool.db with no key")
        home = work / "r1"
        (home / "memory").mkdir(parents=True)
        os.environ["OSTLER_HOME"] = str(home)
        os.environ["OSTLER_DB_KEY_FILE"] = str(home / "nope" / "db_key")
        cm041 = ROOT / "vendor" / "cm041"
        sys.path.insert(0, str(cm041))
        spec = importlib.util.spec_from_file_location(
            "ical_server_h129", cm041 / "assistant_api" / "ical-server.py")
        ical = importlib.util.module_from_spec(spec)
        sys.modules["ical_server_h129"] = ical
        try:
            spec.loader.exec_module(ical)
        except Exception as exc:  # noqa: BLE001
            SKIPPED.append(f"R: ical-server would not import here ({exc.__class__.__name__}: {exc})")
            print(f"  [CANNOT-RUN] R ({exc.__class__.__name__}: {exc})", file=sys.stderr)
            ical = None
        if ical is not None:
            ical.MEMORY_CORRECTIONS_DB = home / "memory" / "corrections.db"
            ical.ASSERT_SPOOL_DB = home / "memory" / "assert_spool.db"
            for label, fn, path in (
                ("corrections.db", ical._memory_corrections_connect, ical.MEMORY_CORRECTIONS_DB),
                ("assert_spool.db", ical._assert_spool_connect, ical.ASSERT_SPOOL_DB),
            ):
                raised = False
                try:
                    c = fn()
                    c.close()
                except Exception:  # noqa: BLE001
                    raised = True
                check(raised, f"R: {label} open with no key is REFUSED")
                check(not path.exists(), f"R: {label} is not created plaintext on disk")
            # The explicit opt-in is the ONLY way back, and it is loud.
            os.environ["OSTLER_ALLOW_PLAINTEXT_DB"] = "1"
            try:
                c = ical._assert_spool_connect()
                c.close()
                check(ical.ASSERT_SPOOL_DB.exists(),
                      "R control: OSTLER_ALLOW_PLAINTEXT_DB=1 (explicit, logged) is the only plaintext path")
            except Exception as exc:  # noqa: BLE001
                check(False, f"R control: explicit opt-in should open ({exc})")
            os.environ.pop("OSTLER_ALLOW_PLAINTEXT_DB", None)
        os.environ.pop("OSTLER_HOME", None)
        os.environ.pop("OSTLER_DB_KEY_FILE", None)

        # ---- A: audit.db keyed --------------------------------------------
        print("A. audit.db keyed")
        from ostler_security import audit_log
        from ostler_security.database import HAS_SQLCIPHER
        os.environ["OSTLER_DB_KEY_FILE"] = str(work / "nope" / "db_key")
        audit_log._default_log = None
        p0 = work / "a0" / "audit.db"
        audit_log.log_event("unlock", "h129-test", db_path=p0)
        check(not p0.exists(), "A0: with no key the default audit log is NOT created (no plaintext audit.db)")
        os.environ.pop("OSTLER_DB_KEY_FILE", None)
        if not HAS_SQLCIPHER:
            skip("A1/A2", "sqlcipher3 not installed in this interpreter; keyed bytes not measurable here")
        else:
            audit_log._default_log = None
            p1 = work / "a1" / "audit.db"
            audit_log.log_event("unlock", "h129-test", db_path=p1, encryption_key_hex=KEY)
            audit_log._default_log = None
            check(p1.exists() and not p1.read_bytes().startswith(SQLITE_MAGIC),
                  "A1: audit.db created with a key has no SQLite magic header")
            ctl = work / "a1c" / "audit.db"
            ctl.parent.mkdir()
            audit_log.AuditLog(ctl)
            check(ctl.read_bytes().startswith(SQLITE_MAGIC),
                  "A1 control: an unkeyed AuditLog does start with the SQLite magic")
            p2 = work / "a2" / "audit.db"
            p2.parent.mkdir()
            old = audit_log.AuditLog(p2)
            old.log("unlock", "before-upgrade")
            check(p2.read_bytes().startswith(SQLITE_MAGIC), "A2 setup: legacy audit.db is plaintext")
            audit_log.AuditLog(p2, KEY).log("unlock", "after-upgrade")
            check(not p2.read_bytes().startswith(SQLITE_MAGIC), "A2: a legacy plaintext audit.db is re-keyed in place")
            check(b"before-upgrade" not in p2.read_bytes(), "A2: the old rows are not readable in the raw file")

        # ---- C: copy --------------------------------------------------------
        print("C. passphrase prompt copy")
        bad = ("encrypts your knowledge graph", "each time you start the Hub UI",
               "unlocks the Hub UI", "Databases encrypted")
        approved = ("Ostler uses this passphrase to set up the key for some of its internal records. "
                    "Your Ostler data as a whole is protected by FileVault, Apple's full-disk encryption.")
        files = sorted(ROOT.glob("install.sh.strings.*.sh"))
        en = (ROOT / "install.sh.strings.en-GB.sh").read_text()
        check(approved in en, "C1: the approved passphrase string is the CLI-path help text")
        check(not any(b in f.read_text() for f in files for b in bad[:3]),
              "C2: no installer string says the passphrase encrypts the graph or is typed at each start")
        vc = [f for f in sorted((ROOT / "gui/OstlerInstaller/Resources").glob("ViewCopy*.json"))]
        sql = [f.name for f in vc if "You will type this passphrase" in f.read_text()
               or "SQLCipher using a passphrase" in f.read_text()]
        check(not sql, f"C3: ViewCopy ack screens no longer promise a passphrase at each start ({sql})")

        # ---- I: installer wiring ---------------------------------------------
        print("I. installer wiring")
        inst = (ROOT / "install.sh").read_text()
        check("encryption_key_hex=_dek.hex()" in inst, "I1: installer creates audit.db with the DEK")
        check("migrate_key_file_to_keychain" in inst, "I2: installer moves the key file into the Keychain")
        plist = inst[inst.index("ICALPLISTEOF"):]
        plist = plist[:plist.index("\nICALPLISTEOF", 10)] if "\nICALPLISTEOF" in plist[10:] else plist
        check("<key>OSTLER_DB_KEY_FILE</key>" not in plist,
              "I3: the ical-server plist does not set OSTLER_DB_KEY_FILE (would force file-only mode)")
    finally:
        kc_delete(service)
        shutil.rmtree(work, ignore_errors=True)

    print("")
    if FAILURES:
        print(f"FAIL: {len(FAILURES)} arm(s) failed", file=sys.stderr)
        for f in FAILURES:
            print(f"  - {f}", file=sys.stderr)
        return 1
    if SKIPPED:
        print("CANNOT-RUN for: " + "; ".join(SKIPPED), file=sys.stderr)
        print("  Arms that did run all held. The rest are NOT passed.", file=sys.stderr)
        return 2
    print("all arms held")
    return 0


if __name__ == "__main__":
    sys.exit(main())
