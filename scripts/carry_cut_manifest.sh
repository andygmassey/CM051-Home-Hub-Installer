#!/usr/bin/env bash
# scripts/carry_cut_manifest.sh <from-version> <to-version>
# Carry cut-manifests/<from>.yaml to <to>.yaml with the owner's name replaced
# by "the owner" (Archie 2026-11-17). Refuses to overwrite; refuses (rc 2) if
# the scrub cannot run; verifies 0 occurrences in the written file.
# The version key and the per-cut rulings are still the caller's to edit.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
from="${1:?usage: carry_cut_manifest.sh <from> <to>}"; to="${2:?usage: carry_cut_manifest.sh <from> <to>}"
src="$repo/cut-manifests/$from.yaml"; dst="$repo/cut-manifests/$to.yaml"
[ -f "$src" ] || { echo "ERROR: no $src" >&2; exit 2; }
[ -e "$dst" ] && { echo "ERROR: $dst exists; refusing to overwrite" >&2; exit 2; }
python3 -I "$here/owner_scrub.py" < "$src" > "$dst.tmp" || { rc=$?; rm -f "$dst.tmp"; exit "$rc"; }
n="$(python3 -I "$here/owner_scrub.py" --count < "$dst.tmp")"
[ "$n" = "0" ] || { rm -f "$dst.tmp"; echo "ERROR: $n occurrences survive the scrub" >&2; exit 1; }
mv "$dst.tmp" "$dst"
echo "[carry] $dst written, owner-name occurrences: 0"
