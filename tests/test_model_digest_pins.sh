#!/usr/bin/env bash
# tests/test_model_digest_pins.sh
#
# OS003 #233. install.sh pulled every Ollama model by a MUTABLE tag with zero
# digest checks, so the model that reads all customer data could change under
# shipped installs whenever a tag moved upstream. Measured 2026-10-18: two of
# the four tags OS003 recorded on 2026-09-06 HAD moved (qwen3.5:9b, gemma4:e2b).
#
# The fix is install.sh OSTLER_MODEL_PINS (one row per pullable model) plus
# ostler_require_model_digest after every pull. This test proves three things:
#
#   A  COVERAGE. Every model the installer can pull has a pinned sha256 digest:
#      lib/ostler-model-fit.sh OSTLER_MODEL_TAGS, every literal AI_MODEL= in
#      install.sh (the stripped-bundle ladder), EMBED_MODEL=, and every literal
#      ollama_pull_with_retry argument. A pull of any OTHER variable is RED.
#      Mutant: the same check over a copy of install.sh with one row deleted
#      must go RED, or the arm is not measuring anything.
#   B  THE VERIFIER, against a fake Ollama store: match passes; a different
#      config digest, a tampered config blob, a layer list that is not the
#      config's, a missing manifest and an unpinned model each fail with the
#      right code. Run under install.sh's own `set -Eeuo pipefail` + ERR trap,
#      which must fire ZERO times.
#   C  END TO END. The REAL "3.9 AI models" section of install.sh, lifted and
#      run with a stub `ollama` that writes a fake store: a good pull reaches
#      the end with both models verified; a registry that serves a DIFFERENT
#      model for the chat tag stops the install with ERR-13-MODEL-DIGEST-MISMATCH;
#      a model ALREADY on disk and serving (an existing customer's older copy,
#      e.g. a 0.34 GGUF) is KEPT: not pin-checked, not re-pulled, recorded as
#      model_pin=... existing=kept for the walk (#2972, Archie). The pin is a
#      promise about what we PULL.
#
# Exit 0 all pass, 1 any FAIL, 2 CANNOT-RUN.
#
# TO UPDATE A PIN (e.g. gemma4:e2b replaced in v1.0.109): resolve the new tag's
# manifest from https://registry.ollama.ai/v2/library/<name>/manifests/<tag>
# with `Accept: application/vnd.docker.distribution.manifest.v2+json`, read
# .config.digest, do it direct (`--noproxy '*'`) AND default-routed and require
# agreement, with a tag that cannot exist as a 404 control. Edit the row in
# install.sh OSTLER_MODEL_PINS and the mirror in OS003 release.toml [models].
set -uo pipefail
ROOT="${OSTLER_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="${OSTLER_TEST_INSTALL_SH:-$ROOT/install.sh}"
FIT="$ROOT/lib/ostler-model-fit.sh"
STRINGS="$ROOT/install.sh.strings.en-GB.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0
pass() { echo "ok    $*"; }
bad()  { echo "FAIL  $*"; fails=$((fails+1)); }

for f in "$INSTALL" "$FIT" "$STRINGS"; do
    [ -s "$f" ] || { echo "CANNOT-RUN: $f missing or empty"; exit 2; }
done
command -v python3 >/dev/null || { echo "CANNOT-RUN: no python3"; exit 2; }

# Lift the pin table and the four pin functions (and the pull pair) verbatim.
lift() {   # lift <install.sh> <out>
    awk '
      /^(OSTLER_MODEL_PINS|OSTLER_MODEL_WEIGHT_MEDIATYPES)=\(/ {p=1}
      p                                       {print}
      p && /^\)$/                             {p=0}
      /^(ostler_model_canonical|ostler_model_pinned_weights|ostler_model_pinned_digest|ostler_verify_model_digest|ostler_require_model_digest|ostler_note_existing_model|_gui_ollama_pull|ollama_pull_with_retry)\(\) \{/ {f=1}
      f                                       {print}
      f && /^}$/                              {f=0}
    ' "$1" > "$2"
}

