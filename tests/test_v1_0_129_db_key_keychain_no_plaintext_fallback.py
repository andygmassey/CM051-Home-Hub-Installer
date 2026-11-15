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

Keychain isolation: no arm touches the real login keychain, its items, the
default keychain or the search list. Hermetic arms (H) use a fake `security`
that records argv and need no keychain. Real-keychain arms (K) create a
throwaway keychain with `security create-keychain` (which adds it to the
search list, so they run ONLY on a disposable CI runner and are CANNOT-RUN
everywhere else), point the code at it with OSTLER_KEYCHAIN_PATH, delete it afterwards, and
assert the search list is unchanged. Every `security` call is given an
explicit keychain path.

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


def kc_read(service: str, kc: str):
    """Independent reader: the macOS tool, not the resolver. Explicit keychain."""
    r = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", service,
         "-a", "ostler-db-key", "-w", kc],
        capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return r.stdout.strip() if r.returncode == 0 else None


def search_list() -> str:
    """READ-ONLY snapshot of the user search list (never written by tests)."""
    r = subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user"],
                       capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return r.stdout


def throwaway_allowed() -> bool:
    """`security create-keychain` ADDS the new keychain to the user's search
    list, so it is only run where that list is disposable: a CI runner. There
    is NO local opt-in: on a developer Mac the real-keychain arms are
    CANNOT-RUN and the hermetic arms (fake `security`, no keychain at all)
    carry the argv/refusal assertions."""
    return os.environ.get("CI") == "true"


def secdir(base: Path, with_key: bool) -> Path:
    d = base / "security"
    d.mkdir(parents=True, exist_ok=True)
    d.chmod(0o700)
    if with_key:
        f = d / "db_key"
        f.write_text(KEY + "\n")
        f.chmod(0o600)
    return d


def fake_security(path: Path, rc: int, log: Path) -> str:
    """A stand-in `security` that records every argv (and stdin for -i) to
    `log` and exits `rc`. Used for the arms that must prove what the code
    asks `security` to do, without any keychain existing."""
    path.write_text(
        "#!/bin/sh\n"
        f'printf "ARGV %s\\n" "$*" >> "{log}"\n'
        f'if [ "$1" = "-i" ]; then while IFS= read -r l; do printf "STDIN %s\\n" "$l" >> "{log}"; done; fi\n'
        f"exit {rc}\n")
    path.chmod(0o755)
    return str(path)


def scan_python_security_calls(src: str, name: str):
    """Return (n_calls, violations) for every call whose argv list starts with
    the security binary. An argv element may only be a string constant or a
    call to keychain_service()/keychain_path()/str(), or the KEYCHAIN_ACCOUNT constant. A key-bearing name, an
    f-string, or an add-generic-password / `-w <value>` pair is a violation."""
    import ast
    tree = ast.parse(src)
    n, bad = 0, []
    def is_bin(e):
        return (isinstance(e, ast.Name) and e.id == "_SECURITY_BIN") or (
            isinstance(e, ast.Constant) and isinstance(e.value, str)
            and e.value.endswith("/security"))
    for node in ast.walk(tree):
        if not (isinstance(node, ast.List) and node.elts and is_bin(node.elts[0])):
            continue
        n += 1
        els = node.elts[1:]
        for i, e in enumerate(els):
            ok = isinstance(e, ast.Constant) or (
                isinstance(e, ast.Name) and e.id == "KEYCHAIN_ACCOUNT") or (
                isinstance(e, ast.Call) and isinstance(e.func, ast.Name)
                and e.func.id in ("keychain_service", "keychain_path", "str"))
            if not ok:
                bad.append(f"{name}:{node.lineno} argv element {i + 1} is {ast.dump(e)[:60]}")
        consts = [e.value for e in els if isinstance(e, ast.Constant)]
        if "add-generic-password" in consts:
            bad.append(f"{name}:{node.lineno} add-generic-password in argv (must go via stdin -i)")
        if "-w" in consts:
            j = [k for k, e in enumerate(els) if isinstance(e, ast.Constant) and e.value == "-w"][0]
            if "find-generic-password" not in consts or j != len(els) - 2:
                bad.append(f"{name}:{node.lineno} -w must be a bare read flag followed only by the keychain path")
    return n, bad


