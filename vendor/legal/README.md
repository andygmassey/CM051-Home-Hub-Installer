# Ostler Legal – versioned consent strings

Tiny, no-runtime-dep package holding the verbatim wording shown to
users at consent time. Imported by:

- `ostler_security.consent` – to compute SHA-256 hashes for the
  records persisted at `~/.ostler/posture/consent.json`.
- `ostler_security.consent_cli` – exposed via `ostler-consent`
  shell entry point.
- The Hub's installer (`install.sh`) – bash heredocs render the
  strings on screen; the CLI persists the same text + hash.
- The Rust `ostler-assistant` binary – gates `whatsapp-bridge` and
  `cm041` voice ingestion off these records.
- The Doctor "Consent" tile – flags amber when bundled wording
  drifts from the persisted record.

Bumping wording text:

- Material change → bump `wording_version`. Existing users see a
  renewal prompt on next Hub start.
- Typo / non-material → bump `wording_version` with a `minor`
  suffix; runtime can elect to skip the renewal.

Lawyer-friend reviews wording before public launch; placeholders
flagged `[DRAFT – pending legal review]` inline.
