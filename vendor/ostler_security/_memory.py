"""Best-effort secret-material scrubbing helpers.

Shared across the security module. Python's standard `bytes` objects
are immutable; the bytes they hold can't be overwritten without
copying to a mutable buffer first. This module provides:

1. `zeroize(buf)` – overwrite a mutable bytearray in-place. Uses
   `ctypes.memset` as the primary path (the operation CPython's
   bytecode interpreter can't dead-store-eliminate even under
   aggressive optimisation) with a portable indexed-assignment
   fallback if the ctypes call fails.

2. `scrub_on_exit(buf)` – context manager that guarantees `zeroize`
   runs even on exception propagation. Use this anywhere a
   sensitive bytearray's lifetime is scoped to a block.

Python-runtime limits
---------------------

The security guarantee has real caveats:

- Immutable `bytes` objects (what `os.urandom()`, `HKDF.derive()`,
  `aes_key_unwrap()`, etc. return) CANNOT be scrubbed. Their
  memory is reclaimed only when Python's GC collects the object,
  which happens at an unpredictable time. We can copy into a
  bytearray and scrub the copy, but the original immutable bytes
  persist until GC.

- Python `str` objects (recovery phrases, after BIP39
  normalisation) are likewise immutable.

- The C-backed `cryptography` library that we call through creates
  temporary bytes-like intermediate values we don't control. We
  assume those are reasonably short-lived; there is no Python API
  to scrub them.

These caveats are documented in SECURITY_MODEL.md alongside the
audit table showing which specific variables are guaranteed-scrubbed
vs best-effort vs impossible. This module's job is to make the
"guaranteed-scrubbed" column honest by providing a primitive that
actually works at runtime.
"""
from __future__ import annotations

from contextlib import contextmanager
from typing import Iterator, Union


def zeroize(buf: Union[bytearray, memoryview]) -> None:
    """Overwrite `buf` with zeros in-place.

    Primary path: `ctypes.memset` on a `from_buffer` view of the
    bytearray. The operation is a C memset that cannot be elided by
    Python's bytecode interpreter.

    Fallback path (when the ctypes call fails for any reason):
    indexed assignment `buf[i] = 0` for each byte. CPython's
    interpreter does not dead-store-eliminate bytecode stores, so
    this genuinely writes zeros to the underlying buffer before
    the reference is dropped.

    Silently accepts zero-length buffers.
    """
    if len(buf) == 0:
        return

    ctypes_ok = False
    try:
        import ctypes
        view = (ctypes.c_char * len(buf)).from_buffer(buf)
        ctypes.memset(view, 0, len(buf))
        ctypes_ok = True
    except Exception:
        ctypes_ok = False

    if not ctypes_ok:
        for i in range(len(buf)):
            buf[i] = 0


@contextmanager
def scrub_on_exit(buf: bytearray) -> Iterator[bytearray]:
    """Context manager: yield `buf` for use, zeroize on exit.

    Guarantees scrubbing runs even if the block raises. Idiomatic
    usage:

        with scrub_on_exit(bytearray(sensitive_bytes)) as scratch:
            ... use scratch ...
        # scratch has been zeroized here

    The yielded bytearray IS the one passed in – not a copy.
    Callers wanting a copy should bytearray()-copy first.
    """
    try:
        yield buf
    finally:
        zeroize(buf)


__all__ = ["zeroize", "scrub_on_exit"]
