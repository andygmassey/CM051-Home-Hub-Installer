#!/usr/bin/env bash
#
# tests/test_write_pipeline_signals.sh
#
# Locks the argv contract + merge semantics of the install-time
# sidecar writer used by install.sh's #259 mail-content probe.
#
# What we verify:
#   1. Writer creates an absent parent directory.
#   2. Resulting JSON has the four expected keys with correct types.
#   3. mail_has_fetched=true|false round-trip (string -> JSON bool).
#   4. install_completed_ts override is honoured.
#   5. first_ingest_complete_ts from an existing file is preserved
#      across a rewrite (the #260 forward-compat slice).
#   6. Corrupt existing JSON is treated as absent, not crashed on.
#   7. Output file lands with 0600 perms (atomic-write contract).
#   8. Non-int --accounts exits 2 with a clear message.
#
# Synthetic inputs only; no Apple Mail data touched.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRITER="${REPO_ROOT}/lib/write_pipeline_signals.py"

if [[ ! -f "$WRITER" ]]; then
    echo "FAIL: write_pipeline_signals.py not found at $WRITER" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Case 1: fresh write into a parent that doesn't exist yet ────
OUT="${WORK}/case1/state/pipeline_signals.json"
if ! python3 "$WRITER" \
        --output "$OUT" \
        --accounts 3 \
        --has-fetched true \
        --install-ts 1747400000 >/dev/null; then
    echo "FAIL [case-1]: writer returned non-zero on fresh write" >&2
    exit 1
fi
if [[ ! -f "$OUT" ]]; then
    echo "FAIL [case-1]: writer did not create $OUT" >&2
    exit 1
fi
echo "PASS [case-1]: writer creates parent directory and output file"

# ── Case 2: JSON shape + types ──────────────────────────────────
python3 - "$OUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)

assert isinstance(data, dict), "root must be object"
assert data["mail_accounts_found"] == 3, data
assert data["mail_has_fetched"] is True, data
assert data["install_completed_ts"] == 1747400000, data
assert "first_ingest_complete_ts" not in data, "absent on fresh write"
PY
echo "PASS [case-2]: JSON has expected shape and types"

# ── Case 3: mail_has_fetched=false round-trip ───────────────────
OUT3="${WORK}/case3/out.json"
python3 "$WRITER" --output "$OUT3" --accounts 0 --has-fetched false --install-ts 100 >/dev/null
python3 - "$OUT3" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["mail_has_fetched"] is False, data
assert data["mail_accounts_found"] == 0, data
PY
echo "PASS [case-3]: has-fetched=false round-trips to JSON false"

# ── Case 4: install-ts override honoured ────────────────────────
OUT4="${WORK}/case4/out.json"
python3 "$WRITER" --output "$OUT4" --accounts 1 --has-fetched true --install-ts 9999 >/dev/null
python3 - "$OUT4" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["install_completed_ts"] == 9999, data
PY
echo "PASS [case-4]: --install-ts override honoured"

# ── Case 5: first_ingest_complete_ts is preserved on rewrite ────
OUT5="${WORK}/case5/out.json"
mkdir -p "$(dirname "$OUT5")"
cat > "$OUT5" <<JSON
{
  "mail_accounts_found": 1,
  "mail_has_fetched": false,
  "install_completed_ts": 100,
  "first_ingest_complete_ts": 200
}
JSON
python3 "$WRITER" --output "$OUT5" --accounts 5 --has-fetched true --install-ts 300 >/dev/null
python3 - "$OUT5" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["mail_accounts_found"] == 5, data
assert data["mail_has_fetched"] is True, data
assert data["install_completed_ts"] == 300, data
assert data["first_ingest_complete_ts"] == 200, "first_ingest must be preserved"
PY
echo "PASS [case-5]: first_ingest_complete_ts preserved across rewrite"

# ── Case 6: corrupt existing JSON treated as absent ─────────────
OUT6="${WORK}/case6/out.json"
mkdir -p "$(dirname "$OUT6")"
echo "not valid json" > "$OUT6"
if ! python3 "$WRITER" --output "$OUT6" --accounts 2 --has-fetched true --install-ts 400 >/dev/null; then
    echo "FAIL [case-6]: writer returned non-zero on corrupt existing file" >&2
    exit 1
fi
python3 - "$OUT6" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["mail_accounts_found"] == 2, data
assert "first_ingest_complete_ts" not in data, "no key to preserve"
PY
echo "PASS [case-6]: corrupt existing JSON treated as absent"

# ── Case 7: 0600 perms on the output file ───────────────────────
PERMS="$(stat -f '%Lp' "$OUT" 2>/dev/null || stat -c '%a' "$OUT" 2>/dev/null)"
if [[ "$PERMS" != "600" ]]; then
    echo "FAIL [case-7]: expected 0600 perms on $OUT, got $PERMS" >&2
    exit 1
fi
echo "PASS [case-7]: output file is mode 0600"

# ── Case 8: non-int --accounts exits 2 ──────────────────────────
OUT8="${WORK}/case8/out.json"
set +e
python3 "$WRITER" --output "$OUT8" --accounts "abc" --has-fetched true >/dev/null 2>"${WORK}/stderr.txt"
RC=$?
set -e
if [[ "$RC" != "2" ]]; then
    echo "FAIL [case-8]: expected exit 2 on non-int --accounts, got $RC" >&2
    exit 1
