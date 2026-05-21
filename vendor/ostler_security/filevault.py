"""FileVault status checking for macOS.

Verifies that full-disk encryption is enabled on the boot volume.
This is the first layer of Ostler's encryption-at-rest strategy.
"""
from __future__ import annotations

import platform
import subprocess
import logging

logger = logging.getLogger(__name__)


def check_filevault_status() -> dict:
    """Check whether FileVault is enabled on macOS.

    Returns:
        Dict with:
            - enabled: bool
            - status: str (human-readable status)
            - raw_output: str (fdesetup output for debugging)
            - platform: str (os name)
    """
    if platform.system() != "Darwin":
        return {
            "enabled": False,
            "status": "Not macOS – FileVault check not applicable",
            "raw_output": "",
            "platform": platform.system(),
        }

    try:
        result = subprocess.run(
            ["fdesetup", "status"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        raw = result.stdout.strip()

        if "FileVault is On" in raw:
            return {
                "enabled": True,
                "status": "FileVault is enabled. Your disk is encrypted.",
                "raw_output": raw,
                "platform": "Darwin",
            }
        elif "FileVault is Off" in raw:
            return {
                "enabled": False,
                "status": (
                    "FileVault is NOT enabled. Your disk is not encrypted. "
                    "Enable it in System Settings > Privacy & Security > FileVault. "
                    "This is strongly recommended before using Ostler."
                ),
                "raw_output": raw,
                "platform": "Darwin",
            }
        else:
            return {
                "enabled": False,
                "status": f"Could not determine FileVault status: {raw}",
                "raw_output": raw,
                "platform": "Darwin",
            }

    except subprocess.TimeoutExpired:
        return {
            "enabled": False,
            "status": "FileVault check timed out",
            "raw_output": "",
            "platform": "Darwin",
        }
    except FileNotFoundError:
        return {
            "enabled": False,
            "status": "fdesetup command not found (unexpected on macOS)",
            "raw_output": "",
            "platform": "Darwin",
        }
    except Exception as exc:
        logger.warning("FileVault check failed: %s", exc)
        return {
            "enabled": False,
            "status": f"FileVault check error: {exc}",
            "raw_output": "",
            "platform": "Darwin",
        }
