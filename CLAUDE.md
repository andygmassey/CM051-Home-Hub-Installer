# CLAUDE.md — CM051 Home Hub Installer

This file provides guidance to Claude Code agents working in this repo.

## Project purpose

CM051 is the installer for the Ostler Hub. Customers buy at https://ostler.ai and
install from the DMG; `OstlerInstaller.app` runs `install.sh`, which verifies the
licence before it touches the machine and refuses without one.

This repo is PUBLIC. Treat every string in it as customer-facing copy.

## Related repos (sibling projects)

- **HR015 - Gaming PC** — parent infra repo, origin of this installer before it was split out. Still the authoritative home for security module, FDA extractors, website, and cross-project tooling.
- **CM050 - Home Hub Update System** — the auto-update pipeline (Sparkle) that maintains the installed Hub over time.
- **CM031 - PWG Companion** — iOS companion app.
- **ZeroClaw** — the Rust agent framework the installer deploys (Mac Mini, repo path varies by user).

## Read before committing

**Every commit in this repo must pass the Rule Zero gate from HR015's PRODUCTISATION_CHECKLIST.md:**

- No real-person names, emails, phone numbers, or conversation transcripts in fixtures
- No committed secrets (.env, SERVER_INFO.md, API keys, signing keys)
- Real-person data in `fixtures_private/` (gitignored) only

The pre-commit hook at `.git/hooks/pre-commit` (symlinked from HR015) enforces this automatically.

## Design principles

1. **This is user-facing public code.** Every line must be reviewable by a beta tester or a security auditor. No internal process noise, no stale personal references, no TODO comments naming real people.
2. **Fail loud, fail early.** If a dependency is missing or a permission is denied, show a clear error with the exact next step. Do not silently degrade.
3. **Idempotent where possible.** Re-running the installer should be safe. Phase 1 always runs; Phase 3 detects already-installed state and skips.
4. **No upload by default.** The installer asks before anything touches the network beyond homebrew / language-ecosystem downloads. Personal data never leaves the user's Mac.
5. **Follow the existing 4-phase structure:**
   - Phase 1: Prerequisites check (automatic, no input)
   - Phase 2: Collect all user input upfront (~2 min)
   - Phase 3: Install unattended (~10-15 min)
   - Phase 4: Health check + next steps

## Current active work

See `PLAN.md` for the current workstream (channel configurator + OAuth for launch).

## Platform assumptions

- macOS only (Intel or Apple Silicon; Apple Silicon recommended for local inference)
- macOS 14+ target (ties to Swift helper binary + passkey support)
- Bash 3.2+ (ships with macOS)
- User-interactive terminal (runs with `/dev/tty` redirect if piped from `curl`)

## Security posture

- Secrets never land in stdout, never in `set -x` output
- User-provided passphrases / tokens are read with `read -s`
- Installer logs are opt-in and written to `$HOME/Library/Logs/Ostler/install-YYYYMMDD-HHMMSS.log`
- No telemetry without explicit consent

## Writing style

- British English in all user-facing messages
- En-dashes ` – ` with spaces, never emdashes
- Short, direct copy; no marketing fluff inside the installer

---

## The walk harness already exists. Do not rebuild it.

Driving `install.sh` on a box is SOLVED, and the tooling is easy to miss
because its documentation lives inside its own header rather than anywhere you
would look first. This file named none of it until 2026-09-07, and an agent
duly started hand-rolling a replacement.

    scripts/ttywalk.sh          drives install.sh over ssh, adjudicates
      -> scripts/walk_drive.py  reactive answer table, answers every prompt
      -> install.sh
    scripts/post_walk_qa.sh     writes walks/<version>.tsv after the install
    scripts/verify_walk_record.sh  read by scripts/publish_release.sh

`walks/README.md` carries the traps in full. The three that bite hardest:
`install.sh` needs a real pty (`exec < /dev/tty` at `:1112`); `OSTLER_GUI=1`
without `OSTLER_GUI_FD` is a state the product never ships, so never set it to
dodge the pty; and use the DMG's bundled `python3.11`, because the box's own
`python3` may be 3.9.6.

**You do not need a tag push to exercise `install.sh`.** Mount the artefact,
take its `Resources` tree, and drive that. A full cut-sign-notarise cycle to
learn one line of shell is the expensive way to find a `head -c 20`.

## 🔴 A WALK FAILURE IS TRIAGED AGAINST HISTORY BEFORE IT IS DIAGNOSED

Andy, 2026-09-07: *"when an installer walk happens, Archie doesn't go back and
look at what changed since the last successful walk and figure out what the
issue is a regression of. He reinvents the whole wheel again, and sometimes
makes matters worse."*

Reinventing is the RATIONAL move when the alternative is reading nine walk
records by hand. So the answer is one command, and it is now mandatory.

**THE PROCEDURE. Do these in this order, every time, before writing a line of
fix code.**

