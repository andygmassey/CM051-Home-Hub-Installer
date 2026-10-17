# shellcheck shell=bash
# lib/companion_pair.sh -- the box-side shell that pairs a synthetic companion
# through the REAL customer flow (lib/companion_pair.py): the owner mints a QR
# token on the loopback admin port, then /auth/pair/init + /auth/pair/register
# on :8443, exactly as CM031 does. Replaces the legacy `POST :8443/pair` with
# a 6-digit code, which ostler-assistant #492/#501 refuse on :8443.
#
# companion_pair_box_snippet <gateway-expr> [replay 0|1]
#   prints shell text for a box-side script. After it runs, $CP_JSON holds the
#   helper's one-line JSON result and $CP_TOKEN the device bearer (empty on
#   failure). It needs a python with `cryptography`: OSTLER_PAIR_PY, then the
#   Ostler venv, then the system pythons; none -> CP_JSON names the stage
#   "crypto" so the caller can say CANNOT-RUN.
_CP_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

companion_pair_box_snippet() {
    local gw="$1" replay="${2:-0}" b64
    b64="$(base64 < "${_CP_HERE}/companion_pair.py" | tr -d '\n')"
    cat <<SNIP
CP_PY_FILE=\$(mktemp -t ostler-companion-pair.XXXXXX)
printf %s '${b64}' | base64 -d > "\$CP_PY_FILE"
CP_PY=''
for _p in "\${OSTLER_PAIR_PY:-}" "\$HOME/.ostler/.venv/bin/python3" /usr/bin/python3 python3; do
    [ -n "\$_p" ] || continue
    "\$_p" -c 'import cryptography' 2>/dev/null && { CP_PY="\$_p"; break; }
done
if [ -n "\${OSTLER_COMPANION_PAIR_CMD:-}" ]; then
    # TEST SEAM ONLY: a stub standing in for the helper (tests/ sets it).
    CP_JSON=\$(\$OSTLER_COMPANION_PAIR_CMD pair --gateway "${gw}" --replay ${replay} 2>/dev/null)
elif [ -n "\$CP_PY" ]; then
    CP_JSON=\$("\$CP_PY" "\$CP_PY_FILE" pair --gateway "${gw}" --replay ${replay} 2>/dev/null)
else
    CP_JSON='{"ok": false, "stage": "crypto", "http": null, "detail": "no python with cryptography on the box", "device_token": null, "replay_http": null}'
fi
rm -f "\$CP_PY_FILE"
CP_TOKEN=\$(printf '%s' "\$CP_JSON" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("device_token") or "")' 2>/dev/null)
SNIP
}

# companion_unpair_box_snippet <since-epoch> <remove-passkey 0|1>
#   prints shell text for a box-side script that revokes every device the walk
#   paired (paired_at >= since) through DELETE /api/devices/{id}, removes the
#   passkey file only when the walk found none, and reads /health. After it
#   runs, $CU_JSON holds the helper's one-line JSON result.
companion_unpair_box_snippet() {
    local since="$1" rmpk="${2:-0}" b64
    b64="$(base64 < "${_CP_HERE}/companion_pair.py" | tr -d '\n')"
    cat <<SNIP
CU_PY_FILE=\$(mktemp -t ostler-companion-unpair.XXXXXX)
printf %s '${b64}' | base64 -d > "\$CU_PY_FILE"
CU_PY=''
for _p in "\${OSTLER_PAIR_PY:-}" "\$HOME/.ostler/.venv/bin/python3" /usr/bin/python3 python3; do
    [ -n "\$_p" ] || continue
    "\$_p" -c 'import cryptography' 2>/dev/null && { CU_PY="\$_p"; break; }
done
if [ -n "\$CU_PY" ]; then
    CU_JSON=\$("\$CU_PY" "\$CU_PY_FILE" unpair --since ${since} --remove-passkey ${rmpk} 2>/dev/null)
else
    CU_JSON='{"ok": false, "detail": "no python with cryptography on the box"}'
fi
rm -f "\$CU_PY_FILE"
SNIP
}
