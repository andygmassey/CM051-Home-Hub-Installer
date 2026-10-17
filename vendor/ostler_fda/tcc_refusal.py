"""Is this exception macOS refusing a read (no Full Disk Access)?

CM051 G1 / status-honesty sweep V26 (2026-10-15). Every FDA reader used to
test for the literal text "authorization denied". A TCC refusal reaches Python
in at least four shapes, and only one of them carries that text:

    PermissionError / OSError EPERM ("Operation not permitted") or EACCES
    sqlite3 SQLITE_AUTH   (23)  "authorization denied"
    sqlite3 SQLITE_PERM   (3)   "access permission denied"
    sqlite3 SQLITE_CANTOPEN (14) "unable to open database file", the usual
                                 shape when open() itself is refused

The other three fell through to status "error", so a refused read was reported
as a generic failure with no permission prompt, and #2908 (which keys on
no_fda) could not tell the customer what to grant.

Classified from STRUCTURE first: the errno, then the sqlite error code
(Python 3.11+ `sqlite_errorcode`). Message text is only a fallback for an
interpreter without the code.

SQLITE_CANTOPEN also means "the file is not there". It counts as a refusal
only when `path` is given and the file EXISTS (or cannot even be stat'ed,
which is itself a refusal). Without a path it is never treated as one.
"""
from __future__ import annotations

import errno
import os
import sqlite3
from typing import Optional, Union

SQLITE_PERM = 3
SQLITE_CANTOPEN = 14
SQLITE_AUTH = 23

_REFUSAL_ERRNOS = (errno.EPERM, errno.EACCES)
_REFUSAL_TEXT = ("authorization denied", "operation not permitted",
                 "access permission denied")


def _path_exists_or_refused(path: Union[str, os.PathLike]) -> bool:
    try:
        os.stat(path)
        return True
    except FileNotFoundError:
        return False
    except OSError as exc:
        return exc.errno in _REFUSAL_ERRNOS


def is_fda_refusal(exc: BaseException,
                   path: Optional[Union[str, os.PathLike]] = None) -> bool:
    """True when `exc` (or anything in its cause chain) is a TCC refusal."""
    seen = set()
    cur: Optional[BaseException] = exc
    while cur is not None and id(cur) not in seen:
        seen.add(id(cur))
        if isinstance(cur, PermissionError):
            return True
        if isinstance(cur, OSError) and cur.errno in _REFUSAL_ERRNOS:
            return True
        if isinstance(cur, sqlite3.Error):
            code = getattr(cur, "sqlite_errorcode", None)
            if isinstance(code, int):
                primary = code & 0xFF
                if primary in (SQLITE_AUTH, SQLITE_PERM):
                    return True
                if primary == SQLITE_CANTOPEN:
                    return path is not None and _path_exists_or_refused(path)
            else:
                msg = str(cur).lower()
                if any(t in msg for t in _REFUSAL_TEXT):
                    return True
                if "unable to open database file" in msg:
                    return path is not None and _path_exists_or_refused(path)
        cur = cur.__cause__ or cur.__context__
    return False
