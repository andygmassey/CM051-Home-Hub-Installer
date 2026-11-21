"""python -m crm_contacts <export.csv> [<out.vcf>]

Writes "<name> (for Contacts).vcf" beside the export. Open it (double-click)
to add the people to Contacts; Ostler reads them from Contacts.
Exit 0 written / 1 not a Dex or Mesh export / 2 unreadable.
"""
import sys
from pathlib import Path

from . import LABELS, convert, read_csv

if len(sys.argv) not in (2, 3):
    print(__doc__, file=sys.stderr)
    sys.exit(2)
src = Path(sys.argv[1]).expanduser()
dst = Path(sys.argv[2]) if len(sys.argv) == 3 else src.with_name(f"{src.stem} (for Contacts).vcf")
try:
    kind, _ = read_csv(src)
    n = convert(src, dst)
except ValueError:
    print(f"{src.name}: not a Dex or Mesh contacts export", file=sys.stderr)
    sys.exit(1)
except (OSError, UnicodeDecodeError) as exc:
    print(f"{src.name}: could not read it ({type(exc).__name__})", file=sys.stderr)
    sys.exit(2)
print(f"{n} contact{'s' if n != 1 else ''} from {LABELS[kind]} written to {dst}. "
      "Open that file to add them to Contacts; Ostler reads them from there.")
