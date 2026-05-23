#!/usr/bin/env bash
#
# tests/test_contact_card_prefill.sh
#
# CX-12 (CX-14 Section F): regression test for the contact-card pre-fill
# suite. Locks the assembly contract between the vCard reader (vendor
# Python) + install.sh (bash plumbing) so a future refactor cannot
# silently regress any of:
#
#   F1  vCard reader exposes first-mobile phone + first-work email
#   F2  install.sh captures USER_PHONE + USER_EMAIL after Q3
#   F3  iMessage allowed default = "$USER_PHONE, $USER_EMAIL"
#   F4  WhatsApp recipient default = "$USER_PHONE"
#   F5  Country-code "We detected +..." prompt fires when source=phone
#   F6  MSG_INFO_PLEASE_WAIT_READING_CONTACTS is emitted before the
#       all-contacts osascript scan
#
# Synthetic fixture only — locked memory
# feedback_synthetic_fixtures_no_real_data_default. Phone is in the
# NANP 555-01XX reserved range; email is the IANA RFC 2606 example
# domain. No real customer data anywhere.
#
# Locked memory feedback_silent_bail_regression_test_shape: each
# assertion walks the actual install.sh / catalogue text for the
# EXACT shape that would be missing if the feature silently
# regressed. Happy-path "does it parse" tests are not enough — we
# want a guard against any of F2-F6 disappearing under a future
# string-catalogue or refactor sweep.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_SH="${REPO_ROOT}/install.sh.strings.en-GB.sh"
VCARD_PARSER="${REPO_ROOT}/vendor/cm041/contact_syncer/vcard_parser.py"
FIXTURE="${REPO_ROOT}/tests/fixtures/contact_card_sample.vcf"

for path in "$INSTALL_SH" "$STRINGS_SH" "$VCARD_PARSER" "$FIXTURE"; do
    if [[ ! -f "$path" ]]; then
        echo "FAIL [setup]: required file not found: $path" >&2
        exit 1
    fi
done

# ── Case 1: vCard parser exposes phone + email convenience fields ──
#
# The fixture has TWO phones (CELL first, HOME second) and TWO emails
# (WORK first, HOME second). The reader must pick the mobile phone
# and the work email — both are the "Q3 pre-fill" defaults the
# installer feeds into the WhatsApp recipient + iMessage allowed
# prompts.
python3 - "$VCARD_PARSER" "$FIXTURE" <<'PY'
import importlib.util
import sys

# The vCard parser depends on the third-party `vobject` library, which
# lives in the customer-side install venv but is not always present on
# CI / developer Macs running the bash test suite. The convenience
# helpers (`first_mobile_phone` / `first_work_email`) do NOT need
# vobject, so we test them through a lightweight import shim that
# exec()s only those helper definitions out of the parser source. The
# end-to-end `parse_vcard(fixture)` check still runs when vobject is
# installed (no skip-silently surprise), and is exercised in the
# CM041 vendor test-suite under contact_syncer/.
src = open(sys.argv[1], encoding="utf-8").read()

try:
    import vobject  # noqa: F401
    spec = importlib.util.spec_from_file_location("vcard_parser", sys.argv[1])
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    with open(sys.argv[2], encoding="utf-8") as fh:
        parsed = mod.parse_vcard(fh.read())
    assert parsed["fn"] == "Alice Tester", parsed
    assert parsed["phone"] == "+15551234567", (
        "phone must be the first CELL/MOBILE entry, got %r" % parsed.get("phone")
    )
    assert parsed["email"] == "alice@example.com", (
        "email must be the first WORK entry, got %r" % parsed.get("email")
    )
    print("END_TO_END_PARSE_OK")
except ImportError:
    # Exec just the helpers + their typing imports — they're
    # pure-Python with no third-party deps.
    helper_ns = {}
    helper_src = []
    for chunk_name in ("def first_mobile_phone", "def first_work_email"):
        idx = src.find(chunk_name)
        assert idx >= 0, "helper %s missing from vcard_parser.py" % chunk_name
        # take until next top-level def
        end = src.find("\ndef ", idx + 1)
        helper_src.append(src[idx:end if end > 0 else None])
    prelude = (
        "from typing import Any, Dict, List, Optional\n"
    )
    exec(prelude + "\n".join(helper_src), helper_ns)
    first_mobile = helper_ns["first_mobile_phone"]
    first_email = helper_ns["first_work_email"]
    phones = [
        {"value": "+15557654321", "label": "HOME"},
        {"value": "+15551234567", "label": "CELL"},
    ]
    emails = [
        {"value": "alice.home@example.com", "label": "HOME"},
        {"value": "alice@example.com", "label": "WORK"},
    ]
    assert first_mobile(phones) == "+15551234567", first_mobile(phones)
    assert first_email(emails) == "alice@example.com", first_email(emails)
    print("HELPER_ONLY_OK")

# Empty-input safety: never raise, always return "" — re-exec helpers
# even on the end-to-end path so this assertion holds both ways.
try:
    mod  # noqa: F821 (defined on end-to-end branch)
    first_mobile = mod.first_mobile_phone
    first_email = mod.first_work_email
except NameError:
    pass  # helper_only path already bound the names above
assert first_mobile([]) == ""
assert first_email([]) == ""
assert first_mobile([{"value": "", "label": "CELL"}]) == ""
PY
echo "PASS [case-1]: vcard_parser exposes phone + email (first mobile / first work)"

