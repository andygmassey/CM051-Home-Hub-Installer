# Regenerating `licence_canonical_golden_vectors.json`

The expected bytes in that fixture are **not** derived from a rule written down
here. They are the output of running CM050's real signer. If you regenerate
them any other way — by re-implementing the canonicalisation, or by copying
what a verifier produces — you rebuild the self-reference the fixture exists to
remove, and the file becomes decoration.

## When to regenerate

- CM050 `appcast-server/src/license.ts` changes (the fixture records its sha256;
  the test does not check it against a live CM050, so nothing will tell you
  automatically — this is the trigger to watch).
- The licence schema gains or loses a `SIGNED_FIELDS` entry.
- The test reports control 5 as **healed**: a recorded divergence has stopped
  diverging, meaning the CM050 side was fixed. Regenerate, then drop the
  `known_divergent` flag on the vectors that now agree. Do not leave a stale
  record standing — a divergence note nobody revisits becomes a permanent bug.

## How

CM050 is not vendored here and does not need to be. Clone it, build the real
module, run it:

```sh
git clone --depth 1 https://github.com/andygmassey/CM050-Home-Hub-Update-System.git cm050
cd cm050/appcast-server && npm ci

# Bundle the UNMODIFIED module. Do not hand-edit license.ts to make it import
# cleanly -- esbuild resolves ./license-schema on its own, and editing the
# artefact to satisfy the instrument is exactly the failure this guards.
./node_modules/.bin/esbuild src/license.ts --bundle --format=esm --platform=node \
    --outfile=/tmp/cm050-license.mjs
```

Then drive `canonicaliseLicenseBody` over each vector body and record
`Buffer.from(bytes).toString("hex")` as `signer_canonical_hex`. Hex, not a
string: the whole point is that the encoding is unambiguous.

Update `provenance.signer_commit` and `provenance.signer_file_sha256` in the
same commit — `git rev-parse HEAD` and `shasum -a 256 src/license.ts`. Control 6
fails if either is missing, but nothing can detect a *stale* value, so this step
is on you.

## What the fixture records, and what it does not

It records what the signer **does**, not what the spec says it should do. Those
currently differ on five codepoints (0x08 0x09 0x0a 0x0c 0x0d) — see
`known_divergence` in the fixture. Recording actual behaviour is deliberate: a
fixture that encoded the intended behaviour would be red on arrival and would be
"fixed" by weakening it.

It does **not** verify a signature. `canonicaliseLicenseBody` is deterministic
and unkeyed, so pinning it needs no private key and no real licence. A
signed-blob fixture would drag the signing key and an expiry date into the test
for no additional coverage.
