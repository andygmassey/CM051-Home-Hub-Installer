# ARCHIE HANDOFF — assemble v1.0.14.1 DMG

**TL;DR:** v1.0.14.1 = **v1.0.14 + the one missing daemon command**. The daemon fix is done, rebuilt on the correct base, and **capability-gate GREEN**. You assemble the DMG from the v1.0.14 CM051 base (which only you/local have — it's not on origin). ~30 min.

## The bug this fixes
v1.0.14 box-walk failed at the final install step: `ERR-11-DAEMON-RUN-SOURCE-SKEW` — bundled daemon lacked `run-source` (needed to route ingest through FDA). Cause: the main↔integration split — `run-source` (v1.0.10, `96e4e810`) lived only on integration, never forward-ported. The v1.0.14 daemon (`f0312ad3`) was otherwise complete (rebrand + QR + parity) but missing it.

## Artifacts READY (TNM built + validated)
- **Daemon source:** ostler-assistant branch **`reconcile/run-source-onto-f0312`** @ `4bd71cf0` (worktree `~/Developer/oa-reconcile-v2`) = `f0312ad3` + cherry-picks `96e4e810 cea9220e af64ade4 3d965cd3` (clean, 0 conflicts). Carries `ostler-hub` rebrand.
- **Built daemon:** `~/Developer/oa-reconcile-v2/target/release/zeroclaw` + tarball `~/Developer/oa-reconcile-v2/ostler-assistant-aarch64-apple-darwin-v0.4.51.tar.gz` — **UNSIGNED** (build-binary.sh = adhoc). Capability-gate GREEN, run-source present, ostler-hub lineage confirmed.
- **The cycle-breaker gate:** `~/Developer/cm051-killgate/scripts/verify_daemon_capability.sh` — asserts the daemon supports every subcommand install.sh invokes (run-source{imessage,fda-rerun,aiconv}, daemon, setup, doctor). Proven RED on the broken v0.4.50, GREEN on this one. **Wire it into `make ship` ahead of `notarise-app`** (it's #631's #1 primitive; blocks this class forever).

## Assembly steps
1. **Sign daemon** (v0.4.51): extract the tarball's `OstlerAssistant.app` in **`/tmp`** — NOT `~/.ostler-release-artefacts` (that's a **file-provider dir that re-stamps `com.apple.FinderInfo`**, so codesign fails "resource fork … not allowed"). Hard-clean: `find <app> -name '._*' -delete; dot_clean -m; xattr -cr; xattr -d com.apple.FinderInfo <app>`. Then `OSTLER_SIGNING_IDENTITY="Developer ID Application: Creative Machines Limited (V95N2B8X7A)" OSTLER_NOTARY_KEYCHAIN_PROFILE=ostler-notary OSTLER_NOTARY_TEAM_ID=V95N2B8X7A release/sign-and-notarize.sh <app>`. Re-tar `COPYFILE_DISABLE=1 tar czf`. Stage tarball + `.sha256` at `~/.ostler-release-artefacts/`. Record `DAEMON_SHA256`.
2. **Build wrapper:** `cargo tauri build` in `~/Developer/oa-reconcile-v2/apps/tauri` → `Ostler.app` at `.../target/release/bundle/macos/Ostler.app`. It stamps the **same `WRAPPER_FRONTEND_COMMIT` as the daemon** (both built from `4bd71cf0`) → parity passes.
3. **CM051 base — YOUR provenance:** use the **v1.0.14 (ostler-hub) CM051 installer** clone/branch (NOT origin/main — it's `zeroclaw-desktop` + behind; not on origin, newest remote = `cut-v1.0.7`). Re-pin the daemon: `gui/Makefile` `DAEMON_VERSION=0.4.51` + `DAEMON_SHA256=<step 1>`; `install.sh` `OSTLER_ASSISTANT_VERSION` default `0.4.51`; `Info.plist` `CFBundleShortVersionString=1.0.14.1`.
4. **Cut:** `make -C gui ship OSTLER_APP_PATH=~/Developer/oa-reconcile-v2/target/release/bundle/macos/Ostler.app` → `/tmp/ostler-installer-dist-$USER/OstlerInstaller-1.0.14.1.dmg`.
5. **Gates (fail-closed):** `verify_daemon_capability.sh --dmg <dmg>` + `verify_commit_parity.sh <dmg>` + existing cut gates. A1 no-codename must pass (this is why origin/main was wrong).
6. **Stage:** spctl accept + stapler validate, then `scp <dmg> andy@192.168.1.200:~/Downloads/`. **Andy runs the box-walk** (install → must reach daemon stage with NO ERR-11 → pair). Ship-go is Andy's.

## Full detail
`project_v1014_1_recut_state.md` (memory) · `cut/CUT_ASSEMBLY_v1.0.14.1.md` · `cut/recut-v1.0.14.1.sh`. Everything is LOCAL — nothing pushed or shipped.
