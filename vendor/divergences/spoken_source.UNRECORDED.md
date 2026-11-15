# spoken_source: vendored edits NOT in the divergence patch

**Written 2026-11-11, CM051 #3429 (user-facing root moved to `~/Ostler`).**
**Location and shape only, never content.**

## Why there is no patch, measured rather than assumed

`scripts/regenerate_divergence_patch.sh spoken_source` (dry run, 2026-11-11, HR015
exported to the local checkout) proposes a 6-file patch, 407 lines added and 24 removed,
against an on-disk patch of 1207 lines. The on-disk patch already carries the `_ostler_run`
change (grep count 3), so the proposal is mostly the on-disk content plus #3429's path
edits. The tool truncates its diff-of-diffs, so that is NOT verified line by line here.
Writing would replace the whole patch, so it was not written. The on-disk patch is unchanged.

## The edits, by location and shape (`~/Documents/Ostler` -> `~/Ostler`)

- `reader.py` (4 edits, CODE): `return Path.home() / "Ostler" / "Transcripts"` is the
  default transcripts root; the rest are docstring lines.
- `bin/spoken-bundle-tick.sh` (3 edits): the `TRANSCRIPTS_DIR` default
  (`${OSTLER_TRANSCRIPTS_DIR:-$HOME/Ostler/Transcripts}`) and two comment lines.
- `pipeline.py` (2 docstring edits), `__init__.py` (1 docstring edit),
  `INSTALL_HANDOFF_SPEC.md` (4 prose edits), `launchd/com.creativemachines.ostler.spoken-bundle.plist`
  (2 plist text lines).

## Upstream

NO PR. The pin `d06d80e3` is not reachable from HR015 `main`; it sits only on the
archived tag `archive/2026-08-06/...`. A PR would re-add an archived tree to main, which
is out of scope for #3429. Blocked until someone decides whether this tree lives on main.
