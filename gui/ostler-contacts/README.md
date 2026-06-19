# ostler-contacts

Native macOS CNContact helper for the **Tidy Contacts** feature (Big Win BW-A).

Design spec: `HR015 - Gaming PC/launch/BIG_WINS_BW-A_apply_spec.md`.

## What this is (step 1 of N)

A thin, auditable, single-purpose Swift CLI binary — the only component on
the Hub Mac (besides `OstlerInstaller.app`) that carries the Contacts
entitlement. Per spec §2.3, keeping the Contacts surface in a tiny
dedicated binary is itself a safety property: the write surface stays small
and reviewable.

The read + backup foundation shipped first (spec §9, build-order item 1).
This package now also carries the **destructive merge writer** (spec §9
item 3): `preview`, `merge` and `undo`.

### Subcommands

| Command | What it does |
|---|---|
| `ostler-contacts backup [--out <dir>]` | Reads all Contacts via `CNContactStore`, exports a full vCard via `CNContactVCardSerialization` to `~/Documents/Ostler/Backups/Contacts/<timestamp>/AllContacts.vcf`, writes a `manifest.json` (count + SHA-256), round-trip-verifies the backup, prints the path. This is the backup-FIRST gate the safety contract (rule 1) depends on. |
| `ostler-contacts list` | Reads Contacts, prints `identifier <tab> name` + a total. Proves read access works. |
| `ostler-contacts preview --survivor <id> --victims <id,...>` | Read-only. Resolves the group, builds the field union and emits the before/after diff (`conflicts`, `adds`) plus the `group_hash`/`confirm_token` as JSON. NO write. |
| `ostler-contacts merge --survivor <id> --victims <id,...> --confirm-token <tok> [--journal <path>]` | **DESTRUCTIVE.** Atomic `CNSaveRequest` that `.update`s the survivor (lossless union of victim fields) AND `.delete`s each victim in ONE request. Refuses unless `OSTLER_TIDY_CONTACTS_ENABLED=true` AND a valid `--confirm-token` for this exact group is presented. Writes + fsyncs the undo-journal entry BEFORE the save (journal-first). |
| `ostler-contacts undo --journal <path>` | Restores the survivor to its pre-merge vCard and re-creates each deleted victim from the journal. Re-created cards get NEW identifiers (field-lossless, identity-lossy per spec §6 caveat). |
| `ostler-contacts version` / `help` | Self-describing. |

### Safety properties (spec §0 contract)

- **Pure CNContact, zero osascript.** No `osascript` / `NSAppleScript` /
  `tell application "Contacts"` anywhere. Pinned by
  `tests/test_ostler_contacts_no_osascript.sh` (CX-453 posture, spec §8.2 #6).
- **Flag OFF by default** (rule 4): the `merge` write path hard-refuses
  unless `OSTLER_TIDY_CONTACTS_ENABLED=true`. The refusal fires BEFORE any
  Contacts access, so it is verifiable headlessly.
- **One-shot, group-bound confirm-token** (rule 3): the token equals the
  `group_hash` (`sha256(survivor + sorted victims)`). A token minted for one
  group cannot authorise another.
- **Journal-first ordering** (rule 6): the undo record is appended +
  `fsync`ed before the `CNSaveRequest`, so the save is the only thing that
  can be lost, never the undo record.
- **Lossless toward survivor** (spec §2.2): the union never drops a survivor
  value; conflicting single-value fields keep the survivor's and surface the
  discarded value ("kept A, discarded B").

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
      ConfirmToken.swift     #   one-shot group-bound token derive/verify (rule 3)
      FieldUnion.swift       #   lossless-toward-survivor union (spec §2.2)
      MergeGate.swift        #   single refusal point: flag + token + sanity
      UndoJournal.swift      #   journal-first NDJSON undo entries (spec §6)
    ostler-contacts/         # thin CLI: arg parsing, live CNContactStore reads,
      main.swift             #   the CNSaveRequest writer + undo restore
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

The live `backup` / `list` / `preview` / `merge` / `undo` paths hit
`CNContactStore`, which fires the macOS Contacts TCC prompt the first time.
On an unsigned local/CI run the prompt does not render and access is denied:
that is expected. The headless `swift test` suite covers every piece of
logic that does NOT need the live store (token, gate, field union, journal,
vCard round-trip). The `CNSaveRequest` commit itself (update + delete in one
request) needs a real, entitled, signed binary against a throwaway Contacts
account, so it is a documented manual test.

### Manual real-Mac test plan (throwaway Contacts account, NEVER the real book)

1. In Contacts.app create a separate test account/container; add two
   duplicate cards (e.g. "Jay Livens" with phone X, and "Jay Livens" with
   email Y). Note their identifiers via `ostler-contacts list`.
2. `ostler-contacts backup` -> confirm `AllContacts.vcf` + `manifest.json`
   land under `~/Documents/Ostler/Backups/Contacts/<ts>/`.
3. `OSTLER_TIDY_CONTACTS_ENABLED=true ostler-contacts preview --survivor <S>
   --victims <V>` -> read off the `confirm_token` from the JSON.
4. `OSTLER_TIDY_CONTACTS_ENABLED=true ostler-contacts merge --survivor <S>
   --victims <V> --confirm-token <tok>` -> survivor now has BOTH phone X and
   email Y; victim is gone; `journal.ndjson` has one line.
5. `ostler-contacts undo --journal <journal_path>` -> survivor back to its
   pre-merge fields; a new "Jay Livens" card re-created (NEW identifier, per
   spec §6 caveat).
6. Flag-off check (headless OK): `unset OSTLER_TIDY_CONTACTS_ENABLED;
   ostler-contacts merge ...` -> exits non-zero "Tidy Contacts is OFF"
   before touching Contacts.

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

`OSTLER_TIDY_CONTACTS_ENABLED` (spec §7) defaults to OFF. It hard-gates the
`merge` write path (refusal before any Contacts access). It does **not**
gate `backup` / `list` / `preview` (pure reads, harmless regardless), and it
does **not** gate `undo` (turning the feature off must never trap a user
with an un-undoable merge).
