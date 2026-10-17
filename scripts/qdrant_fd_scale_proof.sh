#!/usr/bin/env bash
# qdrant_fd_scale_proof.sh -- does the scale fixture drive the PINNED Qdrant out
# of file descriptors at the shipped nofile, and does a raised limit hold?
#
#   scripts/qdrant_fd_scale_proof.sh --nofile 1024  --out DIR   # must go RED
#   scripts/qdrant_fd_scale_proof.sh --nofile 65535 --out DIR   # must stay GREEN
#
# What runs, and what is a stand-in:
#   REAL  the Qdrant image at the digest install.sh pins, with --ulimit nofile=N
#   REAL  the CM024 hydrate path (vendor/cm024_knowledge: `convert` then
#         `embed`, the exact flags install.sh uses), driven by
#         lib/scale_fixture.py replay over the synthetic fixture
#   STAND-IN  Ollama: scripts/qdrant_fd_scale_proof/fake_ollama.py answers each
#         embed with a deterministic vector after --delay seconds, which models
#         the box's embed time. That pacing is what grows the SST count.
#
# Needs docker (colima is fine) and OSTLER_PROOF_PYTHON pointing at a python
# with vendor/cm024_knowledge/requirements.txt installed. Writes nothing
# outside --out and one container it removes at the end. Synthetic data only.
#
# Exit 0 when the observed outcome matches --expect (red|green), else 1;
# 2 when it could not run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
IMAGE="ghcr.io/creativemachines-ai/qdrant@sha256:d774e7bb65744454984c6021637a0da89271f30df15e48601a9fafc926d26b1f"
NOFILE=1024; OUT=""; DELAY=0.04; REMINDERS=9000; NOTES=6000; EXPECT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --nofile) NOFILE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --delay) DELAY="$2"; shift 2 ;;
        --reminders) REMINDERS="$2"; shift 2 ;;
        --notes) NOTES="$2"; shift 2 ;;
        --expect) EXPECT="$2"; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$OUT" ] || { echo "--out is required" >&2; exit 2; }
[ -n "$EXPECT" ] || { [ "$NOFILE" -le 1024 ] && EXPECT=red || EXPECT=green; }
# Loopback only: a proxy in the environment (measured: Privoxy on a dev Mac)
# answers 503 for 127.0.0.1 and would read as Qdrant being down.
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
export NO_PROXY='*' no_proxy='*'
command -v docker >/dev/null || { echo "CANNOT-RUN: no docker" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "CANNOT-RUN: docker is not running" >&2; exit 2; }
mkdir -p "$OUT"
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

FIX="$OUT/fixture"
[ -f "$FIX/manifest.json" ] || python3 "$ROOT/scripts/box_walk_probes/lib/scale_fixture.py" generate \
    --out "$FIX" --reminders "$REMINDERS" --notes "$NOTES" >/dev/null || { echo "CANNOT-RUN: fixture" >&2; exit 2; }

NAME="qdrant-fd-proof-$NOFILE-$$"
cleanup() { kill "${FAKE:-}" "${SAMPLER:-}" 2>/dev/null; docker rm -f "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT
# A free port can be taken between asking and binding (two proofs at once);
# retry with a fresh one rather than reporting the image as broken.
started=0
for _ in 1 2 3 4 5; do
    QPORT="$(free_port)"
    docker rm -f "$NAME" >/dev/null 2>&1
    if docker run -d --name "$NAME" --ulimit "nofile=$NOFILE:$NOFILE" -p "127.0.0.1:$QPORT:6333" "$IMAGE" >/dev/null 2>&1; then
        started=1; break
    fi
done
[ "$started" -eq 1 ] || { echo "CANNOT-RUN: could not start $IMAGE" >&2; exit 2; }
OPORT="$(free_port)"
python3 "$HERE/qdrant_fd_scale_proof/fake_ollama.py" "$OPORT" "$DELAY" & FAKE=$!
for _ in $(seq 1 60); do curl -s --noproxy '*' -o /dev/null "http://127.0.0.1:$QPORT/" && break; sleep 1; done

# The live limit and fd count of the qdrant PROCESS, not the container's shell.
sample() {
    docker exec "$NAME" sh -c 'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = qdrant ] || continue;
        lim=$(awk "/Max open files/ {print \$4}" $p/limits); fds=$(ls $p/fd | wc -l);
        sst=$(find /qdrant/storage -name "*.sst" | wc -l); echo "$lim $fds $sst"; break; done' 2>/dev/null
}
printf 'secs\tlimit\tfds\tsst\n' > "$OUT/samples.tsv"
( t0=$(date +%s); while :; do s="$(sample)"; [ -n "$s" ] && printf '%s\t%s\n' "$(( $(date +%s) - t0 ))" "$(echo "$s" | tr ' ' '\t')" >> "$OUT/samples.tsv"; sleep 15; done ) & SAMPLER=$!

OSTLER_PROOF_PYTHON="${OSTLER_PROOF_PYTHON:?set OSTLER_PROOF_PYTHON}" \
python3 "$ROOT/scripts/box_walk_probes/lib/scale_fixture.py" replay --fixture "$FIX" \
    --knowledge-bin "$HERE/qdrant_fd_scale_proof/ostler-knowledge-from-vendor" \
    --qdrant "http://127.0.0.1:$QPORT" --ollama "http://127.0.0.1:$OPORT" --home "$OUT/home" > "$OUT/replay.json"
s="$(sample)"; [ -n "$s" ] && printf 'end\t%s\n' "$(echo "$s" | tr ' ' '\t')" >> "$OUT/samples.tsv"
docker logs "$NAME" > "$OUT/qdrant.log" 2>&1
TOOMANY="$(grep -c 'Too many open files' "$OUT/qdrant.log")"
MAXFDS="$(awk -F'\t' 'NR>1 && $3+0>m {m=$3+0} END {print m+0}' "$OUT/samples.tsv")"
MAXSST="$(awk -F'\t' 'NR>1 && $4+0>m {m=$4+0} END {print m+0}' "$OUT/samples.tsv")"
DIAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["diagnostics"])' "$OUT/replay.json")"

echo "nofile=$NOFILE  delay=${DELAY}s  max_open_fds=$MAXFDS  max_sst=$MAXSST  'Too many open files' lines=$TOOMANY"
red=0
for log in "$DIAG"/hydrate-*.log; do
    c="$(grep -aE 'Chunks created:' "$log" | tail -1 | tr -dc '0-9')"; c="${c:-0}"
    v="$(grep -aE 'Vectors inserted:' "$log" | tail -1 | tr -dc '0-9')"; v="${v:-0}"
    echo "  $(basename "$log"): chunks created $c, vectors inserted $v"
    [ "$c" -gt 0 ] && [ "$v" -lt "$c" ] && red=1
done
[ "$TOOMANY" -gt 0 ] && red=1
# A run whose embed never started is the harness, not a verdict.
if [ "$red" -eq 0 ] && ! grep -aqE 'Vectors inserted: [1-9]' "$DIAG"/hydrate-*.log; then
    echo "CANNOT-RUN: no vector was inserted on any step; see $DIAG"; exit 2
fi
outcome=green; [ "$red" -eq 1 ] && outcome=red
echo "OUTCOME: $outcome (expected $EXPECT)"
[ "$outcome" = "$EXPECT" ]