# ── Case 2: install.sh captures USER_PHONE / USER_EMAIL at Q3 ──────
if ! grep -qE '^USER_PHONE="\$\{DETECTED_PHONE:-\}"' "$INSTALL_SH"; then
    echo "FAIL [case-2]: install.sh missing USER_PHONE=\${DETECTED_PHONE:-} capture" >&2
    exit 1
fi
if ! grep -qE '^USER_EMAIL="\$\{DETECTED_EMAIL:-\}"' "$INSTALL_SH"; then
    echo "FAIL [case-2]: install.sh missing USER_EMAIL=\${DETECTED_EMAIL:-} capture" >&2
    exit 1
fi
echo "PASS [case-2]: install.sh F2 capture wires DETECTED_* into USER_PHONE/USER_EMAIL"

# ── Case 3: Q8 iMessage allowed default references USER_PHONE/EMAIL ─
if ! grep -q 'IMESSAGE_ALLOWED_DEFAULT="\${USER_PHONE}, \${USER_EMAIL}"' "$INSTALL_SH"; then
    echo "FAIL [case-3]: install.sh missing iMessage allowed comma-separated default" >&2
    exit 1
fi
if ! grep -q 'gui_read "\$MSG_PROMPT_IMESSAGE_ALLOWED_TITLE" text "\$IMESSAGE_ALLOWED_DEFAULT"' "$INSTALL_SH"; then
    echo "FAIL [case-3]: install.sh iMessage allowed prompt not passing pre-fill default" >&2
    exit 1
fi
echo "PASS [case-3]: Q8 iMessage allowed pre-fill wired to USER_PHONE/USER_EMAIL"

# ── Case 4: WhatsApp recipient default references USER_PHONE ───────
if ! grep -q 'WHATSAPP_RECIPIENT_DEFAULT="\${USER_PHONE:-}"' "$INSTALL_SH"; then
    echo "FAIL [case-4]: install.sh missing WhatsApp recipient default" >&2
    exit 1
fi
if ! grep -q '"\$MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE" text "\$WHATSAPP_RECIPIENT_DEFAULT"' "$INSTALL_SH"; then
    echo "FAIL [case-4]: install.sh WhatsApp prompt not passing pre-fill default" >&2
    exit 1
fi
echo "PASS [case-4]: WhatsApp recipient pre-fill wired to USER_PHONE"

# ── Case 5: Q4 country code uses DETECTED_FROM_PHONE title when src=phone ─
if ! grep -q 'DETECTED_CODE_SOURCE="phone"' "$INSTALL_SH"; then
    echo "FAIL [case-5]: install.sh missing DETECTED_CODE_SOURCE=phone branch" >&2
    exit 1
fi
if ! grep -q 'MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE' "$INSTALL_SH"; then
    echo "FAIL [case-5]: install.sh missing DETECTED_FROM_PHONE title use" >&2
    exit 1
fi
if ! grep -q 'MSG_PROMPT_COUNTRY_CODE_DETECTED_FROM_PHONE_TITLE=' "$STRINGS_SH"; then
    echo "FAIL [case-5]: catalogue missing DETECTED_FROM_PHONE title key" >&2
    exit 1
fi
echo "PASS [case-5]: Q4 country-code prompt swaps to DETECTED_FROM_PHONE when source=phone"

# ── Case 6: MSG_INFO_PLEASE_WAIT_READING_CONTACTS exists + is wired ─
if ! grep -q 'MSG_INFO_PLEASE_WAIT_READING_CONTACTS=' "$STRINGS_SH"; then
    echo "FAIL [case-6]: catalogue missing MSG_INFO_PLEASE_WAIT_READING_CONTACTS" >&2
    exit 1
fi
if ! grep -q 'info "\$MSG_INFO_PLEASE_WAIT_READING_CONTACTS"' "$INSTALL_SH"; then
    echo "FAIL [case-6]: install.sh not emitting MSG_INFO_PLEASE_WAIT_READING_CONTACTS" >&2
    exit 1
fi
# Ordering: the status line must appear BEFORE the count-of-every-person
# osascript. Otherwise the silent-wait alarm isn't actually solved.
WAIT_LINE=$(grep -n 'info "\$MSG_INFO_PLEASE_WAIT_READING_CONTACTS"' "$INSTALL_SH" | head -n 1 | cut -d: -f1)
COUNT_LINE=$(grep -n 'count of every person' "$INSTALL_SH" | head -n 1 | cut -d: -f1)
if [[ -z "$WAIT_LINE" || -z "$COUNT_LINE" || "$WAIT_LINE" -ge "$COUNT_LINE" ]]; then
    echo "FAIL [case-6]: wait line (#${WAIT_LINE:-?}) must fire before count osascript (#${COUNT_LINE:-?})" >&2
    exit 1
fi
echo "PASS [case-6]: contacts-wait line wired and fires before count-of-every-person scan"

# ── Case 7: synthetic-fixture invariant (locked memory) ────────────
#
# Defence in depth against a future contributor accidentally swapping
# the fixture for real data. The two synthetic values are pinned.
if ! grep -q '+15551234567' "$FIXTURE"; then
    echo "FAIL [case-7]: fixture lost the synthetic NANP 555-01XX phone" >&2
    exit 1
fi
if ! grep -q 'alice@example.com' "$FIXTURE"; then
    echo "FAIL [case-7]: fixture lost the synthetic example.com email" >&2
    exit 1
fi
echo "PASS [case-7]: fixture pinned to synthetic NANP + example.com data"

echo ""
echo "ALL CONTACT_CARD_PREFILL TESTS PASSED"
