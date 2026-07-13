# Installer platform seam — porting guide

**Status:** groundwork only. Ostler v1 is **single-machine and Mac-only** — a
locked architectural directive (2026-05-09, `CM044 CLAUDE.md`; reaffirmed by
`CROSS_PLATFORM_INSTALLERS_SPEC.md` §1/§11, which states that broadening
"the machine" beyond the Mac is an amendment **only Andy can make**, and that
no port work is cleared to build before that ruling plus the §12 buyer
decision — consumer Windows vs air-gapped sovereign Linux). This directory
therefore contains exactly one implementation, `macos.sh`, and the installer
does not probe the OS. Nothing here ships, or may ship, a second platform.

What this seam *is*: the macOS-specific operations of `install.sh`, extracted
behind named `platform_*` functions so that (a) the main install flow reads
platform-neutrally today, and (b) a future, separately-authorised port
implements one documented function inventory instead of excavating a
16,000-line script.

**Refactor guarantee:** every function body in `macos.sh` is a byte-for-byte
transplant of code that previously sat inline in `install.sh`. The seam
changed where the Mac primitives live, never what they do: same commands,
same redirections, same failure masking, same MSG_* strings, same phases and
step catalogue.

---

## 1. How the module is loaded

`install.sh` sources the platform module immediately after the strings
catalogue / GUI emitter / model-fit helpers, with the same resolution shape:

1. `${OSTLER_PLATFORM_MODULE}` — explicit env override (tests, staging)
2. `${SCRIPT_DIR}/platform/macos.sh` — tarball / dev checkout / curl|bash
   bootstrap / `.app` bundle (`Contents/Resources/platform/macos.sh`)
3. `${HOME}/.ostler/platform/macos.sh` — post-install re-run fallback

A missing module is a **packaging bug** and install.sh hard-fails loudly
(exactly like a missing strings catalogue). Three packaging surfaces ship it:

| Surface | Mechanism |
|---|---|
| Release tarball | `release.sh` `CM051_SOURCES` includes `platform` |
| `.app` bundle | `gui/project.yml` "Bundle install.sh + lib/…" postBuildScript copies it to `Contents/Resources/platform/macos.sh` |
| CI gate | `scripts/check_install_sh_script_dir_coverage.py` needle `platform/macos.sh` fails the build if the postBuildScript copy line disappears |

Sourcing must remain **side-effect-free**: the module defines functions only,
prints nothing, reads nothing at load time, and is safe under
`set -Eeuo pipefail` and `set -u`.

---

## 2. The function inventory a port implements

Contracts below are what `install.sh` relies on. "Best-effort" means the
function must never propagate failure (the macOS bodies end `|| true`);
"reporting" means the exit status is the caller's branch condition.

### Service supervision

The port's largest seam. macOS = per-user launchd LaunchAgents;
per `CROSS_PLATFORM_INSTALLERS_SPEC.md` §7.1 the analogues are systemd
`--user` units (Linux) and a per-user Service / Scheduled Task (Windows).

| Function | Contract | macOS today |
|---|---|---|
| `platform_service_dir` | echo the directory holding per-user service definitions (no trailing newline) | `~/Library/LaunchAgents` |
| `platform_service_load <definition>` | register + start; best-effort | `launchctl bootstrap` then legacy `load`, masked |
| `platform_service_load_check <definition>` | register + start; reporting | same, unmasked |
| `platform_service_bootstrap <definition>` | register + start, modern verb only, stderr visible; reporting | `launchctl bootstrap` |
| `platform_service_bootstrap_check <definition>` | register + start, modern verb only, stderr masked; reporting | `launchctl bootstrap 2>/dev/null` |
| `platform_service_unload <label>` | stop + unregister by label; best-effort | `launchctl bootout` |
| `platform_service_unload_fallback <label>` | stop + unregister with legacy fallback against `$(platform_service_dir)/<label>.plist`; best-effort | `bootout` then `unload` |
| `platform_service_restart <label>` | restart a running service in place; best-effort | `launchctl kickstart -k` |

**Known residue (deliberate, see §4):** the service *manifests* themselves are
still launchd plist heredocs inside `install.sh`, and the labels remain
reverse-DNS strings (`com.ostler.*`, `com.creativemachines.ostler.*`). A port
adds a manifest-rendering function per OS (plist → systemd unit / scheduled
task XML); that extraction is a later wave because each of the ~15 manifests
carries bespoke keys (`StartInterval`, `RunAtLoad`, `ThrottleInterval`,
log paths…) that are asserted byte-for-byte by the installer test suite.

### Permissions

| Function | Contract | macOS today |
|---|---|---|
| `platform_has_full_disk_access <probe-db>` | 0 = broad file access granted (or nothing to probe), 1 = denied; never raises | sqlite3 read of a TCC-gated store, grepping the denial signature (CX-103) |
| `platform_open_fda_pane` | open the OS UI where the user grants broad file access; best-effort | System Settings → Privacy → Full Disk Access |
| `platform_open_automation_pane` | open the OS UI for automation/scripting consent; best-effort | Privacy → Automation |
| `platform_open_internet_accounts_pane` | open the OS UI where mail/calendar accounts are connected; best-effort | Internet Accounts pane |

On platforms without a TCC analogue, `platform_has_full_disk_access` may
legitimately be a constant success — the port decides per its consent model.
Note the deeper truth from the spec (§3): most of what FDA *guards* (iMessage,
Apple Mail, Safari history) simply does not exist off the Mac, so the port's
permission story is about its own per-OS source adapters, not a shim of TCC.

