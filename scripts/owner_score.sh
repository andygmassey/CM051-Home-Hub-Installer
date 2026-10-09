#!/usr/bin/env bash
# scripts/owner_score.sh -- the owner-knowledge score (Lane 17, the v1.0.108
# "so what" gate): N questions about the owner, asked over the SAME chat path a
# customer uses, graded deterministically, nothing uploaded.
#
#   scripts/owner_score.sh                       the 60 visible questions
#   scripts/owner_score.sh --limit 8             stratified sample (one per category first)
#   scripts/owner_score.sh --set all --enforce   the release gate: 80 questions, exit 1 under 70%
#   scripts/owner_score.sh --questions mine.jsonl   the owner's real questions, locked on first use
#   scripts/owner_score.sh --print-checksum      print and verify the immutable check, ask nothing
#
# Prints: the checksum it verified, SCORE, PER-CATEGORY, WORST 10 (verbatim for
# visible questions; held-back questions are withheld). Exit: 0 ran, 1 below
# --target under --enforce, 2 usage, 3 the check was changed (refuses to
# score), 78 could not run (no token / gateway down; coverage lost, never a 0).
#
# Route: ws://127.0.0.1:8000/ws/chat, Bearer ~/.ostler/secrets/zeroclaw_admin_token
# (OSTLER_PROBE_GATEWAY / OSTLER_PROBE_TOKEN_PATH override, as the walk probes do).
# A non-loopback gateway is refused. Tuning loops: read scripts/owner_score/README.md.
#
# bash 3.2 and python 3.9+ (stdlib only).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${OSTLER_PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "owner_score: no $PY on PATH" >&2; exit 78; }
exec "$PY" -I "$HERE/owner_score/owner_score.py" "$@"
