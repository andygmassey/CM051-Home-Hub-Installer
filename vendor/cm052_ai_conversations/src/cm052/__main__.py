"""``python -m src.cm052`` entrypoint.

Delegates to :func:`cli.main`. This mirrors the ``pwg-ai-convo``
console script declared in ``pyproject.toml`` so the package is
runnable both as an installed script AND as a module, which is how
the CM051 installer invokes the vendored copy (``python -m
src.cm052 --source all``) without depending on the console-script
shim being on PATH.
"""
from __future__ import annotations

import sys

from .cli import main

if __name__ == "__main__":
    sys.exit(main())
