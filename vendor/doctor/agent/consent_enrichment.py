#!/usr/bin/env python3
"""Give or withdraw the public-lookups consent (GDPR Art.7(3)).

Withdrawing must be as easy as giving. Setup asks the question once
(install.sh) and writes the answer to ~/.ostler/config/.env as
OSTLER_CONSENT_ENRICHMENT_DECISION. Every reader of that key (the wiki tick,
the CM019 enrich gate, the CM059 scouts, the CM044 launcher) re-reads the FILE
on each run and fails closed on anything but "accepted". So changing the value
in the file is the whole mechanism; this module is the one writer.

What a write does:
  1. rewrites the key in config/.env atomically (temp file in the same dir,
     mode 0600, os.replace), keeping every other line byte for byte;
  2. rewrites posture/enrichment-decision.json (the file install.sh writes);
  3. appends one event to posture/consent-events.jsonl with a UTC timestamp,
     the previous and the new decision, and whether it was given or withdrawn.

Only "accepted" and "declined" are valid. "declined" is the withdrawal: every
reader treats it as off.

CLI:
    python3 vendor/doctor/agent/consent_enrichment.py set accepted|declined [--ostler-dir DIR]

Exit: 0 written, 2 usage or invalid decision, 1 could not write.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

KEY = "OSTLER_CONSENT_ENRICHMENT_DECISION"
VALID = ("accepted", "declined")
TICKBOX = "background_enrichment"


def ostler_dir(override: Optional[str] = None) -> Path:
    base = override or os.environ.get("OSTLER_DIR") or os.path.join(os.path.expanduser("~"), ".ostler")
    return Path(base)


def read_decision(env_text: str) -> Optional[str]:
    """Last matching line wins, one pair of quotes stripped, exact compare
    (the same reader as the shell gates). None when the key is absent."""
    value = None
    prefix = KEY + "="
    for line in env_text.split("\n"):
        if line.startswith(prefix):
            value = line[len(prefix):]
    if value is None:
        return None
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    return value


def read_decision_from_base(base: Path) -> Optional[str]:
    """The decision as the wiki tick reads it: config/.env under base."""
    env_path = base / "config" / ".env"
    try:
        text = env_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    return read_decision(text)


def rewrite_env(env_text: str, decision: str) -> str:
    """Return env_text with every KEY= line replaced by one KEY="decision"
    line at the position of the last one; appended when absent. Other lines
    are untouched."""
    if decision not in VALID:
        raise ValueError(f"decision must be one of {VALID}, got {decision!r}")
    new_line = f'{KEY}="{decision}"'
    lines = env_text.split("\n")
    positions = [i for i, ln in enumerate(lines) if ln.startswith(KEY + "=")]
    if not positions:
        body = env_text
        if body and not body.endswith("\n"):
            body += "\n"
        return body + new_line + "\n"
    last = positions[-1]
    out = []
    for i, ln in enumerate(lines):
        if ln.startswith(KEY + "="):
            if i == last:
                out.append(new_line)
            continue
        out.append(ln)
    return "\n".join(out)


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _append_event(path: Path, event: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    existed = path.exists()
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(event, sort_keys=True) + "\n")
    if not existed:
        os.chmod(path, 0o600)


def set_decision(base: Path, decision: str, *, now: Optional[datetime] = None) -> dict:
    """Write the decision and log the event. Returns the event dict."""
    if decision not in VALID:
        raise ValueError(f"decision must be one of {VALID}, got {decision!r}")
    env_path = base / "config" / ".env"
    posture = base / "posture"
    old_text = env_path.read_text(encoding="utf-8") if env_path.exists() else ""
    previous = read_decision(old_text)
    stamp = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")

    _atomic_write(env_path, rewrite_env(old_text, decision))
    _atomic_write(
        posture / "enrichment-decision.json",
        json.dumps({"tickbox": TICKBOX, "decision": decision, "recorded_at": stamp}) + "\n",
    )
    event = {
        "tickbox": TICKBOX,
        "event": "given" if decision == "accepted" else "withdrawn",
        "previous": previous,
        "decision": decision,
        "recorded_at": stamp,
        "source": "owner_settings",
    }
    _append_event(posture / "consent-events.jsonl", event)
    return event


def main(argv: list[str]) -> int:
    args = list(argv)
    override = None
    if "--ostler-dir" in args:
        i = args.index("--ostler-dir")
        try:
            override = args[i + 1]
        except IndexError:
            print("usage: --ostler-dir needs a path", file=sys.stderr)
            return 2
        del args[i:i + 2]
    if len(args) != 2 or args[0] != "set":
        print("usage: consent_enrichment.py set accepted|declined [--ostler-dir DIR]", file=sys.stderr)
        return 2
    if args[1] not in VALID:
        print(f"invalid decision {args[1]!r}; expected accepted or declined", file=sys.stderr)
        return 2
    try:
        event = set_decision(ostler_dir(override), args[1])
    except OSError as exc:
        print(f"could not write the consent decision: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(event, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