fi
if ! grep -q "must be int" "${WORK}/stderr.txt"; then
    echo "FAIL [case-8]: stderr message did not mention 'must be int'" >&2
    cat "${WORK}/stderr.txt" >&2
    exit 1
fi
if [[ -f "$OUT8" ]]; then
    echo "FAIL [case-8]: writer created $OUT8 despite bad input" >&2
    exit 1
fi
echo "PASS [case-8]: non-int --accounts exits 2 cleanly"

# ── Case 9 (CX-60): --imessage-fda-needed=true on fresh file ────
OUT9="${WORK}/case9/out.json"
python3 "$WRITER" \
    --output "$OUT9" \
    --imessage-fda-needed true \
    --install-ts 9000 >/dev/null
python3 - "$OUT9" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["imessage_chat_db_fda_needed"] is True, data
assert data["install_completed_ts"] == 9000, data
# Mail half MUST be absent when the caller omitted those args.
assert "mail_accounts_found" not in data, data
assert "mail_has_fetched" not in data, data
PY
echo "PASS [case-9]: --imessage-fda-needed=true writes the field, no mail keys"

# ── Case 10 (CX-60): both halves on the same invocation ─────────
OUT10="${WORK}/case10/out.json"
python3 "$WRITER" \
    --output "$OUT10" \
    --accounts 7 --has-fetched true \
    --imessage-fda-needed false \
    --install-ts 10000 >/dev/null
python3 - "$OUT10" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["mail_accounts_found"] == 7, data
assert data["mail_has_fetched"] is True, data
assert data["imessage_chat_db_fda_needed"] is False, data
assert data["install_completed_ts"] == 10000, data
PY
echo "PASS [case-10]: mail + iMessage halves written together"

# ── Case 11 (CX-60): later mail-only call preserves imessage flag
OUT11="${WORK}/case11/out.json"
mkdir -p "$(dirname "$OUT11")"
cat > "$OUT11" <<JSON
{
  "mail_accounts_found": 0,
  "mail_has_fetched": false,
  "install_completed_ts": 11000,
  "imessage_chat_db_fda_needed": true
}
JSON
python3 "$WRITER" \
    --output "$OUT11" \
    --accounts 4 --has-fetched true \
    --install-ts 11500 >/dev/null
python3 - "$OUT11" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
# Mail half overwritten...
assert data["mail_accounts_found"] == 4, data
assert data["mail_has_fetched"] is True, data
# ...but the prior iMessage flag must survive.
assert data["imessage_chat_db_fda_needed"] is True, data
PY
echo "PASS [case-11]: mail-only rewrite preserves prior imessage flag"

# ── Case 12 (CX-60): later imessage-only call preserves mail half
OUT12="${WORK}/case12/out.json"
python3 "$WRITER" \
    --output "$OUT12" \
    --accounts 2 --has-fetched false \
    --install-ts 12000 >/dev/null
python3 "$WRITER" \
    --output "$OUT12" \
    --imessage-fda-needed true \
    --install-ts 12500 >/dev/null
python3 - "$OUT12" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
# Mail half from the first call must survive the imessage-only update.
assert data["mail_accounts_found"] == 2, data
assert data["mail_has_fetched"] is False, data
assert data["imessage_chat_db_fda_needed"] is True, data
assert data["install_completed_ts"] == 12500, data
PY
echo "PASS [case-12]: imessage-only rewrite preserves prior mail half"

# ── Case 13 (CX-60): bad --imessage-fda-needed exits 2 ──────────
OUT13="${WORK}/case13/out.json"
set +e
python3 "$WRITER" \
    --output "$OUT13" \
    --imessage-fda-needed "maybe" >/dev/null 2>"${WORK}/stderr13.txt"
RC=$?
set -e
if [[ "$RC" != "2" ]]; then
    echo "FAIL [case-13]: expected exit 2 on bad --imessage-fda-needed, got $RC" >&2
    exit 1
fi
if ! grep -q "must be 'true' or 'false'" "${WORK}/stderr13.txt"; then
    echo "FAIL [case-13]: stderr did not mention the accepted values" >&2
    cat "${WORK}/stderr13.txt" >&2
    exit 1
fi
echo "PASS [case-13]: bad --imessage-fda-needed exits 2 cleanly"

# ── Case 14 (CX-60): --accounts without --has-fetched exits 2 ───
OUT14="${WORK}/case14/out.json"
set +e
python3 "$WRITER" --output "$OUT14" --accounts 3 >/dev/null 2>"${WORK}/stderr14.txt"
RC=$?
set -e
if [[ "$RC" != "2" ]]; then
    echo "FAIL [case-14]: expected exit 2 on partial mail args, got $RC" >&2
    exit 1
fi
if ! grep -q "must be supplied together" "${WORK}/stderr14.txt"; then
    echo "FAIL [case-14]: stderr did not mention paired args" >&2
    cat "${WORK}/stderr14.txt" >&2
    exit 1
fi
echo "PASS [case-14]: partial mail args exit 2 cleanly"

echo ""
echo "ALL PIPELINE_SIGNALS WRITER TESTS PASSED"
