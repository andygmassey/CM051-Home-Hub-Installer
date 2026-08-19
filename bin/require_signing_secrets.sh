#!/usr/bin/env bash
#
# require_signing_secrets.sh -- assert every credential a cut needs is
# present, BEFORE any of them is used, and name the missing ones exactly.
#
# NAMED "secrets" AND NOT "credentials" FOR ONE REASON: .gitignore carries
# `*credentials*`, and the first version of this file was called
# require_signing_credentials.sh. `git add -A` silently skipped it, the commit
# went up without it, and cut.yml was left calling a script that does not exist
# in the repo. Same class as the `*token*` rule that swallowed
# vendor/doctor/agent/chat_token.py and blanked the iOS Pairing tab -- see the
# note beside that entry in .gitignore.
#
# That one was vendored upstream so it needed a negation. This one is ours, so
# it is renamed instead: a security glob should not accumulate exceptions when
# a rename costs nothing.
#
# WHY THIS IS A SCRIPT AND NOT INLINE YAML. The check it replaces lived inside
# the workflow, which meant the only way to test it was to re-implement it in a
# harness -- and a hand-written re-implementation carries the belief that caused
# the defect. Same rule that was applied to the CM044 person-summary prompt on
# the same day: the thing under test must be the thing that ships.
# tests/test_signing_credential_guard.sh executes THIS file.
#
# WHY IT CHECKS ALL FIVE. The previous guard tested exactly one of them,
# OSTLER_SIGNING_CERT_P12, and that shape failed the moment the secrets were
# provisioned one at a time. Measured 2026-08-10: three of the five were
# derivable from the operator's signing material and two were not on it at all
# (one line pointed at another store, one was a path into App Store Connect).
#
# In that half-provisioned state the old guard PASSED -- the one secret it
# tested was set -- and the cut then died inside `security import` with an
# opaque keychain error naming no secret. The notary step had no guard at all,
# so an empty --issuer went straight into `notarytool store-credentials`.
#
# A missing credential must never present as a toolchain fault.
#
# Checking one member of a set is not checking the set.
#
# Reports EVERY missing name in one run, so provisioning is one round trip
# rather than one re-tag per secret. Values are never read, compared or
# echoed -- only emptiness, and only names.

set -uo pipefail

REQUIRED="
OSTLER_SIGNING_CERT_P12
OSTLER_SIGNING_CERT_PASSWORD
OSTLER_NOTARY_KEY
OSTLER_NOTARY_KEY_ID
OSTLER_NOTARY_ISSUER
"

missing=""
present=0
for name in $REQUIRED; do
	if [ -n "${!name:-}" ]; then
		present=$(( present + 1 ))
	else
		missing="$missing $name"
	fi
done

echo "signing credentials present: $present of 5"

if [ -n "$missing" ]; then
	echo "::error::Missing signing credentials:$missing" >&2
	echo "Add them in repo Settings > Secrets and variables > Actions, then" >&2
	echo "re-tag. Failing closed here rather than part-way through signing," >&2
	echo "where a missing secret looks like a keychain or notarytool fault." >&2
	exit 1
fi
