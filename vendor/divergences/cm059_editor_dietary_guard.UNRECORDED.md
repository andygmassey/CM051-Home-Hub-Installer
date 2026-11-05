# cm059_editor: the dietary guard (2026-10-23)

Tree `cm059_editor`. Pin NOT moved; this is a DIVERGENCE from source at the pin that
`cm059_editor.patch` does NOT record (regenerating that patch needs the CM059 source
checkout; the edit is two lines and is declared here instead).

Why: the food evidence parser stores grocery diet signals (vegan, halal, gluten free) as
category `dietary` at compartment 0. They must never reach the Front Page, the editor cards
or the brief. `project_preferences.to_triples` projects EVERY preference category into the
graph those read, so without a guard a dietary point would be shown.

- `compiler/project_preferences.py` `to_triples`: a point whose category is `dietary` or
  `diet` is skipped (counted in `skipped`). Line tagged `dietary-guard`.
- `compiler/interest_profile.py` `SENSITIVE_CATEGORIES`: `dietary`, `diet` added, so the
  interest profile classes them L3 outright (health-adjacent, GDPR Art. 9 adjacent). Tagged.
- Proof: `tests/test_dietary_is_never_surfaced.py` (wired in `derived-preferences.yml`); arm 3
  is RED with the guard removed, and arm 4 proves the scanner goes red on a fake reader row
  and on fake card code.
- Retire: when the same two lines land in CM059 and the tree is re-pinned past them.

## 2026-11-05: the editor hands the Hub's owed list to the wiki (graft of CM059 #39)

Tree `cm059_editor`, file `compiler/emit_frontpage.py`, BYTE-IDENTICAL to CM059 main
at 8b37a5e0 (the merge of #39). Each tick writes the /api/v1/reply-debt payload to
`~/.ostler/editor/reply_debt.json` for the CM044 Reply Debt wing (CM044 #421); a
failed fetch is `status: unavailable`. Retire: re-pin cm059_editor to 8b37a5e0 or later.
