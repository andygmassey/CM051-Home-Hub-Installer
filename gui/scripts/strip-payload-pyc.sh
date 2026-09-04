#!/usr/bin/env bash
# Remove every ambient .pyc / __pycache__ from the assembled upgrade payload,
# BEFORE seed-hub-payload-pyc.sh writes the canonical unchecked-hash set
# (register #644).
#
# WHY THIS EXISTS. stage-payload assembles the payload with `cp -R` out of the
# working tree (vendor/doctor/agent -> services/doctor, and knowledge, cm048).
# On a local or emergency cut the operator's checkout carries __pycache__ from
# whatever python ran there -- typically the runner's system python3, e.g.
# cpython-314. The seeder compiles for the BUNDLED 3.11 and writes
# cpython-311.pyc; it NEVER overwrites a different cache tag, so those ambient
# files ride into the shipped payload as unsealed, wrong-mode bytecode. CI
# never catches it: __pycache__ is gitignored, so a clean checkout has none.
# Every Xcode bundle phase already strips __pycache__ after its cp; this is the
# same hygiene for the one assembly step that lacked it.
#
# Self-checking: after the strip it re-counts, and EXITS NON-ZERO if any .pyc
# survives. A broken find that silently removes nothing must not read as a
# clean payload -- "0 removed" and "0 remain" are different claims, and only
# the second one is the guarantee stage-payload needs before seeding.
set -euo pipefail

PAYLOAD="${1:-}"
if [[ -z "$PAYLOAD" ]]; then
  echo "usage: strip-payload-pyc.sh <payload-dir>" >&2
  exit 2
fi
if [[ ! -d "$PAYLOAD" ]]; then
  echo "ERROR: strip-payload-pyc.sh: payload dir not found: $PAYLOAD" >&2
  exit 2
fi

before_pyc="$(find "$PAYLOAD" -type f -name '*.pyc' | wc -l | tr -d ' ')"
before_dir="$(find "$PAYLOAD" -type d -name '__pycache__' | wc -l | tr -d ' ')"

# Remove the compiled artefacts; keep the .py sources untouched.
find "$PAYLOAD" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find "$PAYLOAD" -type f -name '*.pyc'       -delete       2>/dev/null || true

after_pyc="$(find "$PAYLOAD" -type f -name '*.pyc' | wc -l | tr -d ' ')"
after_dir="$(find "$PAYLOAD" -type d -name '__pycache__' | wc -l | tr -d ' ')"

if [[ "$after_pyc" != "0" || "$after_dir" != "0" ]]; then
  echo "ERROR: strip-payload-pyc.sh: $after_pyc .pyc and $after_dir __pycache__ dir(s) survived the strip in $PAYLOAD." >&2
  echo "       The payload would carry ambient bytecode into seeding. Refusing." >&2
  exit 1
fi

printf '[OK] strip-payload-pyc: removed %s .pyc and %s __pycache__ dir(s); 0 remain before seeding.\n' \
  "$before_pyc" "$before_dir"