# ── A: coverage ──────────────────────────────────────────────────────
coverage() {   # coverage <install.sh>  -> prints "MISSING <m>" / "BADDIGEST <m>" / "UNKNOWNVAR <l>" / "N <count>"
    local inst="$1" fns="$W/cov.$$.sh"
    lift "$inst" "$fns"
    INST="$inst" FIT="$FIT" FNS="$fns" bash -c '
        . "$FIT" >/dev/null 2>&1 || true
        . "$FNS"
        if ! declare -p OSTLER_MODEL_PINS >/dev/null 2>&1 || ! declare -F ostler_model_pinned_digest >/dev/null; then
            echo "NOTABLE"; exit 0
        fi
        models=$( {
            printf "%s\n" "${OSTLER_MODEL_TAGS[@]}"
            sed -n "s/^[[:space:]]*AI_MODEL=\"\([^\"\$]*\)\".*/\1/p" "$INST"
            sed -n "s/^[[:space:]]*EMBED_MODEL=\([A-Za-z0-9._:-]*\)[[:space:]]*$/\1/p" "$INST"
            sed -n "s/.*ollama_pull_with_retry[[:space:]]\{1,\}\([A-Za-z0-9._:-]\{1,\}\).*/\1/p" "$INST"
        } | sed "/^$/d" | sort -u )
        n=0
        while IFS= read -r m; do
            n=$((n+1))
            d="$(ostler_model_pinned_digest "$m")" || { echo "MISSING $m"; continue; }
            [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || echo "BADDIGEST $m $d"
        done <<<"$models"
        # Every variable pull must be AI_MODEL, the only variable whose values
        # are enumerated above.
        grep -n "ollama_pull_with_retry[[:space:]]*\"*\\$" "$INST" | grep -v "AI_MODEL" | sed "s/^/UNKNOWNVAR /"
        echo "N $n"
    '
}
out="$(coverage "$INSTALL")"
if grep -q '^NOTABLE' <<<"$out"; then
    bad "A coverage: install.sh has no OSTLER_MODEL_PINS table / ostler_model_pinned_digest (pulls are unpinned)"
else
    n="$(sed -n 's/^N //p' <<<"$out")"
    miss="$(grep -E '^(MISSING|BADDIGEST|UNKNOWNVAR)' <<<"$out" || true)"
    if [ -z "$miss" ] && [ "${n:-0}" -ge 4 ]; then
        pass "A coverage: $n pullable models examined, every one has a sha256 pin"
    else
        bad "A coverage: examined ${n:-0} (need >=4); $(tr '\n' ';' <<<"$miss")"
    fi
    # Mutant: delete the gemma4:e2b row; the arm must go RED for that model.
    grep -v '^    "gemma4:e2b ' "$INSTALL" > "$W/mutant.sh"
    if cmp -s "$INSTALL" "$W/mutant.sh"; then
        bad "A mutant did not apply (no gemma4:e2b row to delete)"
    elif grep -q '^MISSING gemma4:e2b$' <<<"$(coverage "$W/mutant.sh")"; then
        pass "A mutant: deleting the gemma4:e2b pin turns coverage RED"
    else
        bad "A mutant: deleting the gemma4:e2b pin was NOT caught"
    fi
fi

# Helpers that write a fake model store (python, so no shasum dependency on the runner).
# Every layer is a REAL blob whose filename is its own sha256, as Ollama stores it.
# One SHARED non-weight layer (identical across models, like a tokenizer json)
# plus three weight layers of mediaType $WT whose bytes depend on the seed; the
# third is the largest. Prints the row value "<n> <fingerprint>".
mkstore() {   # mkstore <models_dir> <name> <tag> <seed> [truncate-largest|missing-largest|noweights]
    python3 -I - "$@" <<'PY'
import hashlib, json, os, sys
d, name, tag, seed = sys.argv[1:5]; mode = sys.argv[5] if len(sys.argv) > 5 else ""
wt = os.environ.get("WT") or "application/vnd.ollama.image.model"
bd = os.path.join(d, "blobs"); os.makedirs(bd, exist_ok=True)
def blob(data):
    dg = "sha256:" + hashlib.sha256(data).hexdigest()
    with open(os.path.join(bd, dg.replace(":", "-")), "wb") as f:
        f.write(data)
    return dg
layers = [{"mediaType": "application/vnd.ollama.image.json", "digest": blob(b"shared-tokenizer"), "size": 16}]
weights = []
if mode != "noweights":
    for i in range(3):
        data = (("%s-weights-%d-" % (seed, i)) * (10 * (i + 1) ** 3)).encode()
        dg = blob(data); weights.append(dg)
        layers.append({"mediaType": wt, "digest": dg, "size": len(data)})
    big = os.path.join(bd, weights[-1].replace(":", "-"))
    if mode == "truncate-largest":
        with open(big, "r+b") as f:
            f.truncate(os.path.getsize(big) // 2)
    elif mode == "missing-largest":
        os.remove(big)
cfg = blob(json.dumps({"seed": "shared-config"}).encode())
md = os.path.join(d, "manifests", "registry.ollama.ai", "library", name)
os.makedirs(md, exist_ok=True)
with open(os.path.join(md, tag), "w") as f:
    json.dump({"schemaVersion": 2, "config": {"digest": cfg}, "layers": layers}, f)
ds = sorted(weights)
print("%d sha256:%s" % (len(ds), hashlib.sha256("".join(x + "\n" for x in ds).encode()).hexdigest()))
PY
}

lift "$INSTALL" "$W/fns.sh"
if ! grep -q '^ostler_require_model_digest() {' "$W/fns.sh"; then
    bad "B verifier: install.sh has no ostler_require_model_digest (nothing checks a pulled model)"
    bad "C end to end: nothing to run"
    echo; echo "$fails FAIL"; exit 1
fi
WT="$(FNS="$W/fns.sh" bash -c '. "$FNS"; printf "%s" "${OSTLER_MODEL_WEIGHT_MEDIATYPES[0]:-}"')"
[ -n "$WT" ] || { echo "CANNOT-RUN: install.sh OSTLER_MODEL_WEIGHT_MEDIATYPES is empty"; exit 2; }
export WT

# ── B: the verifier ──────────────────────────────────────────────────
S="$W/b"; mkdir -p "$S"
P4="$(mkstore "$S" qwen 4b "four")"                       # the model pinned as qwen:4b
P9="$(mkstore "$S" qwen 9b "nine")"                       # a different model, qwen:9b
mkstore "$S" other m "other" >/dev/null                   # other weights under a pinned tag
mkstore "$S" trunc m "trunc" truncate-largest >/dev/null  # largest weight blob cut in half
PT="$(mkstore "$W/pt" trunc m "trunc")"                   # its pin = the intact version
mkstore "$S" gone m "gone" missing-largest >/dev/null     # largest weight blob deleted
PG="$(mkstore "$W/pg" gone m "gone")"
mkstore "$S" now m "now" noweights >/dev/null             # no weight layers at all
# swapped: the 9b manifest written under the 4b tag of another name
mkdir -p "$S/manifests/registry.ollama.ai/library/swap"
cp "$S/manifests/registry.ollama.ai/library/qwen/9b" "$S/manifests/registry.ollama.ai/library/swap/4b"

res="$(OLLAMA_MODELS="$S" P4="$P4" P9="$P9" PT="$PT" PG="$PG" FNS="$W/fns.sh" STRINGS="$STRINGS" bash -c '
    set -Eeuo pipefail
    errs=0; trap "errs=\$((errs+1))" ERR
    . "$STRINGS"
    ok(){ echo "OKLINE $*" >&2; }; info(){ :; }; warn(){ :; }
    fail_with_code(){ echo "CODE $1"; }
    . "$FNS"
    OSTLER_MODEL_PINS=( "qwen:4b $P4" "qwen:9b $P9" "other:m $P4" "swap:4b $P4" "trunc:m $PT" "gone:m $PG" "now:m $P4" "absent:m $P4" )
    for m in qwen:4b qwen:9b other:m swap:4b trunc:m gone:m now:m absent:m notpinned:m; do
        rc=0; ostler_verify_model_digest "$m" || rc=$?
        echo "RC $m $rc"; echo "GOT $m $OSTLER_MODEL_DIGEST_GOT"; echo "DETAIL $m $OSTLER_MODEL_DIGEST_DETAIL"
        ostler_require_model_digest "$m" 2>/dev/null | sed "s/^/REQ $m /"
    done
    echo "ERRS $errs"
' 2>/dev/null)"
expect() {   # expect <label> <pattern>
    if grep -qx -- "$2" <<<"$res"; then pass "B $1"; else bad "B $1 (want line '$2'; got: $(tr '\n' ';' <<<"$res"))"; fi
}
expect "matching weights pass (rc 0)"                                 "RC qwen:4b 0"
expect "a second model matching its own pin passes (rc 0)"            "RC qwen:9b 0"
expect "other weights under a pinned tag are a MISMATCH (rc 1)"       "RC other:m 1"
expect "  ...and fail the step ERR-13-MODEL-DIGEST-MISMATCH"          "REQ other:m CODE ERR-13-MODEL-DIGEST-MISMATCH"
expect "SWAPPED manifest (9b weights under a 4b-pinned tag) FAILS"    "RC swap:4b 1"
expect "TRUNCATED largest weight blob fails the recompute (rc 1)"     "RC trunc:m 1"
expect "  ...named as a corrupt store"                                "DETAIL trunc:m largest weight blob does not hash to its own name (corrupt store)"
expect "missing largest weight blob is CANNOT-VERIFY (rc 2)"          "RC gone:m 2"
expect "a manifest with NO weight layers is CANNOT-VERIFY (rc 2)"     "RC now:m 2"
expect "missing manifest is CANNOT-VERIFY, not a pass (rc 2)"         "RC absent:m 2"
expect "  ...and fails the step ERR-13-MODEL-DIGEST-UNREADABLE"       "REQ absent:m CODE ERR-13-MODEL-DIGEST-UNREADABLE"
expect "unpinned model is refused (rc 3)"                             "RC notpinned:m 3"
expect "  ...and fails the step ERR-13-MODEL-UNPINNED"                "REQ notpinned:m CODE ERR-13-MODEL-UNPINNED"
expect "ERR trap fired 0 times across every case"                     "ERRS 0"
if grep -q '^REQ qwen:4b CODE' <<<"$res"; then bad "B a MATCHING model was failed"; else pass "B matching model is not failed (control)"; fi

# The 4b and 9b pins must DIFFER. Two layers of defence:
#  (1) the fingerprints the verifier computes for two different models differ;
#  (2) MUTANT: if the weight mediaType set degenerates to the SHARED layer's
#      type, the two fingerprints collide, and the distinct-pins check below
#      must catch it, or a pin that matches every model would ship.
g4="$(sed -n 's/^GOT qwen:4b //p' <<<"$res")"; g9="$(sed -n 's/^GOT qwen:9b //p' <<<"$res")"
[ -n "$g4" ] && [ "$g4" != "$g9" ] && pass "B 4b and 9b weight fingerprints DIFFER ($g4 vs $g9)" \
    || bad "B 4b and 9b weight fingerprints are equal or empty ('$g4' / '$g9')"
distinct_pins() {   # distinct_pins <fns.sh> -> "DUP <fp> <tagA> <tagB>" lines, or nothing
    FNS="$1" bash -c '
        . "$FNS"
        for row in "${OSTLER_MODEL_PINS[@]}"; do
            read -r tag n fp <<<"$row"
            [[ "$fp" == sha256:* ]] && printf "%s\n" "$fp"
        done | sort | uniq -d | sed "s/^/DUP /"'
}
mut="$(OLLAMA_MODELS="$S" FNS="$W/fns.sh" bash -c '
    . "$FNS"
    OSTLER_MODEL_WEIGHT_MEDIATYPES=( "application/vnd.ollama.image.json" )
    OSTLER_MODEL_PINS=( "qwen:4b 0 sha256:x" "qwen:9b 0 sha256:x" )
    ostler_verify_model_digest qwen:4b || true; a="$OSTLER_MODEL_DIGEST_GOT"
    ostler_verify_model_digest qwen:9b || true; b="$OSTLER_MODEL_DIGEST_GOT"
    printf "%s\n%s\n" "$a" "$b"' 2>/dev/null)"
m4="$(sed -n 1p <<<"$mut")"; m9="$(sed -n 2p <<<"$mut")"
cp "$W/fns.sh" "$W/fns_dup.sh"
printf '\nOSTLER_MODEL_PINS=( "qwen:4b %s" "qwen:9b %s" )\n' "$m4" "$m9" >> "$W/fns_dup.sh"
if [ -n "$m4" ] && [ "$m4" = "$m9" ] && grep -q '^DUP ' <<<"$(distinct_pins "$W/fns_dup.sh")"; then
    pass "B mutant: a weight set degenerated to the shared layer gives 4b == 9b, and the distinct-pins check catches it"
else
    bad "B mutant: shared-layer degeneration not caught (4b='$m4' 9b='$m9')"
fi
# The REAL table: no two rows may share a fingerprint.
dups="$(distinct_pins "$W/fns.sh")"
[ -z "$dups" ] && pass "B the shipped table has no two rows with the same weight fingerprint" \
    || bad "B the shipped table has duplicate fingerprints: $(tr '\n' ';' <<<"$dups")"
# The real table resolves a bare name to :latest, as `ollama pull` does.
real="$(OLLAMA_MODELS="$W/empty" FNS="$W/fns.sh" bash -c '. "$FNS"; ostler_model_pinned_digest nomic-embed-text' 2>/dev/null || true)"
[[ "$real" =~ ^sha256:[0-9a-f]{64}$ ]] && pass "B bare 'nomic-embed-text' resolves to its :latest pin" \
    || bad "B bare 'nomic-embed-text' has no pin via :latest (got '$real')"

# ── E: the shipped table equals the committed clean-pull evidence ─────
EV="${ROOT}/docs/model-pins/ollama-0.34.0"
CHK="${ROOT}/scripts/model_pins_from_evidence.py"
if [ ! -f "$EV/PROVENANCE.tsv" ] || [ ! -f "$CHK" ]; then
    bad "E evidence: missing $EV/PROVENANCE.tsv or $CHK"
else
    eo="$(python3 -I "$CHK" --check "$EV" "$INSTALL" 2>&1)"; erc=$?
    if [ "$erc" = 0 ] && grep -q '^examined [0-9]* evidence manifest(s) against [0-9]* install.sh row(s): PASS$' <<<"$eo" \
       && [ "$(grep -c '^ok ' <<<"$eo")" -ge 4 ]; then
        pass "E every pinned row equals the committed clean-pull manifest ($(tail -1 <<<"$eo"))"
    else bad "E table vs evidence (rc $erc): $(tr '\n' ';' <<<"$eo")"; fi
    # Mutant 1: a row edited in install.sh must fail.
    sed 's/^    "qwen3.5:9b              2 sha256:8a/    "qwen3.5:9b              2 sha256:9a/' "$INSTALL" > "$W/inst_mut1.sh"
    if cmp -s "$INSTALL" "$W/inst_mut1.sh"; then bad "E mutant 1 did not apply"
    elif python3 -I "$CHK" --check "$EV" "$W/inst_mut1.sh" >/dev/null 2>&1; then bad "E mutant 1: an edited 9b row was NOT caught"
    else pass "E mutant 1: an edited 9b row in install.sh is caught"; fi
    # Mutant 2: one byte of an evidence manifest changed must fail.
    cp -R "$EV" "$W/ev_mut2"; printf ' ' >> "$W/ev_mut2/qwen3.5_9b.json"
    if python3 -I "$CHK" --check "$W/ev_mut2" "$INSTALL" >/dev/null 2>&1; then bad "E mutant 2: a changed evidence file was NOT caught"
    else pass "E mutant 2: an evidence manifest that no longer hashes to its PROVENANCE sha is caught"; fi
    # Mutant 3: drop the projector mediaType; the 9b and e2b rows must stop matching.
    grep -v '^    "application/vnd.ollama.image.projector"$' "$INSTALL" > "$W/inst_mut3.sh"
    if cmp -s "$INSTALL" "$W/inst_mut3.sh"; then bad "E mutant 3 did not apply"
    elif python3 -I "$CHK" --check "$EV" "$W/inst_mut3.sh" >/dev/null 2>&1; then bad "E mutant 3: dropping the projector weight type was NOT caught"
    else pass "E mutant 3: dropping the projector weight type from install.sh is caught"; fi
fi

# ── C: the real 3.9 section, end to end ──────────────────────────────
awk '/^progress "Downloading AI models/{f=1} /^# ── 3\.10 /{f=0} f{print}' "$INSTALL" > "$W/section.sh"
nsec="$(wc -l < "$W/section.sh" | tr -d ' ')"
if [ "${nsec:-0}" -lt 20 ] || ! grep -q 'ollama_pull_with_retry' "$W/section.sh"; then
    echo "CANNOT-RUN: could not lift the 3.9 AI-models section ($nsec lines)"; exit 2
fi
# Every pull in install.sh must be inside that section (or the wrapper itself).
stray="$(grep -n 'ollama_pull_with_retry \|ollama pull ' "$INSTALL" | grep -v '^[0-9]*:[[:space:]]*#' \
         | grep -v '_gui_ollama_pull "\$model"\|ollama pull "\$model"' \
         | while IFS=: read -r ln _; do
               s="$(awk '/^progress "Downloading AI models/{print NR; exit}' "$INSTALL")"
               e="$(awk '/^# ── 3\.10 /{print NR; exit}' "$INSTALL")"
               [ "$ln" -gt "$s" ] && [ "$ln" -lt "$e" ] || echo "$ln"
           done)"
[ -z "$stray" ] && pass "C every model pull in install.sh is inside the verified 3.9 section" \
    || bad "C pull call(s) outside the verified section at install.sh line(s): $(tr '\n' ' ' <<<"$stray")"

mkdir -p "$W/bin"
cat > "$W/bin/ollama" <<'O'
#!/bin/bash
# Stub: `list` prints $STORE_LIST; `pull X` writes a fake manifest+blob seeded
# by $SEED_<sanitised X> (default "good") and logs the pull.
case "$1" in
  list) cat "$STATE/list" 2>/dev/null; exit 0 ;;
  pull) echo "$2" >> "$STATE/pulls"
        n="${2%%:*}"; t="${2#*:}"; [ "$t" = "$2" ] && t=latest
        v="SEED_$(printf '%s' "$n" | tr -c 'A-Za-z0-9' '_')"; seed="${!v:-good-$n}"
        python3 -I "$STATE/mkstore.py" "$OLLAMA_MODELS" "$n" "$t" "$seed" >/dev/null
        printf 'pulling 4e30e2665218: 100%%\n'; exit 0 ;;
