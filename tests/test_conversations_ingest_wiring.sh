#!/usr/bin/env bash
#
# test_conversations_ingest_wiring.sh
#
# Cut-time guard for the CM044 conversations-ingest fix. Refuses the
# exact silent-100%-drop shapes proven on the live Hub (192.168.1.159):
#
#   1. CM048 gist sinks wrote conversation Qdrant points with NO `channel`
#      tag and Oxigraph facts with NO link back to the JID/handle-keyed
#      pwg:Person nodes -> a graph that "mentions" whatsapp/imessage but
#      cannot answer "who did I talk to" structurally.
#   2. ostler_fda.pwg_ingest wrote a raw "+44..." number as a contact's
#      displayName with no provisional flag (#576 leak).
#   3. install.sh had no loud guard for "extraction emitted >0 but ZERO
#      reached the graph", so a total drop looked like a clean install.
#   4. The iMessage bundle tick instant-yielded on EVERY tick under slot
#      contention and never ran a single pass (no watermark, empty
#      Conversations dir).
#
# Asserts on the SHIPPED (vendored) copies so a future re-vendor that
# drops any graft fails the cut. Network-free, dependency-free.
#
# Upstream twins ORM must keep byte-identical:
#   - vendor/cm048_pipeline/src/ingest.py  <- CM048 src/ingest.py
#   - vendor/ostler_fda/pwg_ingest.py      <- HR015 ostler_fda/pwg_ingest.py
#   - vendor/imessage_source/bin/imessage-bundle-tick.sh <- HR015 (CM040)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0
failure() { echo "FAIL: $*" >&2; FAILED=1; }

INGEST="$REPO_ROOT/vendor/cm048_pipeline/src/ingest.py"
PWG_INGEST="$REPO_ROOT/vendor/ostler_fda/pwg_ingest.py"
TICK="$REPO_ROOT/vendor/imessage_source/bin/imessage-bundle-tick.sh"
INSTALL="$REPO_ROOT/install.sh"

for f in "$INGEST" "$PWG_INGEST" "$TICK" "$INSTALL"; do
    [[ -f "$f" ]] || { failure "missing shipped file: $f"; }
done
[[ "$FAILED" -eq 0 ]] || exit 1

# 1. CM048 Qdrant points carry the channel tag.
if ! grep -Eq '"channel":[[:space:]]*channel' "$INGEST"; then
    failure "ingest.py base_payload does not tag points with channel -- whatsapp/imessage points are indistinguishable in the conversations collection"
fi

# 2. CM048 emits participant-identity edges linking to JID/handle-keyed
#    Person nodes, with the deterministic derivation that MUST match
#    pwg_ingest's _person_id_from_identifier.
grep -q 'def _participant_identity_triples' "$INGEST" \
    || failure "ingest.py is missing _participant_identity_triples() -- conversations never link to Person nodes"
grep -q 'urn:pwg:participatedIn' "$INGEST" \
    || failure "ingest.py does not emit pwg:participatedIn edges"
grep -q 'urn:pwg:hasParticipant' "$INGEST" \
    || failure "ingest.py does not emit pwg:hasParticipant edges"
grep -q 'uuid.uuid5(uuid.NAMESPACE_URL' "$INGEST" \
    || failure "ingest.py person-id derivation does not match pwg_ingest (uuid5 over NAMESPACE_URL)"

# 3. _write_oxigraph / _write_qdrant accept metadata (so channel +
#    participants actually reach the sink writers).
grep -Eq 'def _write_qdrant\(.*' "$INGEST" \
    && grep -q 'metadata: dict | None = None' "$INGEST" \
    || failure "sink writers do not accept metadata -- the channel/participant fix is not wired through"

# 4. pwg_ingest flags raw-number/handle displayNames provisional (#576).
grep -q 'def _is_provisional_display_name' "$PWG_INGEST" \
    || failure "pwg_ingest.py is missing _is_provisional_display_name() (#576 leak)"
grep -q 'pwg:displayNameProvisional' "$PWG_INGEST" \
    || failure "pwg_ingest.py never marks a bare-number displayName provisional (#576 leak)"

# 5. install.sh loud landing guard.
grep -q 'Conversation-ingest guard' "$INSTALL" \
    || failure "install.sh has no conversation-ingest landing guard -- a 100% drop would look like a clean install"
grep -q 'PersonIdentifier' "$INSTALL" \
    || failure "install.sh landing guard does not query for chat-identifier facts"

# 6. iMessage bundle tick has anti-starvation fairness (never-run feeds
#    wait for the slot instead of instant-yielding forever).
grep -q 'Anti-starvation fairness' "$TICK" \
    || failure "imessage-bundle-tick.sh has no anti-starvation fairness -- a never-run feed yields on every tick"
grep -q 'OSTLER_INGEST_STARVE_WAIT' "$TICK" \
    || failure "imessage-bundle-tick.sh starvation wait is not configurable"

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_conversations_ingest_wiring: RED" >&2
    exit 1
fi
echo "test_conversations_ingest_wiring: GREEN -- channel tag + participant identity + #576 flag + landing guard + starvation fairness all present on the shipped copies"
exit 0
