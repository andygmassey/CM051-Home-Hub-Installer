# ostler_security: divergences the patch does not record

## consent_cli publish-wording writes the wording hashes the app is gated on (CM051 #3431)

Tree `ostler_security`. NEW CM051-side behaviour in `consent_cli.py`.

Measured refusal: `scripts/regenerate_divergence_patch.sh ostler_security` REFUSES with "the SOURCE has advanced past the pin" (unshipped upstream commit a324219, universal_import plaintext staging cleanup, touches this tree). Regenerating would fold that upstream commit into the patch as a local edit, so the patch is left alone and the edit is recorded here instead.

Location and shape: `consent_cli.py` gains the constant `WORDING_HASHES_FILE` and `_cmd_publish_wording` (inserted immediately above `_cmd_remove_all`), plus a `publish-wording` subparser in `main` (inserted immediately above the `remove-all` subparser). The command writes `posture/consent_wording_hashes.json` (mode 0600, atomic via a temp file and rename) holding the SHA-256 and version of every registered tickbox. install.sh calls it in the 3.6b persist block. The CM042 RemoteCapture app reads that file; absent or unreadable means it refuses capture.

### What a future sync must preserve

`WORDING_HASHES_FILE`, `_cmd_publish_wording` and the `publish-wording` subparser. Guarded by `tests/test_consent_wording_hashes_published.py`, wired into `consent-registry.yml`. Retire by landing the same command in HR015 `ostler_security` and re-pinning.