def scan_shell_security_calls(text: str, name: str):
    """Shell call sites: no add-generic-password at all outside `security -i`,
    and no `-w <value>` on any security line."""
    n, bad = 0, []
    for no, line in enumerate(text.splitlines(), 1):
        code = line.strip()
        if code.startswith("#") or "generic-password" not in code:
            continue
        if not re.search(r"\bsecurity\b", code):
            continue
        n += 1
        if "add-generic-password" in code and not re.search(r"\bsecurity\s+-i\b", code):
            bad.append(f"{name}:{no} add-generic-password in argv")
        if re.search(r"\s-w\s+[^\s-]", code) and "find-generic-password" not in code:
            bad.append(f"{name}:{no} -w <value> in argv")
    return n, bad


def scan_tree_for_security_calls(root: Path):
    total, bad, files = 0, [], []
    skip_dirs = {".git", "tests", "node_modules", "cut-manifests", "divergences"}
    for p in sorted(root.rglob("*")):
        if not p.is_file() or skip_dirs & set(p.relative_to(root).parts):
            continue
        if p.suffix not in (".py", ".sh") and p.name != "install.sh":
            continue
        try:
            t = p.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        rel = str(p.relative_to(root))
        if p.suffix == ".py" and ("_SECURITY_BIN" in t or "/usr/bin/security" in t):
            n, b = scan_python_security_calls(t, rel)
        elif p.suffix != ".py" and "generic-password" in t:
            n, b = scan_shell_security_calls(t, rel)
        else:
            continue
        if n:
            files.append(rel)
        total += n
        bad += b
    return total, bad, files


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix="ostler-h129-"))
    # Nothing below may resolve ~ to the real home (and so the real keychain).
    os.environ["HOME"] = str(work / "home")
    (work / "home").mkdir()
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

        # ---- H: HERMETIC keychain arms (fake `security`, no keychain) ----
        print("H. every security call carries an explicit keychain; a missing keychain never reaches security")
        h = work / "home" / ".ostler"
        d = secdir(h, True)   # == the default key file location under the fake HOME
        os.environ["OSTLER_DB_KEY_FILE"] = str(d / "db_key")
        # Control: legacy file-only mode leaves the file, and the scan sees it.
        legacy = db_key.resolve_db_key()
        check(legacy.key == KEY and (d / "db_key").exists() and tree_contains(d, KEY),
              "K control: file-only mode keeps the plaintext key file and the scan finds it")
        os.environ.pop("OSTLER_DB_KEY_FILE", None)
        have_api = all(hasattr(db_key, n) for n in
                       ("keychain_available", "keychain_path", "migrate_key_file_to_keychain"))
        check(have_api, "H0: resolver exposes keychain_path() and migrate_key_file_to_keychain")
        if have_api:
            real_bin = db_key._SECURITY_BIN
            svc = f"Ostler DB Key TEST h129 {os.getpid()}"
            os.environ["OSTLER_DB_KEY_KEYCHAIN_SERVICE"] = svc
            os.environ.pop("OSTLER_KEYCHAIN_PATH", None)
            default_kc = os.path.expanduser("~/Library/Keychains/login.keychain-db")
            check(db_key.keychain_path() == default_kc,
                  "H1: with no override the keychain is the login keychain, by explicit path")
            # H2: nonexistent keychain -> keychain_unavailable, NO security call at all.
            log = work / "h2.log"
            db_key._SECURITY_BIN = fake_security(work / "sec_h2", 0, log)
            ghost = str(work / "does-not-exist.keychain-db")
            os.environ["OSTLER_KEYCHAIN_PATH"] = ghost
            (d / "db_key").write_text(KEY + "\n")
            (d / "db_key").chmod(0o600)
            rk = db_key.read_keychain_key()
            check(rk.key is None and rk.reason == db_key.REASON_KEYCHAIN_UNAVAILABLE,
                  f"H2: nonexistent keychain file -> keychain_unavailable (got {rk.reason!r})")
            try:
                db_key.write_keychain_key(KEY)
                wrote = True
            except OSError:
                wrote = False
            check(not wrote, "H2: writing to a nonexistent keychain fails loudly (OSError), no fallback")
            mg = db_key.migrate_key_file_to_keychain(d / "db_key")
            check((d / "db_key").exists() and mg.source != "keychain",
                  "H2: a failed move leaves the key file exactly as it was")
            check(not log.exists(),
                  "H2: NO security invocation was made for a nonexistent keychain (no dialog-capable call)")
            # H2b: the resolver itself, end to end, with the keychain absent.
            rr = db_key.resolve_db_key()
            check(rr.key is None and rr.reason == db_key.REASON_KEYCHAIN_UNAVAILABLE,
                  f"H2b: resolve_db_key with an absent keychain -> keychain_unavailable (got {rr.reason!r})")
            check(rr.source != "file" and (d / "db_key").read_text().strip() == KEY
                  and not log.exists(),
                  "H2b: ...no plaintext fallback, key file untouched, still no security call")
            # H2c: the DEFAULT path (login.keychain-db under the fake HOME, which
            # does not exist) must not be assumed to exist either.
            os.environ.pop("OSTLER_KEYCHAIN_PATH", None)
            check(not os.path.exists(db_key.keychain_path()),
                  "H2c (control): the default login keychain does not exist under the temp HOME")
            rd = db_key.read_keychain_key()
            check(rd.key is None and rd.reason == db_key.REASON_KEYCHAIN_UNAVAILABLE and not log.exists(),
                  f"H2c: absent default login keychain -> keychain_unavailable, no security call (got {rd.reason!r})")
            os.environ["OSTLER_KEYCHAIN_PATH"] = ghost
            # H3: with the keychain file present, EVERY invocation names it explicitly.
            dummy = work / "dummy.keychain-db"
            dummy.write_bytes(b"not a real keychain; the fake security never reads it")
            os.environ["OSTLER_KEYCHAIN_PATH"] = str(dummy)
            real_lock = getattr(db_key, "_keychain_lock_state", None)
            db_key._keychain_lock_state = lambda p: "unlocked"
            log3 = work / "h3.log"
            db_key._SECURITY_BIN = fake_security(work / "sec_h3", 44, log3)
            db_key.read_keychain_key()
            try:
                db_key.write_keychain_key(KEY)
            except OSError:
                pass
            lines = log3.read_text().splitlines() if log3.exists() else []
            argvs = [l[5:].split() for l in lines if l.startswith("ARGV ")]
            stdin = [l[6:] for l in lines if l.startswith("STDIN ")]
            check(len(argvs) >= 2, f"H3 (control): the fake security recorded the calls ({len(argvs)} argv)")
            for a in argvs:
                if a and a[0] == "-i":
                    continue
                check(a[-1] == str(dummy),
                      f"H3: `security {a[0]}` carries the explicit keychain path as its last argument")
            check(any(l.startswith("add-generic-password") and l.endswith(f'"{dummy}"') for l in stdin),
                  "H3: the `security -i` add-generic-password command names the keychain explicitly")
            check(not any(KEY in " ".join(a) for a in argvs),
                  "H3: the key never appears in argv")
            # H4: unreadable keychain (locked / no session): do not guess, do not touch the file.
            log4 = work / "h4.log"
            db_key._SECURITY_BIN = fake_security(work / "sec51", 51, log4)
            (d / "db_key").write_text(KEY + "\n")
            (d / "db_key").chmod(0o600)
            ru = db_key.resolve_db_key()
            check(ru.key is None and ru.reason == db_key.REASON_KEYCHAIN_UNAVAILABLE,
                  f"H4: unreadable Keychain -> no key, reason keychain_unavailable (got {ru.reason!r})")
            check(ru.source != "file" and ru.key is None, "H4: and it does not fall back to the plaintext file")
            check((d / "db_key").exists(), "H4: ...and the key file is left exactly as it was")
            # H6: a LOCKED (or undeterminable) keychain never reaches `security`
            # (in a GUI session a find/add on a locked keychain can raise the
            # unlock-password dialog). Control: when unlocked, security IS called.
            for state in ("locked", "unknown"):
                log6 = work / f"h6-{state}.log"
                db_key._SECURITY_BIN = fake_security(work / f"sec6-{state}", 0, log6)
                db_key._keychain_lock_state = lambda p, _s=state: _s
                (d / "db_key").write_text(KEY + "\n")
                (d / "db_key").chmod(0o600)
                rk = db_key.read_keychain_key()
                check(rk.key is None and rk.reason == db_key.REASON_KEYCHAIN_UNAVAILABLE,
                      f"H6 {state}: read -> keychain_unavailable (got {rk.reason!r})")
                try:
                    db_key.write_keychain_key(KEY)
                    wrote = True
                except OSError:
                    wrote = False
                check(not wrote, f"H6 {state}: write fails loudly (OSError)")
                rr = db_key.resolve_db_key()
                check(rr.key is None and rr.reason == db_key.REASON_KEYCHAIN_UNAVAILABLE
                      and rr.source != "file" and (d / "db_key").read_text().strip() == KEY,
                      f"H6 {state}: resolve -> unavailable, no plaintext fallback, file untouched")
                check(not log6.exists(),
                      f"H6 {state}: NO security invocation was made (no dialog-capable call)")
            log6u = work / "h6-unlocked.log"
            db_key._SECURITY_BIN = fake_security(work / "sec6-u", 44, log6u)
            db_key._keychain_lock_state = lambda p: "unlocked"
            db_key.read_keychain_key()
            check(log6u.exists(), "H6 (control): an unlocked keychain DOES reach security")
            if real_lock is not None:
                db_key._keychain_lock_state = real_lock
            db_key._SECURITY_BIN = real_bin
            os.environ.pop("OSTLER_KEYCHAIN_PATH", None)
            os.environ.pop("OSTLER_DB_KEY_KEYCHAIN_SERVICE", None)
            check(db_key.keychain_service() == "Ostler DB Key",
                  "H5: default service name is 'Ostler DB Key'")
            os.environ["OSTLER_DB_KEY_FILE"] = str(d / "db_key")
            check(not db_key.keychain_enabled(),
                  "H5: explicit OSTLER_DB_KEY_FILE keeps file-only mode (no Keychain access from tests)")
            os.environ.pop("OSTLER_DB_KEY_FILE", None)

        # ---- K: key in a THROWAWAY keychain (CI / opt-in only) -------------
        print("K. DB key in a throwaway Keychain")
        if not (have_api and have_kc):
            check(False, "K: resolver has Keychain support")
        elif not throwaway_allowed():
            skip("K1-K3", "creating a keychain edits the user's keychain search list; "
                          "runs on CI only, never on a developer Mac")
        else:
            kc = str(work / "test.keychain-db")
            pw = os.urandom(16).hex()
            before = search_list()
            cr = subprocess.run(["/usr/bin/security", "create-keychain", "-p", pw, kc],
                                capture_output=True, text=True, stdin=subprocess.DEVNULL)
            ul = subprocess.run(["/usr/bin/security", "unlock-keychain", "-p", pw, kc],
                                capture_output=True, text=True, stdin=subprocess.DEVNULL)
            try:
                if cr.returncode != 0 or ul.returncode != 0:
                    skip("K1-K3", f"could not create/unlock the throwaway keychain ({cr.stderr.strip()} {ul.stderr.strip()})")
                else:
                    h = work / "k1"
                    d = secdir(h, True)
                    os.environ["OSTLER_KEYCHAIN_PATH"] = kc
                    os.environ["OSTLER_DB_KEY_KEYCHAIN_SERVICE"] = service
                    os.environ["OSTLER_DB_KEY_FILE"] = str(d / "db_key")
                    # An explicit file path switches the resolver to file-only unless the
                    # service opt-in is set; the opt-in is set, so keychain mode is on.
                    r1 = db_key.resolve_db_key()
                    check(r1.key == KEY and r1.source == "keychain",
                          f"K1: resolver returns the key from the throwaway Keychain (source={r1.source!r})")
                    check(not (d / "db_key").exists(), "K1: the plaintext key file is deleted after the move")
                    check(not tree_contains(d, KEY), "K1: the key's bytes are nowhere in the security folder")
                    check(kc_read(service, kc) == KEY, "K1: an independent `security` read returns the key")
                    r2 = db_key.resolve_db_key()
                    check(r2.key == KEY and r2.source == "keychain",
                          "K2: with no file at all, the reader still gets the key (from the Keychain)")
                    (d / "db_key").write_text(KEY + "\n")
                    (d / "db_key").chmod(0o600)
                    db_key.resolve_db_key()
                    check(not (d / "db_key").exists(), "K3: a leftover key file beside a Keychain item is removed")
                    # K5: lock it; the real detector must say locked, and no read/write
                    # may hang or reach security. Bounded by a wall-clock assert.
                    import time
                    check(db_key._keychain_lock_state(kc) == "unlocked",
                          "K5 (control): detector reports the unlocked throwaway keychain as unlocked")
                    subprocess.run(["/usr/bin/security", "lock-keychain", kc],
                                   capture_output=True, stdin=subprocess.DEVNULL)
                    t0 = time.monotonic()
                    ls = db_key._keychain_lock_state(kc)
                    r5 = db_key.resolve_db_key()
                    try:
                        db_key.write_keychain_key(KEY)
                        w5 = True
                    except OSError:
                        w5 = False
                    el = time.monotonic() - t0
                    check(ls == "locked", f"K5: detector reports the locked keychain as locked (got {ls!r})")
                    check(r5.key is None and r5.reason == db_key.REASON_KEYCHAIN_UNAVAILABLE
                          and "locked" in (r5.detail or ""),
                          f"K5: resolve on a locked keychain -> keychain_unavailable naming the lock ({r5.reason!r}, {r5.detail!r})")
                    check(not w5, "K5: write to a locked keychain fails loudly")
                    check(el < 10, f"K5: no hang (took {el:.2f}s)")
            finally:
                subprocess.run(["/usr/bin/security", "delete-keychain", kc],
                               capture_output=True, stdin=subprocess.DEVNULL)
                os.environ.pop("OSTLER_KEYCHAIN_PATH", None)
                os.environ.pop("OSTLER_DB_KEY_FILE", None)
                os.environ.pop("OSTLER_DB_KEY_KEYCHAIN_SERVICE", None)
            check(search_list() == before,
                  "K4: the user keychain search list is identical before and after the test")

        # ---- S: the key value is never in any security argv (static scan) ----
        print("S. no security call site anywhere puts the key in argv")
        # Controls: the scanner flags each way of getting it wrong.
        cn, cb = scan_python_security_calls(
            "import subprocess\nsubprocess.run([_SECURITY_BIN, 'add-generic-password', '-w', key_hex, kp])\n", "ctl")
        check(cn == 1 and len(cb) >= 3, f"S control: scanner flags key_hex + add-generic-password + -w in a python argv ({len(cb)} hits)")
        cn, cb = scan_python_security_calls(
            "subprocess.run([_SECURITY_BIN, 'find-generic-password', '-w', f'{k}', kp])\n", "ctl")
        check(cn == 1 and cb, "S control: scanner flags an f-string argv element")
        cn, cb = scan_shell_security_calls('security add-generic-password -s x -w "$KEY" kc\n', "ctl.sh")
        check(cn == 1 and len(cb) == 2, f"S control: scanner flags shell `add-generic-password -w $KEY` ({len(cb)} hits)")
        cn, cb = scan_python_security_calls(
            "subprocess.run([_SECURITY_BIN, 'find-generic-password', '-s', keychain_service(), '-a', A, '-w', keychain_path()])\n", "ctl")
        check(cn == 1 and len(cb) == 1, "S control: a Name element (A) is flagged but the bare `-w <path>` read form is accepted")
        total, bad, files = scan_tree_for_security_calls(ROOT)
        check(total >= 2 and "vendor/ostler_security/db_key.py" in files,
              f"S denominator: {total} call sites in {files} (db_key.py read+write must be among them)")
        check(not bad, "S: no call site puts the key in argv" + (": " + "; ".join(bad) if bad else ""))

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
