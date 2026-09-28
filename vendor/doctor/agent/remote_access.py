"""Remote access = the Tailscale the INSTALLER set up (Doctor, v1.0.106).

Andy's v1.0.105 walk: Settings showed "Remote access (Tailscale)" OFF while
the installer's tailscaled was connected. The Settings toggle read the
daemon's `tunnel.provider`, which install.sh never writes, and a daemon
provider of "tailscale" does something else entirely: it runs
`tailscale serve` against the DEFAULT socket, not the installer's userspace
tailscaled at ~/.ostler/tailscale/tailscaled.sock. So the toggle neither
showed nor controlled the real connection.

This reads and drives the installer's own tailscaled through its socket, with
the same `up` flags install.sh used, so flipping it back on reconnects the
same machine without a new sign-in.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

_CANDIDATES = ("/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale")
# Must match install.sh: ( "$TS_CLI" --socket="$TS_SOCK" up --hostname=ostler-hub )
UP_ARGS = ("up", "--hostname=ostler-hub")


def _cli() -> str | None:
    for c in _CANDIDATES:
        if os.access(c, os.X_OK):
            return c
    return shutil.which("tailscale")


def _socket() -> Path:
    root = Path(os.environ.get("OSTLER_DIR", str(Path.home() / ".ostler")))
    return root / "tailscale" / "tailscaled.sock"


def _run(args, timeout=20):
    cli = _cli()
    if cli is None:
        return None
    return subprocess.run([cli, f"--socket={_socket()}", *args],
                          capture_output=True, text=True, timeout=timeout)


def status() -> dict:
    """{installed, connected, state}. `installed` is False when the installer
    never set Tailscale up on this Mac (no CLI or no socket)."""
    if _cli() is None or not _socket().exists():
        return {"installed": False, "connected": False, "state": "not_installed"}
    try:
        out = _run(["status", "--json"], timeout=8)
    except Exception as exc:
        return {"installed": True, "connected": False, "state": "unreadable",
                "error": exc.__class__.__name__}
    if out is None or out.returncode != 0 and not out.stdout.strip():
        return {"installed": True, "connected": False, "state": "stopped"}
    try:
        d = json.loads(out.stdout)
    except ValueError:
        return {"installed": True, "connected": False, "state": "unreadable"}
    state = d.get("BackendState") or "unknown"
    return {"installed": True, "connected": state == "Running", "state": state}


def set_enabled(enabled: bool) -> dict:
    """Turn the installer's Tailscale connection on or off, then report."""
    if _cli() is None or not _socket().exists():
        return {**status(), "error": "Tailscale was not set up on this Mac"}
    out = _run(list(UP_ARGS) if enabled else ["down"])
    result = status()
    if out is not None and out.returncode != 0:
        result["error"] = "tailscale did not accept the change"
    return result