```
1  walk the box, and let post_walk_qa.sh write walks/<version>.tsv
2  scripts/walk_regression_triage.sh <version>
3  paste its verdict into the record, one row per failing probe:
       regression_of<TAB><probe><TAB><v1.0.NN | NEVER-PASSED | CANNOT-CLASSIFY: why>
4  for each REGRESSION row, read the named range FIRST. The cause is in it.
5  only then write the fix
```

`tests/test_a_walk_failure_is_classified.sh` fails the build if a walk record
filed on or after 2026-09-07 names a failing probe with no `regression_of` row.
Silence is not an available answer. The three classifications mean:

    v1.0.NN                 it PASSED there and fails now. The range
                            v1.0.NN..<this walk> CONTAINS the cause. Read it
                            before theorising; `scripts/install_depth.sh
                            --bisect N` turns it into `git bisect run`.
    NEVER-PASSED            no earlier walk records it passing. NOT a
                            regression. Treat as unbuilt, not broken -- and do
                            not go hunting for the commit that "broke" it.
    CANNOT-CLASSIFY: why    the history cannot answer. A real third state, and
                            it must carry a reason. Do NOT name a commit range
                            from a CANNOT-CLASSIFY.

**⚠️ FIVE STATES PER PROBE, AND ONLY ONE IS A BASELINE. THIS IS WHY YOU DO NOT
DO IT BY EYE.** A probe missing from a record's `failed_probe` list has NOT
necessarily passed. It may be in `not_measured_probe`, in `broken_probe` (the
runner refused its verdict), or the record may predate the field entirely.

Measured 2026-09-07, both from real records:

    no_person_holds_two_contact_cards   absent from v1.0.50 and v1.0.51,
                                        passed in NEITHER -- not_measured
    no_store_port_is_tcp_reachable      absent from v1.0.50's failed list,
                                        and v1.0.50 carries
                                        `broken_probe  no_store_port_is_tcp_reachable`

The second one caught the FIRST VERSION OF THIS TOOL out. It read that absence
as a pass and reported a REGRESSION with the range v1.0.50..v1.0.68 -- a range
that contains no such cause. That is the "makes matters worse" outcome, produced
by the very tool meant to prevent it, and it was found by using it on a real
probe rather than by reading the code.

**🔴 AND THE FACT THAT CHANGES THE QUESTION: there has never been a green
walk.** All nine records say `verdict FAILED`. "The last successful walk" does
not exist, so the baseline is PER PROBE and never per walk. Anyone reasoning
from "the last good walk" is reasoning from something that has never happened.

## 🔴 "WHAT SHIPS" IS TEN INPUTS, NOT install.sh

Before you claim a payload delta, run it. Do not reason from
`git log -- install.sh`.

```
scripts/payload_delta.sh <from-ref> [<to-ref>]
```

**MEASURED 2026-09-07, and this is why the tool exists.** The v1.0.74 payload
delta was reasoned out as *"which commits touch install.sh"* plus *"gui/Makefile
builds the DMG and is not in it"*. Both steps are true and neither can see the
other nine inputs. Across `c0401242..origin/main`, **two** payload inputs had
changed:

```
install.sh                    27236c3d
vendor/VENDOR_MANIFEST.toml   ab286995   <- ships as vendor-manifest.toml, and
                                            install.sh:1034 writes it onto the
                                            customer's machine
```

It happened not to matter — the manifest is copied, not branched on — so the
conclusion survived. The METHOD would wave through a launchd plist, a
`services/doctor` bump or a stale `cut-bom.tsv` just as readily, and all three
reach the customer without touching `install.sh`.

The tool parses the input list **from `gui/Makefile`**, never from a hardcoded
copy, because a second source of truth rots exactly like the reasoning it
replaces. If it cannot parse the list it exits **2, CANNOT-RUN** — "no payload
input changed" and "I could not find the payload inputs" print identically and
only one of them is safe.

## 🗿 THE CUT MECHANISM LIVES IN OS003 -- NON-NEGOTIABLE

**Before answering any question about what ships, where a component lives, or whether a fix is in the cut, read `~/Documents/Projects/OS003 - Ostler Release`.** It is the canonical cut mechanism, cut register and release truth. Do not infer the answer from this repo's scripts or their defaults -- `release.sh`'s `HR015_DIR` sibling-path default caused two false cut-blockers on 2026-08-08.

- `release.toml` -- the pins. Names where every component lives and how it ships.
- `cuts/<version>/MUST_CONTAIN.tsv` -- the BOM. **The moment anything here is built it gets a row**, via `OS003/bin/bom_add.sh`.
- `manifest/capability_manifest.tsv` -- how a change is PROVEN present in the artefact.
- `CUT_MECHANISM_CANONICAL.md` -- how a cut actually happens.

Never build a competing gate or a second release repo. A missing gate belongs in `OS003/gates/`.
