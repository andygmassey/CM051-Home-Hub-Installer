# .vendor-manifests/

Per-vendor-tree GitHub-source resolvers for the vendor-drift-check workflow
(`.github/workflows/vendor-drift-check.yml`).

## Why this exists alongside `vendor/VENDOR_MANIFEST.toml`

`vendor/VENDOR_MANIFEST.toml` is the single source of truth for the vendor
CONTENT gate (`scripts/verify_vendor_fresh.sh` and `scripts/sync_vendor.sh`).
It carries every field the content gate needs: source_repo alias (like
`$HR015/doctor`), source_path, pinned_sha, divergence_patch, exempt reason.

The alias fields resolve to a LOCAL checkout by design -- the content gate
compares vendored bytes against `git show <alias>:<path>`, not against
GitHub. That works on the cut host where every source repo is checked out,
but not from GitHub Actions where nothing is checked out.

`.vendor-manifests/` maps each vendor tree's `name` to a GITHUB owner + repo
+ branch + path, so a scheduled GHA job can ask
`gh api repos/{owner}/{repo}/commits/{branch}?path=` and compare the pinned
SHA against upstream HEAD. That's the drift check.

`pinned_sha` is NOT duplicated here -- the workflow reads it live from
`vendor/VENDOR_MANIFEST.toml` at check time, so the two files cannot drift
out of sync.

## Schema

```yaml
name: <vendor tree name, matches VENDOR_MANIFEST.toml [[tree]].name>
github:
  owner: <GitHub owner slug, or `<UNKNOWN -- retrofit needed>`>
  repo:  <GitHub repo slug,  or `<UNKNOWN -- retrofit needed>`>
  branch: <default branch to compare against, usually `main`>
  path:  <path within the source repo, matches VENDOR_MANIFEST.toml source_path>
notes: <optional free text>
```

## UNKNOWN entries

Trees whose upstream source is a private local checkout (not on GitHub under
any owner we can enumerate) are marked with `<UNKNOWN -- retrofit needed>` in
`owner` and `repo`. The workflow SKIPS these with a WARN in the summary, so
the gate remains honest until the source lineage is wired up.

Retrofit workflow when a source moves to GitHub: replace the UNKNOWN owner +
repo values with the real ones; the drift check goes live automatically on
the next scheduled run.