esac
exit 0
O
cat > "$W/bin/curl" <<'C'
#!/bin/bash
# Stub for the embed healthcheck: write a 768-dim vector to -o, print 200.
o=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { o="$2"; shift; }; shift; done
[ -n "$o" ] && python3 -I -c "import json,sys;json.dump({'embeddings':[[0.5]*768]},open(sys.argv[1],'w'))" "$o"
printf 200
C
cat > "$W/bin/mktemp" <<'M'
#!/bin/sh
if [ "${1:-}" = "-t" ]; then exec /usr/bin/mktemp "${TMPDIR:-/tmp}/${2:-tmp}.XXXXXX"; fi
exec /usr/bin/mktemp "$@"
M
chmod +x "$W/bin/ollama" "$W/bin/curl" "$W/bin/mktemp"
# The stub's store writer is the same mkstore body.
awk '/^    python3 -I - "\$@" <<'"'"'PY'"'"'$/{f=1; next} f&&/^PY$/{f=0} f{print}' "$0" > "$W/mkstore.py"
[ -s "$W/mkstore.py" ] || { echo "CANNOT-RUN: could not extract the store writer"; exit 2; }

scenario() {   # scenario <name> <preinstalled-embed-seed|-> <chat-seed> [preinstalled-chat-seed]  -> prints "EXIT n" "CODE c" "PULLS ..." "ERRS n" "PINREC ..." OKLINE...
    local name="$1" pre="$2" chat="$3" prechat="${4:--}" st="$W/c_$1"
    mkdir -p "$st/models"; cp "$W/mkstore.py" "$st/mkstore.py"; : > "$st/pulls"
    local ge gc
    ge="$(python3 -I "$st/mkstore.py" "$W/pin_$name" nomic-embed-text latest good-nomic-embed-text)"
    gc="$(python3 -I "$st/mkstore.py" "$W/pin_$name" qwen3.5 9b good-qwen3.5)"
    if [ "$pre" != "-" ]; then
        python3 -I "$st/mkstore.py" "$st/models" nomic-embed-text latest "$pre" >/dev/null
        echo "nomic-embed-text:latest    0a109f422b47    274 MB    1 day ago" >> "$st/list"
    fi
    if [ "$prechat" != "-" ]; then
        python3 -I "$st/mkstore.py" "$st/models" qwen3.5 9b "$prechat" >/dev/null
        echo "qwen3.5:9b    6488c96fa5fa    6.6 GB    3 weeks ago" >> "$st/list"
    fi
    PATH="$W/bin:/usr/bin:/bin" STATE="$st" OLLAMA_MODELS="$st/models" SEED_qwen3_5="$chat" \
    GE="$ge" GC="$gc" FNS="$W/fns.sh" SEC="$W/section.sh" STRINGS="$STRINGS" bash -c '
        set -Eeuo pipefail
        trap "echo x >> \"\$STATE/errs\"" ERR
        . "$STRINGS"
        OSTLER_GUI=0; PULL_MODEL=y; AI_MODEL=qwen3.5:9b; AI_MODEL_SIZE="~6.6 GB"
        OSTLER_DIR="$STATE"; INSTALL_LOG="$STATE/log"; OSTLER_MODEL_PIN_STATE_FILE="$STATE/model-pins"
        progress(){ :; }; info(){ :; }; warn(){ :; }; gui_emit(){ :; }; gui_log(){ :; }; sleep(){ :; }
        ok(){ echo "OKLINE $*"; }
        fail_with_code(){ echo "CODE $1"; exit 1; }
        . "$FNS"
        OSTLER_MODEL_PINS=( "nomic-embed-text:latest $GE" "qwen3.5:9b $GC" )
        . "$SEC"
        echo "REACHED-END"
    ' 2>"$st/stderr"
    echo "EXIT $?"
    echo "PULLS $(tr '\n' ' ' < "$st/pulls" 2>/dev/null)"
    echo "ERRS $(cat "$st/errs" 2>/dev/null | wc -l | tr -d ' ')"
    sed 's/^/PINREC /' "$st/model-pins" 2>/dev/null
}

