"""CM051 port of CM048 tests/conftest.py at ec5e1e83 (#99), for v1.0.112.

These upstream tests run against the VENDORED tree vendor/cm048_pipeline,
not a CM048 checkout: the path insert below puts the vendored ``src``
first, and this directory second for the shared fixtures. Upstream text
follows unchanged.
"""
import sys as _sys
from pathlib import Path as _Path

_HERE = _Path(__file__).resolve().parent
_VENDOR = _HERE.parent.parent / "vendor" / "cm048_pipeline"
for _p in (str(_HERE), str(_VENDOR)):
    if _p not in _sys.path:
        _sys.path.insert(0, _p)

"""Make the suite runnable in CI without the private HR015 checkout.

WHY THIS EXISTS
---------------
``src/ingest.py`` hard-fails at import time if ``ostler_security`` is
missing. That guard is correct and deliberate -- a missing security
package is a deploy bug, and silently degrading to plaintext databases is
exactly the defect it was written to remove.

But ``ostler_security`` lives in **HR015-Gaming-PC, which is private**
(verified: ``gh repo view andygmassey/HR015-Gaming-PC`` -> private=true).
CM048's ``GITHUB_TOKEN`` cannot check it out, so every module that
imports ``src.ingest`` fails to COLLECT in CI. That is why 35 of 36 test
files have never run there: not because anyone chose to skip them, but
because they could not be imported.

WHAT THIS DOES, AND WHAT IT DELIBERATELY DOES NOT DO
----------------------------------------------------
If the REAL package is importable, this file does nothing at all. On a
dev box with HR015 on ``PYTHONPATH`` the real code is exercised, exactly
as before.

Only when the real package is genuinely absent does it install a minimal
stand-in, so the ~700 tests that have nothing to do with encryption can
run. The stand-in is deliberately loud and useless for anything real:
``get_db_connection`` returns an ordinary in-memory sqlite3 connection
and ``record_posture`` is a no-op.

🔴 THE STUB MUST NOT BE ABLE TO HIDE THE PRODUCTION GUARD.
A stub that silences a security hard-fail is strictly worse than no
tests, because it converts a loud deploy bug into a green suite. So
``test_security_guard_still_hard_fails.py`` asserts, in a subprocess with
this stub explicitly NOT installed, that importing ``src.ingest`` still
raises. If someone ever weakens that guard, that test goes red -- the
stub cannot mask it, because the test does not use the stub.
"""


import sys
import types


def _real_package_is_available() -> bool:
    """True when the genuine ostler_security can be imported."""
    try:
        import ostler_security.database  # noqa: F401
        import ostler_security.posture  # noqa: F401
    except Exception:
        return False
    return True


def _install_stub() -> None:
    """Register a minimal, obviously-inert ostler_security in sys.modules."""
    import sqlite3

    pkg = types.ModuleType("ostler_security")
    pkg.__OSTLER_TEST_STUB__ = True  # so a test can assert which one ran

    database = types.ModuleType("ostler_security.database")

    def get_db_connection(path=None, key=None, **kwargs):
        """Plain sqlite3. NOT encrypted. Test-only, never importable in prod
        because prod has the real package and this branch never runs."""
        return sqlite3.connect(":memory:" if path is None else str(path))

    database.get_db_connection = get_db_connection

    posture = types.ModuleType("ostler_security.posture")

    def record_posture(*args, **kwargs):
        return None

    posture.record_posture = record_posture

    pkg.database = database
    pkg.posture = posture
    sys.modules.setdefault("ostler_security", pkg)
    sys.modules.setdefault("ostler_security.database", database)
    sys.modules.setdefault("ostler_security.posture", posture)


if not _real_package_is_available():
    _install_stub()


# CM051 VENDORED DIFFERENCE: the vendored src/ingest.py also imports
# ostler_security.db_key (resolve_db_key), which upstream's stub does not
# provide. When the stub is the one in play, give it that module too, and
# make it a package so the submodule import resolves. Never touches the
# real package (CI installs vendor/ostler_security, so this branch is idle).
_pkg = sys.modules.get("ostler_security")
if _pkg is not None and getattr(_pkg, "__OSTLER_TEST_STUB__", False):
    _pkg.__path__ = []
    _db_key = types.ModuleType("ostler_security.db_key")
    _db_key.resolve_db_key = lambda *a, **k: types.SimpleNamespace(key=None, source="test-stub", reason="")
    sys.modules["ostler_security.db_key"] = _db_key
    _pkg.db_key = _db_key
