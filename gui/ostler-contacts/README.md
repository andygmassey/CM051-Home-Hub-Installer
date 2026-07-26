# ostler-contacts

Native macOS CNContact helper for the **Tidy Contacts** feature (Big Win BW-A).

Design spec: `HR015 - Gaming PC/launch/BIG_WINS_BW-A_apply_spec.md`.

## What this is (step 1 of N)

A thin, auditable, single-purpose Swift CLI binary — the only component on
the Hub Mac (besides `OstlerInstaller.app`) that carries the Contacts
entitlement. Per spec §2.3, keeping the Contacts surface in a tiny
dedicated binary is itself a safety property: the write surface stays small
and reviewable.

**This first increment is READ + BACKUP ONLY.** It is the safe foundation
the rest of BW-A builds on (spec §9, build-order item 1: "Ship this even
before the merge stage — it's independently useful and de-risks the
framework").

### Subcommands in this increment

| Command | What it does |
|---|---|
| `ostler-contacts backup [--out <dir>]` | Reads all Contacts via `CNContactStore`, exports a full vCard via `CNContactVCardSerialization` to `~/Documents/Ostler/Backups/Contacts/<timestamp>/AllContacts.vcf`, writes a `manifest.json` (count + SHA-256), round-trip-verifies the backup, prints the path. This is the backup-FIRST gate the safety contract (rule 1) depends on. |
| `ostler-contacts list` | Reads Contacts, prints `identifier <tab> name` + a total. Proves read access works. |
| `ostler-contacts version` / `help` | Self-describing. |

### What is DELIBERATELY ABSENT

There is **no write path** in this package:

- no `CNSaveRequest`
- no `.update(...)` / `.delete(...)`
- no field-union / merge logic
- no undo journal write
- no `--confirm-token`

The destructive half (`preview`, `merge`, `undo`) lands in later PRs
(spec §9 items 2–4). `grep -r CNSaveRequest .` over this package returns
zero matches by design.

## Layout

```
ostler-contacts/
  Package.swift
  Sources/
    OstlerContactsCore/      # pure, TCC-free, unit-tested logic
      BackupPaths.swift      #   directory/timestamp derivation
      BackupManifest.swift   #   SHA-256 + count manifest
      VCardBackup.swift      #   serialise / parse / round-trip verify
      FeatureFlag.swift      #   OSTLER_TIDY_CONTACTS_ENABLED (defined; off by default)
    ostler-contacts/         # thin CLI: arg parsing + live CNContactStore reads
      main.swift
  Tests/OstlerContactsCoreTests/
  Entitlements/
    ostler-contacts.entitlements   # com.apple.security.personal-information.addressbook
    Info.plist                     # NSContactsUsageDescription (linked via __info_plist)
```

## Build & test

```sh
cd gui/ostler-contacts
swift build
swift test
```

`swift test` exercises everything in `OstlerContactsCore` (paths, manifest,
SHA-256, feature flag, and the vCard serialise/parse round-trip against
synthetic in-memory `CNMutableContact` fixtures). Serialising an in-memory
contact array does **not** require Contacts authorisation, so the tests run
clean in CI with no TCC prompt.

## On-box only (cannot be exercised in CI)

The live `backup` / `list` reads hit `CNContactStore`, which fires the
macOS Contacts TCC prompt the first time. On an unsigned local/CI run the
prompt does not render and access is denied — that is expected. The
read-from-real-Contacts path is verified on-box against a real signed
binary.

## Signing / shipping (later step)

The binary must be Developer-ID-signed with hardened runtime, the
`Entitlements/ostler-contacts.entitlements` file, and the
`Entitlements/Info.plist` linked in via `-sectcreate __TEXT __info_plist`
(see that file's comment). The entitlement + usage string already exist on
the installer (`gui/project.yml`, CX-46); this wires the equivalent for the
standalone helper. The xcodegen/Makefile build-and-ship wiring is a small
follow-up and is intentionally out of scope for this read-only foundation
PR.

## Feature flag

`OSTLER_TIDY_CONTACTS_ENABLED` (spec §7) is defined and defaults to OFF. In
a later PR it hard-gates the *write* subcommands. In this PR it does **not**
gate `backup` / `list` — both are pure reads and harmless regardless.
