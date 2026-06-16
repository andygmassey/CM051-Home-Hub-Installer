# vendor/divergences/

Checked-in patches recording how each vendored tree LEGITIMATELY differs from
its pinned upstream source. The gate (`scripts/verify_vendor_fresh.sh`)
materialises `source_repo @ pinned_sha`, applies the tree's patch here, and
asserts the result equals the vendored tree for every shared file.

A patch captures only the content drift of files present in BOTH source and
vendor -- the house-style edits (en-dash punctuation), extra imports, and small
local adaptations the vendoring step makes. Source-only files (tests/, dev
docs, un-vendored modules) and vendor-only files (grafts like
`subscription_gate.py`, `canonical_name.py`) are out of scope by design.

## Rules

- DO NOT hand-edit these patches. They are generated.
- To pull an upstream fix into a vendored tree, run
  `scripts/sync_vendor.sh <tree>` -- it re-syncs from source, re-applies the
  divergence, regenerates the patch, and bumps the manifest SHA.
- To capture a freshly-introduced legitimate divergence for the CURRENT
  vendor state, run `scripts/sync_vendor.sh <tree> --regen-patch`.
- A patch that fails to apply during the gate means the source has moved under
  it -- that is the signal to re-graft (`sync_vendor.sh <tree>`), not to edit
  the patch.

See `../VENDOR_MANIFEST.toml` for the per-tree source, pinned SHA, and patch
reference, and `../README.md` for the vendoring rationale.