r="$(scenario good - good-qwen3.5)"
if grep -qx 'EXIT 0' <<<"$r" && grep -qx 'REACHED-END' <<<"$r" \
   && [ "$(grep -c '^OKLINE .*verified against its pinned digest' <<<"$r")" = 2 ] && grep -qx 'ERRS 0' <<<"$r"; then
    pass "C good pulls: section completes, both models verified against their pins, ERR trap 0"
else
    bad "C good pulls: $(tr '\n' ';' <<<"$r")"
fi

r="$(scenario moved - SOMETHING-ELSE)"
if grep -qx 'CODE ERR-13-MODEL-DIGEST-MISMATCH' <<<"$r" && ! grep -qx 'REACHED-END' <<<"$r" && grep -qx 'EXIT 1' <<<"$r"; then
    pass "C tag moved upstream (registry serves another model): install STOPS with ERR-13-MODEL-DIGEST-MISMATCH"
else
    bad "C tag moved upstream was not stopped: $(tr '\n' ';' <<<"$r")"
fi

r="$(scenario stale STALE-OLD good-qwen3.5)"
if grep -qx 'EXIT 0' <<<"$r" && grep -qx 'REACHED-END' <<<"$r" && ! grep -q '^PULLS .*nomic-embed-text' <<<"$r" \
   && grep -q '^PINREC model_pin=nomic-embed-text:latest existing=kept pin_check=skipped on_disk=differs ' <<<"$r" \
   && ! grep -q '^CODE ' <<<"$r" && grep -qx 'ERRS 0' <<<"$r"; then
    pass "C an existing embed model that differs from the pin is KEPT: not re-pulled, no stop, recorded on_disk=differs"
