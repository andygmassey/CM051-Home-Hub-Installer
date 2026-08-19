#!/usr/bin/env bash
#
# tests/test_consent_tickbox_registry.sh
#
# Regression gate for F1 (box-walk recut #2, 2026-07-26): on .185 the
# spoken-capture consent was NOT persisted because the DMG bundled a STALE
# ostler_security whose consent_cli TICKBOX_REGISTRY did not yet include
# `spoken_capture_recording_consent` -- so `ostler-consent record --tickbox
# spoken_capture_recording_consent` hit an argparse "invalid choice" and the
# consent silently failed to record (fails safe: transcription stays off, but
# the operator's opt-in is lost). install.sh's call was CORRECT; the vendored
# registry was stale. Maps to #659.
#
# This test walks the ACTUAL contract (per feedback_silent_bail_regression_
# test_shape): EVERY `_consent_cli_record <mode> <tickbox> ...` call in
# install.sh must pass a tickbox id that is (a) defined as a ConsentString in
# vendor/legal/consent_strings.py AND (b) registered in the vendored
# consent_cli.py TICKBOX_REGISTRY. Any drift -- a new consent call with an
# unregistered id, or a re-vendor that drops a registration -- fails HERE,
# before it can silently swallow a consent record on a customer install.
#
# Static source cross-check (no venv needed): the DMG bundles the vendor
# source and install.sh pip-installs it at encrypt_db time, so a correct
# source guarantees a correct installed CLI.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
CONSENT_STRINGS="${REPO_ROOT}/vendor/legal/consent_strings.py"
CONSENT_CLI="${REPO_ROOT}/vendor/ostler_security/consent_cli.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
for p in "$INSTALL_SH" "$CONSENT_STRINGS" "$CONSENT_CLI"; do
    [[ -f "$p" ]] || fail "required file not found: $p"
done

python3 - "$INSTALL_SH" "$CONSENT_STRINGS" "$CONSENT_CLI" <<'PY'
import re, sys

install_sh, consent_strings_py, consent_cli_py = sys.argv[1:4]

src_strings = open(consent_strings_py, encoding="utf-8").read()
src_cli     = open(consent_cli_py, encoding="utf-8").read()
src_install = open(install_sh, encoding="utf-8").read()

# 1. Map ConsentString VAR_NAME -> tickbox_id from consent_strings.py.
#    Each is `NAME = ConsentString(` ... `tickbox_id="X"` within the block.
name_to_id = {}
for m in re.finditer(r'^([A-Z][A-Z0-9_]+)\s*=\s*ConsentString\(', src_strings, re.M):
    name = m.group(1)
    block = src_strings[m.end():m.end() + 1200]  # block window
    idm = re.search(r'tickbox_id\s*=\s*"([^"]+)"', block)
    if idm:
        name_to_id[name] = idm.group(1)
if not name_to_id:
    print("FAIL: parsed 0 ConsentString definitions from consent_strings.py", file=sys.stderr); sys.exit(1)

# 2. Which VAR_NAMEs are registered in consent_cli.py TICKBOX_REGISTRY?
reg_m = re.search(r'TICKBOX_REGISTRY\s*=\s*\{(.*?)\}', src_cli, re.S)
if not reg_m:
    print("FAIL: could not locate TICKBOX_REGISTRY in consent_cli.py", file=sys.stderr); sys.exit(1)
registered_names = set(re.findall(r'([A-Z][A-Z0-9_]+)\.tickbox_id\s*:', reg_m.group(1)))
registered_ids = {name_to_id[n] for n in registered_names if n in name_to_id}

# 3. Every tickbox id passed to _consent_cli_record in install.sh.
#    A real call line is `    _consent_cli_record <mode> \` (indented, mode
#    arg present, not the `_consent_cli_record() {` definition). The tickbox
#    id is the next non-comment token on the following line.
install_ids = set()
lines = src_install.splitlines()
for i, ln in enumerate(lines):
    if re.match(r'\s*_consent_cli_record\s+\w+', ln) and '()' not in ln and '{' not in ln:
        for j in range(i + 1, min(i + 4, len(lines))):
            tok = lines[j].strip().rstrip('\\').strip()
            if not tok or tok.startswith('#'):
                continue
            if re.fullmatch(r'[a-z][a-z0-9_]+', tok):
                install_ids.add(tok)
            break

if not install_ids:
    print("FAIL: parsed 0 _consent_cli_record tickbox args from install.sh", file=sys.stderr); sys.exit(1)

print(f"install.sh consent tickboxes: {sorted(install_ids)}")
print(f"registered (defined+registry): {sorted(registered_ids)}")

missing = install_ids - registered_ids
if missing:
    print(f"FAIL: install.sh records consent against UNREGISTERED tickbox id(s): {sorted(missing)}", file=sys.stderr)
    print("      This is the F1 class: the consent will silently fail to persist on a customer install.", file=sys.stderr)
    print(f"      Known registered ids: {sorted(registered_ids)}", file=sys.stderr)
    sys.exit(1)

# Belt-and-braces: spoken-capture specifically (the F1 defect) must be present.
if 'spoken_capture_recording_consent' not in registered_ids:
    print("FAIL: spoken_capture_recording_consent is not registered (the exact F1 regression)", file=sys.stderr); sys.exit(1)

print(f"PASS: all {len(install_ids)} install.sh consent tickboxes are defined + registered")
PY
rc=$?
[[ $rc -eq 0 ]] || fail "consent tickbox registry cross-check failed (see above)"
echo "ALL PASS: test_consent_tickbox_registry.sh"
