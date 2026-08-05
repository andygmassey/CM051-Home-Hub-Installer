# CUT_ASSEMBLY — v1.0.14.1 (daemon re-cut)

**Living cut doc.** Every SHA, command, hash, and decision for the v1.0.14.1 re-cut.
Companion script: `recut-v1.0.14.1.sh` (deterministic, stage-skippable — full *or* incremental re-cut in one command).

---

## Why this cut exists
v1.0.14 DMG (`OstlerInstaller-1.0.14.dmg`, sha `e16f4c4e…`) passed signing + notarisation + frontend-commit **parity**, then **failed the box-walk at the final install step**:

```
ERR-11-DAEMON-RUN-SOURCE-SKEW — bundled daemon v0.4.50 does not support the
'run-source' command this installer needs to route ingest through Full Disk Access.
```

**Root cause = the integration→main lineage split.** `run-source` (a v1.0.10 daemon feature, commit `96e4e810`) lived **only on `integration`**, never forward-ported to `origin/main`. The v1.0.14 daemon was built **main-ward** (so it had the QR pairing fix + parity sentinels, but inherited main's *missing* `run-source`). No cut gate tests the daemon's command surface → it shipped. install.sh's own preflight caught it, but on the customer's Mac after a 40-min install.

**Fix = reconcile + rebuild + capability-gate + re-cut, fully scripted.**

---

## Versions / identities
| thing | value |
|---|---|
| Daemon (bin `zeroclaw`, pkg `zeroclawlabs`) | **v0.4.51** (was v0.4.50) |
| DMG | **OstlerInstaller-1.0.14.1.dmg** (was 1.0.14) |
| Signing identity | `Developer ID Application: Creative Machines Limited (V95N2B8X7A)` |
| Notary profile | `ostler-notary` |
| Daemon reconcile branch | ostler-assistant `reconcile/run-source-onto-main` (worktree `~/Developer/oa-reconcile`) |
| Kill-layer branch | CM051 `killgate/bom-kill-layer` off `origin/main` `23ca749` (worktree `~/Developer/cm051-killgate`) |

---

## Stage log  (✅ done · ⏳ running · ⬜ pending)

### 1. Daemon reconcile ✅  (2026-08-05)
Base: ostler-assistant `origin/main` = `cf82dab8` — has QR pairing route stubs + parity sentinels (#226) + all v1.0.14 GUI/build fixes, but **LACKS `run-source`**.
Cherry-picked the v1.0.10 ingest-reroute cluster onto it — **clean, 0 conflicts**:

| new SHA | orig | commit |
|---|---|---|
| `22f19227` | `96e4e810` | run-source subcommand (`src/main.rs` +160/-1) |
| `447b79b0` | `cea9220e` | 10 sealed ingest-reroute tick scripts |
| `31771e8c` | `af64ade4` | daemon owns colima lifecycle |
| `9ae7537f` | `3d965cd3` | colima start/status timeouts |

Result: `reconcile/run-source-onto-main` has **both halves** for the first time; `run-source` present in `src/main.rs`.

**WHY a bounded graft, not the 113-commit `integration`→`main` merge:** supersede-rot rule — a full merge drags back old code main has since evolved. We graft only the cluster install.sh needs; the **capability gate provides the completeness guarantee** (asserts every subcommand install.sh calls is present in the built binary).

### 2. Daemon rebuild ✅  (2026-08-05 13:26→13:35, exit 0)
`release/build-binary.sh 0.4.51` → npm web build → `cargo build --release --locked` → `target/release/zeroclaw` (14M) + `ostler-assistant-aarch64-apple-darwin-v0.4.51.tar.gz` (8.4M, wraps `OstlerAssistant.app` incl. the grafted ingest tick scripts) + `.sha256` + build-info sidecar. **Graft compiled CLEAN — no semantic drift** (v1.0.10 code sits fine on current main). Log: `cut/daemon-build-0.4.51.log`.

### 3. KILL-LAYER GATE — capability ✅ GREEN  **← the ERR-11 killer, proven both ways**
`scripts/verify_daemon_capability.sh --daemon target/release/zeroclaw` → **exit 0**: `run-source` ✓ (+imessage/fda-rerun/aiconv), `daemon` ✓, `setup` ✓, `doctor` ✓ → "cut may proceed." Same gate was **RED** (exit 1, MISSING run-source) on the shipped v0.4.50. ERR-11 fix mechanically verified at the daemon level.

### 4. Sign + notarise daemon ⏳
`release/sign-and-notarize.sh <OstlerAssistant.app>` — env `OSTLER_SIGNING_IDENTITY="Developer ID Application: Creative Machines Limited (V95N2B8X7A)"`, `OSTLER_NOTARY_KEYCHAIN_PROFILE=ostler-notary`, `OSTLER_NOTARY_TEAM_ID=V95N2B8X7A`.
🔴 **REPRODUCIBILITY GOTCHA:** the tar round-trip re-introduces AppleDouble / resource-fork detritus → `codesign` fails *"resource fork … not allowed"* and never reaches notarise (leaves the .app signed-but-not-stapled — caught by `stapler validate`). **`xattr -cr` alone is INSUFFICIENT.** Hard-clean first: `find <app> -name '._*' -delete; dot_clean -m <dir>; xattr -cr <app>` — then sign. (recut.sh stage 4 will encode this once green.)

### 5. Stage into CM051 + re-pin ⬜
4 pin sites: install.sh `OSTLER_ASSISTANT_VERSION` ×2 + gui/Makefile `DAEMON_VERSION` + `DAEMON_SHA256`.

### 6. DMG re-cut ⬜
`make -C gui ship` (self signs/notarises/staples/packages) → `OstlerInstaller-1.0.14.1.dmg` in `DIST_DIR=/tmp/ostler-installer-dist-$USER`.

### 7. Cut gates on the assembled DMG ⬜
`verify_daemon_capability.sh --dmg <dmg>` **[NEW — wired AHEAD of `notarise-app`]** + `verify_commit_parity.sh` + existing cut gates.

### 8. Verify + box-walk ⬜
`spctl` accept, `stapler validate`, then install on the Mini (`andy@192.168.1.200`) to completion — **must reach the daemon stage with NO ERR-11** and pair.

---

## Decision log
- **2026-08-05** — bounded graft chosen over full integration→main merge (supersede-rot risk mid-launch). Capability gate = the completeness guarantee. Full reconcile filed as post-launch debt (ends the split forever).
- **2026-08-05** — kill-layer (BOM slice, #631) **BLOCKS** the re-cut, not "rides with" it. Capability gate built + proven-red first; the re-cut is the first cut that must pass it.

## Reproduce / incremental
`bash recut-v1.0.14.1.sh [--from <stage-number>]` — stages idempotent; re-run whole or from any point.