else
    bad "C existing (differing) embed model was not kept: $(tr '\n' ';' <<<"$r")"
fi

# An existing customer's chat model written by an older Ollama (the 0.34 GGUF
# shape: a different config digest under the same tag) must not stop the install.
r="$(scenario existing034 good-nomic-embed-text good-qwen3.5 OLLAMA-034-GGUF)"
if grep -qx 'EXIT 0' <<<"$r" && grep -qx 'REACHED-END' <<<"$r" && ! grep -q '^PULLS .*qwen3.5' <<<"$r" \
   && grep -q '^PINREC model_pin=qwen3.5:9b existing=kept pin_check=skipped on_disk=differs ' <<<"$r" \
   && ! grep -q '^CODE ' <<<"$r" && grep -qx 'ERRS 0' <<<"$r"; then
    pass "C an existing customer's 0.34-era chat model is KEPT: no ERR-13 stop, not re-pulled, recorded"
else
    bad "C existing 0.34-era chat model tripped the pin: $(tr '\n' ';' <<<"$r")"
fi

r="$(scenario fresh good-nomic-embed-text good-qwen3.5)"
if grep -qx 'EXIT 0' <<<"$r" && ! grep -q '^PULLS .*nomic-embed-text' <<<"$r" \
   && grep -q '^PINREC model_pin=nomic-embed-text:latest existing=kept pin_check=skipped on_disk=match ' <<<"$r"; then
    pass "C control: a correct pre-installed embed model is kept, NOT re-pulled, and recorded on_disk=match"
else
    bad "C control, correct pre-installed embed model: $(tr '\n' ';' <<<"$r")"
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAIL"; exit 1
