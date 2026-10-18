"""python -m meeting_import [--root DIR | --loose DIR] [--out DIR] [--private] [--push-reminders]

--root   a drop folder laid out as <root>/<source>/... (default ~/Documents/Ostler/Imports)
--loose  a flat folder such as ~/Downloads; each file's source is detected from
         its documented name or content, and anything unattributable is left alone
Writes the Doctor's record to ~/.ostler/state/hydrate/meetings.done.
"""
import argparse
import json
import sys
from pathlib import Path

from . import importer

p = argparse.ArgumentParser(prog="meeting_import")
g = p.add_mutually_exclusive_group()
g.add_argument("--root")
g.add_argument("--loose")
p.add_argument("--out")
p.add_argument("--private", action="store_true", help="mark every imported meeting L3")
p.add_argument("--push-reminders", action="store_true", help="opt in: queue action items for Reminders")
a = p.parse_args()
root = Path(a.loose or a.root).expanduser() if (a.loose or a.root) else None
r = importer.import_all(root=root, loose=bool(a.loose), out_root=Path(a.out) if a.out else None,
                        privacy_level="L3" if a.private else None, push_reminders=a.push_reminders,
                        sentinel_dir=importer.default_sentinel_dir())
print(json.dumps({k: v for k, v in r.items() if k != "folders"}))
sys.exit(0 if r["status"] in ("ok", "disabled") else 1)
