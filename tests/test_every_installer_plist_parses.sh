#!/usr/bin/env bash
# Every LaunchAgent plist that install.sh renders must parse with Python's
# plistlib, not just with plutil.
#
# Why: launchd (CoreFoundation) is lenient, so `plutil -lint` passes some
# malformed XML, but the walk probes read installed plists with plistlib
# (scripts/box_walk_probes/probes/launchd_no_ephemeral_paths.sh,
# lib/bundle_inspect.py). A double hyphen inside an XML comment is the case
# that prompted this: legal to CF, an ExpatError to plistlib, and it breaks
# those probes on every walk.
#
# Shell expansions are not rendered here, so ${...} inside <integer> becomes 1
# (the only place an unrendered value can't be a string). Everything else is
# parsed exactly as written.
set -uo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import plistlib, re, sys
s = open("install.sh").read()
segs = [(m.start(), m.group(0)) for m in re.finditer(r"<\?xml[^\n]*\n.*?</plist>", s, re.S)]
MIN = 20  # denominator guard: a broken extractor must not read as "all parse"
if len(segs) < MIN:
    print(f"FAIL: found only {len(segs)} plists in install.sh (expected at least {MIN}); the extractor is broken")
    sys.exit(1)
fails = 0
for pos, seg in segs:
    line = s.count("\n", 0, pos) + 1
    rendered = re.sub(r"(<integer>)\s*\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\s*(</integer>)", r"\g<1>1\2", seg)
    try:
        plistlib.loads(rendered.encode())
    except Exception as e:
        fails += 1
        print(f"FAIL install.sh:{line}: {type(e).__name__}: {str(e)[:120]}")
print(f"{len(segs) - fails} of {len(segs)} plists parse with plistlib")
sys.exit(1 if fails else 0)
PY
