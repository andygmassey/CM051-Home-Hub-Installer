# Vendored: generate_pwg_context.py

`bin/generate_pwg_context.py` is vendored byte-for-byte from the
`ostler-assistant` repository. It is the personal-context digest
generator that gives the local assistant baseline awareness of the
customer's people, meetings, and preferences without the 9B local
model having to call a tool every turn.

| Field | Value |
|-------|-------|
| Upstream repo | `ostler-ai/ostler-assistant` |
| Upstream path | `scripts/generate_pwg_context.py` |
| Upstream commit | `f441f09f` (feat(assistant): inject personal-graph CONTEXT.md digest + lookup guidance) |
| SHA-256 | `58d0c5e31d899ad994fb9413bd8d6d511d27433c84acaf01cff7119b2254a613` |
| Vendored | 2026-06-02 (v1.0.1 launch-blocker #608) |

## Why vendored rather than shipped in the assistant release

The assistant release tarball (`release/build-binary.sh` +
`release/wrap-in-app-bundle.sh`) bundles the daemon binary and its
`.app` wrapper only; it does not carry `scripts/`. The installer is
the half that owns the LaunchAgent wiring (the script's own docstring
says "the CM051 installer wires a LaunchAgent that calls this"), so
the script has to reach the customer's disk through CM051. Vendoring a
byte-identical copy is the self-contained launch-fix and mirrors the
existing `vendor/` pattern in this repo.

## Post-launch follow-up

Dedupe by adding `scripts/generate_pwg_context.py` to the assistant
release bundle and having CM051 reference the extracted path, removing
this copy. Tracked as a post-launch tidy; not a launch blocker.

## Refresh procedure

```sh
cp /path/to/ostler-assistant/scripts/generate_pwg_context.py \
   context-refresh/bin/generate_pwg_context.py
shasum -a 256 context-refresh/bin/generate_pwg_context.py   # update the table above
```

Pure Python standard library (urllib, json, pathlib, datetime); no
pip dependencies, so it runs under any `python3` on the customer Mac.
