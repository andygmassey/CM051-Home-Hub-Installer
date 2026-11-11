#!/usr/bin/env python3
"""THE HUB INSTALL MUST PUBLISH THE WORDING HASH THE APP CHECKS AGAINST.

CM042 RemoteCapture refuses capture unless its persisted spoken-capture
record carries the SHA-256 of the wording THIS install ships. The app used to
pin that hash as a Swift constant, which nothing cross-checked, so any wording
change here refused every customer. The app now reads
``$OSTLER_HOME/posture/consent_wording_hashes.json`` instead, and this build
is what writes it.

Driven for real, not grepped:
  (a) ``consent_cli publish-wording`` writes the file, and the spoken-capture
      hash in it is the SHA-256 of the wording text the legal package bundles,
      and of the text ``consent_cli text`` prints (what the screen shows).
  (b) the file is mode 0600 and contains every registered tickbox.
  (c) install.sh calls the publish on the consent-persist path, exactly once.

FAIL BEFORE: on a tree without the subcommand, argparse exits 2 and (a) fails.
"""
from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor"
TICKBOX = "spoken_capture_recording_consent"


def _run(args, env_home):
    env = dict(os.environ, OSTLER_HOME=env_home, PYTHONDONTWRITEBYTECODE="1",
               PYTHONPATH=str(VENDOR))
    return subprocess.run(
        [sys.executable, "-m", "ostler_security.consent_cli", *args],
        cwd=str(VENDOR), env=env, capture_output=True, text=True,
    )


def main() -> int:
    failures = []

    with tempfile.TemporaryDirectory(prefix="wording-hashes-") as home:
        pub = _run(["publish-wording"], home)
        if pub.returncode != 0:
            failures.append(f"publish-wording exited {pub.returncode}: {pub.stderr.strip()[:300]}")
            _report(failures)
            return 1

        path = Path(home) / "posture" / "consent_wording_hashes.json"
        if not path.is_file():
            failures.append(f"publish-wording wrote no file at {path}")
            _report(failures)
            return 1

        mode = stat.S_IMODE(path.stat().st_mode)
        if mode != 0o600:
            failures.append(f"file mode is {oct(mode)}, want 0o600")

        data = json.loads(path.read_text())
        entry = data.get("tickboxes", {}).get(TICKBOX)
        if not entry:
            failures.append(f"no entry for {TICKBOX} in {sorted(data.get('tickboxes', {}))}")
        else:
            shown = _run(["text", "--tickbox", TICKBOX], home)
            if shown.returncode != 0:
                failures.append(f"consent_cli text exited {shown.returncode}")
            else:
                shown_hash = hashlib.sha256(shown.stdout.encode("utf-8")).hexdigest()
                if entry["wording_hash"] != shown_hash:
                    failures.append(
                        f"published hash {entry['wording_hash']} != SHA-256 of "
                        f"the wording the screen shows {shown_hash}"
                    )

        expected_ids = {"article_9_special_category_consent", TICKBOX, "personal_use_only"}
        missing = expected_ids - set(data.get("tickboxes", {}))
        if missing:
            failures.append(f"tickboxes missing from file: {sorted(missing)}")

    install = (ROOT / "install.sh").read_text(encoding="utf-8")
    calls = install.count("ostler_security.consent_cli publish-wording")
    if calls != 1:
        failures.append(f"install.sh has {calls} publish-wording calls, want exactly 1")

    _report(failures)
    return 1 if failures else 0


def _report(failures):
    if failures:
        for f in failures:
            print(f"FAIL: {f}")
    else:
        print("PASS: consent wording hashes are published for the shipped build")


if __name__ == "__main__":
    sys.exit(main())
