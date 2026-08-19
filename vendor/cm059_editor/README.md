# vendor/cm059_editor — The Editor Front Page producer (CM059)

Vendored copy of CM059 "The Editor" Front Page producer. On a schedule it
recompiles the interest profile from the live PWG graph (Oxigraph) and
re-emits `~/.ostler/editor/front_page.{json,html}` — the file the Hub app
Dashboard's `<FrontPageCards>` reads via the `get_front_page` Tauri command.

## Layout

| Path | Origin | Gate-tracked |
|------|--------|--------------|
| `compiler/` | Vendored byte-identical from CM059 `main` (pin in `VENDOR_MANIFEST.toml`) | yes (`vendor_path = vendor/cm059_editor/compiler`) |
| `bin/editor-frontpage-tick.sh` | CM051-authored LaunchAgent wrapper | no |
| `launchd/com.creativemachines.ostler.editor-frontpage.plist` | CM051-authored | no |
| `INSTALL_SNIPPET.sh` | CM051-authored installer hook | no |

## How it is installed

`install.sh` phase `3.14d-editor` resolves this dir (bundled
`${SCRIPT_DIR}/cm059_editor` on a productised `.app`, or
`${SCRIPT_DIR}/../vendor/cm059_editor` on a dev install), then runs
`INSTALL_SNIPPET.sh`, which:

1. stages `compiler/` under `~/.ostler/services/cm059-editor/`,
2. renders `bin/editor-frontpage-tick.sh` into `~/.ostler/bin/` (substituting
   the resolved `python3` and the staged source dir),
3. renders the plist into `~/Library/LaunchAgents/`, and
4. `launchctl bootstrap`s it. `RunAtLoad` fires the first emit immediately.

`gui/project.yml` copies this dir into the app Resources so the bundled path
exists on a real DMG install.

## Producer notes

- **Stdlib only.** No third-party deps, no Ollama, no Docker. One read-only
  SPARQL SELECT + in-process scoring; sub-second.
- **Never blanks.** Graph down / mid-hydration → a graceful "still settling
  in" card (`phase: hydrating`); ≥6 interests → `steady` interest cards.
- **Entrypoint:** `python3 -m compiler.emit_frontpage` (see the module's
  docstring for env overrides: `OSTLER_EDITOR_DIR`, `OSTLER_OXIGRAPH_URL`,
  `OSTLER_HYDRATION_PROGRESS_FILE`, …).

## Re-vendoring

Update `pinned_sha` in `vendor/VENDOR_MANIFEST.toml` and re-run
`scripts/sync_vendor.sh` / `scripts/verify_vendor_fresh.sh`. Set
`VENDOR_SRC_CM059_EDITOR=/path/to/CM059-Ostler-Editor` (or `export CM059=…`)
so the freshness gate can materialise the source at the pin.
