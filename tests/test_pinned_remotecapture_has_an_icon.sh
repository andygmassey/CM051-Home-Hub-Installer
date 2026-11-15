#!/bin/bash
# The RemoteCapture build install.sh pins has an icon, or is declared known-red
# for exactly that version (118 U4). RemoteCapture is not in the DMG: install.sh
# downloads it at install time, so the DMG icon gate cannot see it. This reads
# the pin the way install.sh does and checks the real release tarball.
# Exit 0 PASS, 1 FAIL, 2 CANNOT-RUN (no pin parsed, download failed).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${1:-$ROOT/install.sh}"
ver="$(sed -n 's/^OSTLER_REMOTECAPTURE_VERSION="\${OSTLER_REMOTECAPTURE_VERSION:-\([^}]*\)}".*/\1/p' "$SUBJECT" | head -1)"
repo="$(sed -n 's/^OSTLER_REMOTECAPTURE_REPO="\${OSTLER_REMOTECAPTURE_REPO:-\([^}]*\)}".*/\1/p' "$SUBJECT" | head -1)"
if [ -z "$ver" ] || [ -z "$repo" ]; then
    echo "CANNOT-RUN: could not read the RemoteCapture pin from $SUBJECT"; exit 2
fi
url="https://github.com/${repo}/releases/download/remote-capture-v${ver}/RemoteCapture-${ver}-arm64.tar.gz"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
echo "pinned RemoteCapture ${ver}: ${url}"
if ! curl -fsSL --retry 2 -o "$T/rc.tgz" "$url"; then
    echo "CANNOT-RUN: download failed; nothing was examined"; exit 2
fi
python3 "$ROOT/scripts/verify_payload_app_icons.py" "$T/rc.tgz" --known-red "$ROOT/tests/payload_app_icons_known_red.tsv"
