import argparse, json, sys
from . import importer

p = argparse.ArgumentParser(prog="meeting_import")
p.add_argument("--root"); p.add_argument("--out")
p.add_argument("--private", action="store_true", help="mark every imported meeting L3")
p.add_argument("--push-reminders", action="store_true", help="opt in: queue action items for Reminders")
a = p.parse_args()
from pathlib import Path
r = importer.import_all(root=Path(a.root) if a.root else None, out_root=Path(a.out) if a.out else None,
                        privacy_level="L3" if a.private else None, push_reminders=a.push_reminders)
print(json.dumps({k: v for k, v in r.items() if k != "folders"}))
sys.exit(0 if r["status"] in ("ok", "disabled") else 1)
