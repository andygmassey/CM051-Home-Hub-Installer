# install.sh idempotency + "re-run to update" (Phase 1)

WORKSTREAM C / C3. Single-machine Ostler updates are pull-based. The Phase
1 update mechanism is simply **re-running `install.sh`**: it must update
CODE in place while leaving the user's DATA untouched. This document is
the audit of whether that is safe today, what was verified, and the one
fix this PR makes.

## The structural guarantee

Durable DATA (the markdown vault + Oxigraph + Qdrant under named Docker
volumes + the encryption DEK) is cleanly separated from replaceable CODE
(the vendored pipelines, the doctor agent, the daemon, the wiki images).
A re-run is a CODE SWAP; the data survives by construction. No re-run
rebuilds or migrates the graph as a precondition.

## Audit findings

Verified against `install.sh` on `origin/main` (HEAD 842591b). Two
recon-stage claims were **refuted** on inspection; the data-preservation
guards were confirmed sound.

### Confirmed SAFE to re-run

| Phase / step | Mechanism | Why safe |
|---|---|---|
| Prereqs (Phase 1) | read-only probes | no writes |
| Questionnaire (Phase 2) | `SKIP_PHASE2` reads `~/.ostler/config/.env` | re-run reuses saved answers; never re-asks |
| Config `.env` | `grep -v` filter then append | prior `JWT_SECRET` / `USER_FIRST_NAME` line stripped before re-append -- no duplication |
| Encryption / DEK | skip-guard | if `passkey.json` **or** `keychain.json` exists, the whole encryption setup is skipped -- the DEK (and thus the data) is preserved (install.sh:3484, :6360) |
| Docker volumes | named volumes `qdrant_data` / `oxigraph_data` / `redis_data` / `wiki-docs` | `docker compose up` reuses existing volumes -- the graph is never re-initialised |
| Docker images | `compose pull` + `up -d` | idempotent by Docker's design |
| launchd plists | `cat >` heredoc overwrite, plus unload + `rm -f` before rewrite | no duplicate agents; clean replace |
| Vendored code (pipeline / doctor / knowledge / cm048) | bundled `cp -R` from `${SCRIPT_DIR}`, `rm -rf` + fresh copy, or `git pull` on an existing clone | clobber-and-replace of CODE dirs -- this IS the code swap; data lives in volumes, not these dirs |
| Shell RC PATH | both the bash/zsh and the fish blocks are guarded by `grep -q "ostler/bin"` | no duplicate PATH entries on re-run |
| Homebrew / venv | `if ! brew list` / `if [[ ! -d "$OSTLER_VENV" ]]` guards | conditional, no rework |
| iMessage TCC marker | `cat >` overwrite of `state.md` | clean replace |

### Refuted recon claims

- **"Shell-RC PATH append is unguarded -> duplicates on re-run."** FALSE.
  Both the `zsh`/`bash` block (install.sh ~8801) and the `fish` block
  (~8790) are wrapped in `! grep -q "ostler/bin" "$RC"` guards. No fix
  needed.
- **"Early git clones (pipeline / cm048) fail on re-run."** FALSE for the
  shipping path. The pipeline step prefers a bundled `cp -R` from the DMG
  and only falls to a clone for dev/`*_REPO`-override installs; an
  existing dir takes the `elif ... git pull` branch. cm048 resets-hard an
  existing repo. Both are re-run safe.

### Confirmed re-run safe by THIS PR

- **Release manifest emit.** `emit_release_manifest` (Phase 4) writes
  `~/.ostler/ostler-release.json` atomically (temp + `mv`), so a re-run
  refreshes the deployed-version record in place. It never aborts the
  install (soft no-op when its lib is absent).
- **lib staging.** `lib/release_manifest.sh` is copied into
  `~/.ostler/lib/` (overwrite) so a post-install re-run can still source
  the emitter even from a tree without the bundled lib.

## The re-run-as-update flow (Phase 1)

```
# Customer has a newer DMG / tarball. To update in place:
#   1. Mount the new DMG (or extract the new tarball).
#   2. Run the bundled install.sh exactly as for a first install.
#      - Phase 2 is skipped (saved answers in ~/.ostler/config/.env).
#      - Encryption is skipped (existing passkey/keychain.json).
#      - Docker volumes (the graph) are reused untouched.
#      - Vendored code dirs + the daemon + the wiki image pins are
#        re-staged from the new bundle -- the code swap.
#      - The manifest is re-emitted with the new versions.
#   3. Doctor's "Deployed version" tile now shows the new version.
```

No data is wiped, no graph is migrated, no question is re-asked. This is
the floor that the Phase 2 Hub "Check for updates" button (see
`HR015/artefacts/2026-06-16/CUSTOMER_UPDATE_PHASE2_DESIGN.md`) drives as its apply step.

## Residual gaps (not blocking Phase 1, flagged for Phase 2)

- A dedicated `install.sh --update` intent flag would make the code-swap
  semantics explicit rather than implicit-via-`SKIP_PHASE2`. Today the
  re-run is safe, but the operator has no single documented "update"
  affordance beyond "re-run the installer".
- The previous manifest is currently overwritten, not retained. Phase 2's
  rollback design wants an `ostler-release.prev.json` kept before
  overwrite. Deferred to the Phase 2 build (out of scope for C3).