### Power

| Function | Contract | macOS today |
|---|---|---|
| `platform_has_battery` | 0 when the machine is battery-powered (laptop) | `pmset -g batt` percentage probe |
| `platform_power_source` | echo `AC Power` / `Battery Power` / nothing when undetectable | `pmset -g batt` |

Linux: `/sys/class/power_supply`; Windows: `GetSystemPowerStatus` via
PowerShell. Callers only branch on "laptop on battery during the long
Phase 3 run" warnings and the battery watcher.

### Hardware

| Function | Contract | macOS today |
|---|---|---|
| `platform_ram_gb` | echo installed RAM in whole GB | `sysctl hw.memsize` |

Linux: `/proc/meminfo`; Windows: `GlobalMemoryStatusEx`. Feeds the model-fit
picker (`lib/ostler-model-fit.sh`, which is already pure logic over this
number) and the `--check` prerequisites.

### Installer trust

| Function | Contract | macOS today |
|---|---|---|
| `platform_app_signature_info <path>` | echo human-readable signing details; never fail | `codesign -dv --verbose=4` |
| `platform_verify_app_signature <path> <log1> <log2>` | verify vendor signature AND OS trust assessment, stderr to caller logs; reporting | `codesign --verify --deep --strict` + `spctl --assess` |

Per spec §7.2 the analogues are Authenticode (Windows) and GPG-signed
packages (Linux). The *caller-side* authority checks (grepping for
`Authority=Developer ID Application`) are still in `install.sh` and would be
generalised in the wave that first needs them.

### Path layout (reference)

| Function | Contract |
|---|---|
| `platform_engine_dir` | echo the private Engine-zone root (`~/.ostler`) |
| `platform_visible_dir` | echo the Visible-zone vault root (`~/Documents/Ostler`) |

Provided for new code and the future port; `install.sh`'s historical path
plumbing (`_ostler_set_paths`) is **not yet routed through these** (§4). The
two-zone layout itself is preserved on every platform per spec §7.1; on
Windows the `0700`-equivalent story is ACL-based and belongs behind these
functions when the plumbing moves.

---

## 3. How a port would slot in (when — and only when — authorised)

1. Add `platform/<os>.sh` implementing every function in §2 (the guard test
   `tests/test_platform_seam.sh` asserts the inventory of `macos.sh`; extend
   it to each new implementation so the inventories can never drift apart).
2. Extend the selection block in `install.sh` (today it hardcodes `macos.sh`
   by design — resist adding an OS probe before the directive is amended).
3. Port the packaging surfaces in §1 to the platform's artefact
   (MSI/`.deb`/offline bundle per spec §7.2) so the module always travels
   with `install.sh`.
4. Work through §4's residue in dependency order: manifest rendering first
   (services are load-bearing), then secrets, then the permission UX.

## 4. Not yet behind the seam (documented residue)

Deliberately left inline in `install.sh`, in rough order of porting effort:

- **Service manifests** — the ~15 launchd plist heredocs (see §2 note).
- **Secret storage** — the recovery-key save is a macOS Keychain
  multi-strategy block (Swift `SecItemAdd` helper, `security
  add-generic-password` fallback, MSG-driven user guidance). The PAL row is
  Secret Service / DPAPI / encrypted-file per spec §7.1; extracting
  `platform_secret_store`/`platform_secret_get` is the natural next wave but
  touches customer-visible copy, so it was not folded into this pure
  refactor.
- **Permission-grant UX** — the FDA-assist flows (`_fda_read_probe`,
  FDA_ASSIST_TRIGGER ordering, osascript modals, `tccutil` resets) are
  macOS-shaped end to end and heavily test-anchored; the *panes* and the
  *probe* are behind the seam, the choreography is not.
- **Generated agent scripts** — everything written via heredoc into
  `~/.ostler/bin/*` (export scan, dedupe catch-up, contact resync, wiki
  recompile tick, uninstaller…) runs standalone post-install and deliberately
  embeds raw `launchctl`/`osascript`/`pmset`. Porting those means porting the
  generators, one per service, alongside the manifest work.
- **macOS-only ecosystem steps** — Homebrew/Colima/Docker bootstrap,
  `osascript` dialogs and app activation, Apple-app quit/open choreography,
  `sudo pmset` sleep configuration, Spotlight/Finder integration, and the
  Apple source readers (iMessage, Apple Mail, Safari, Contacts/Calendar,
  Notes, Photos). Per spec §3 these have **no analogue to port** — a port
  replaces them with its own per-OS source adapters (§4 of the spec) rather
  than reimplementing these steps.
- **Path plumbing** — `_ostler_set_paths` and friends (see §2 "Path layout").

## 5. Verification contract for any change here

- `bash -n install.sh platform/macos.sh` — syntax.
- `bash tests/test_platform_seam.sh` — module sourced, hard-fail present,
  inventory complete, side-effect-free sourcing under `set -u`.
- The installer bash suite (`tests/test_*.sh`) and the install.sh↔GUI
  contract tests (`tests/test_install_gui_contract*.py`) — the refactor must
  keep the Mac path byte-behaviour-identical: same MSG keys, same phases,
  same step catalogue, same launchctl/pmset/codesign invocations after
  function inlining.
- `python3 scripts/check_install_sh_script_dir_coverage.py --mode ci` — the
  module is shipped by every packaging surface.
