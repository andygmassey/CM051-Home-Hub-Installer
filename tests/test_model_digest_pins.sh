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
#      a stale pre-installed embed model is re-pulled, not trusted.
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
      /^OSTLER_MODEL_PINS=\(/                {p=1}
      p                                       {print}
      p && /^\)$/                             {p=0}
      /^(ostler_model_canonical|ostler_model_pinned_digest|ostler_verify_model_digest|ostler_require_model_digest|_gui_ollama_pull|ollama_pull_with_retry)\(\) \{/ {f=1}
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

# Fake Ollama store helpers (python, so no shasum dependency on the runner).
mkstore() {   # mkstore <models_dir> <name> <tag> <cfg-seed> [tamper-blob|wrong-layers]
    python3 -I - "$@" <<'PY'
import hashlib, json, os, sys
d, name, tag, seed = sys.argv[1:5]; mode = sys.argv[5] if len(sys.argv) > 5 else ""
layers = ["sha256:" + hashlib.sha256((seed + str(i)).encode()).hexdigest() for i in range(3)]
cfg = json.dumps({"model_format": "gguf", "rootfs": {"type": "layers", "diff_ids": layers}}).encode()
cd = "sha256:" + hashlib.sha256(cfg).hexdigest()
os.makedirs(os.path.join(d, "blobs"), exist_ok=True)
with open(os.path.join(d, "blobs", cd.replace(":", "-")), "wb") as f:
    f.write(cfg + (b" " if mode == "tamper-blob" else b""))
ml = layers if mode != "wrong-layers" else layers[:2] + ["sha256:" + "0" * 64]
md = os.path.join(d, "manifests", "registry.ollama.ai", "library", name)
os.makedirs(md, exist_ok=True)
with open(os.path.join(md, tag), "w") as f:
    json.dump({"schemaVersion": 2, "config": {"digest": cd}, "layers": [{"digest": l} for l in ml]}, f)
print(cd)
PY
}

lift "$INSTALL" "$W/fns.sh"
if ! grep -q '^ostler_require_model_digest() {' "$W/fns.sh"; then
    bad "B verifier: install.sh has no ostler_require_model_digest (nothing checks a pulled model)"
    bad "C end to end: nothing to run"
    echo; echo "$fails FAIL"; exit 1
fi

# ── B: the verifier ──────────────────────────────────────────────────
S="$W/b"; mkdir -p "$S"
good="$(mkstore "$S" pinned m "good")"
other="$(mkstore "$W/other" pinned m "other")"
mkstore "$S" wrongcfg m "other" >/dev/null                # manifest names the OTHER config
mkstore "$W/t" tamper m "good" tamper-blob >/dev/null      # blob bytes != pin
mkdir -p "$S/manifests/registry.ollama.ai/library/tamper"
cp "$W/t/manifests/registry.ollama.ai/library/tamper/m" "$S/manifests/registry.ollama.ai/library/tamper/m"
mkstore "$W/l" layers m "good" wrong-layers >/dev/null     # layers != diff_ids
mkdir -p "$S/manifests/registry.ollama.ai/library/layers"
cp "$W/l/manifests/registry.ollama.ai/library/layers/m" "$S/manifests/registry.ollama.ai/library/layers/m"
# tamper: the store's blob for the good digest must be the TAMPERED one for
# that case only, so give it its own store.
TS="$W/ts"; mkdir -p "$TS"; cp -R "$W/t/." "$TS/"

res="$(OLLAMA_MODELS="$S" TS="$TS" GOOD="$good" FNS="$W/fns.sh" STRINGS="$STRINGS" bash -c '
    set -Eeuo pipefail
    errs=0; trap "errs=\$((errs+1))" ERR
    . "$STRINGS"
    ok(){ echo "OKLINE $*" >&2; }; info(){ :; }; warn(){ :; }
    fail_with_code(){ echo "CODE $1"; }
    . "$FNS"
    OSTLER_MODEL_PINS=( "pinned:m $GOOD" "wrongcfg:m $GOOD" "tamper:m $GOOD" "layers:m $GOOD" "absent:m $GOOD" )
    for m in pinned:m wrongcfg:m layers:m absent:m notpinned:m; do
        rc=0; ostler_verify_model_digest "$m" || rc=$?
        echo "RC $m $rc"; ostler_require_model_digest "$m" 2>/dev/null | sed "s/^/REQ $m /"
    done
    rc=0; OLLAMA_MODELS="$TS" ostler_verify_model_digest tamper:m || rc=$?
    echo "RC tamper:m $rc"
    echo "ERRS $errs"
' 2>/dev/null)"
expect() {   # expect <label> <pattern>
    if grep -qx -- "$2" <<<"$res"; then pass "B $1"; else bad "B $1 (want line '$2'; got: $(tr '\n' ';' <<<"$res"))"; fi
}
expect "matching digest passes (rc 0)"                          "RC pinned:m 0"
expect "different config digest is a MISMATCH (rc 1)"           "RC wrongcfg:m 1"
expect "  ...and fails the step ERR-13-MODEL-DIGEST-MISMATCH"   "REQ wrongcfg:m CODE ERR-13-MODEL-DIGEST-MISMATCH"
expect "tampered config blob is a MISMATCH (rc 1)"              "RC tamper:m 1"
expect "layer list not the pinned config's is a MISMATCH"       "RC layers:m 1"
expect "missing manifest is CANNOT-VERIFY, not a pass (rc 2)"   "RC absent:m 2"
expect "  ...and fails the step ERR-13-MODEL-DIGEST-UNREADABLE" "REQ absent:m CODE ERR-13-MODEL-DIGEST-UNREADABLE"
expect "unpinned model is refused (rc 3)"                       "RC notpinned:m 3"
expect "  ...and fails the step ERR-13-MODEL-UNPINNED"          "REQ notpinned:m CODE ERR-13-MODEL-UNPINNED"
expect "ERR trap fired 0 times across every case"               "ERRS 0"
if grep -q '^REQ pinned:m CODE' <<<"$res"; then bad "B a MATCHING model was failed"; else pass "B matching model is not failed (control)"; fi
# The real table resolves a bare name to :latest, as `ollama pull` does.
real="$(OLLAMA_MODELS="$W/empty" FNS="$W/fns.sh" bash -c '. "$FNS"; ostler_model_pinned_digest nomic-embed-text' 2>/dev/null || true)"
[[ "$real" =~ ^sha256:[0-9a-f]{64}$ ]] && pass "B bare 'nomic-embed-text' resolves to its :latest pin" \
    || bad "B bare 'nomic-embed-text' has no pin via :latest (got '$real')"

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

scenario() {   # scenario <name> <preinstalled-embed-seed|-> <chat-seed>  -> prints "EXIT n" "CODE c" "PULLS ..." "ERRS n" OKLINE...
    local name="$1" pre="$2" chat="$3" st="$W/c_$1"
    mkdir -p "$st/models"; cp "$W/mkstore.py" "$st/mkstore.py"
    local ge gc
    ge="$(python3 -I "$st/mkstore.py" "$W/pin_$name" nomic-embed-text latest good-nomic-embed-text)"
    gc="$(python3 -I "$st/mkstore.py" "$W/pin_$name" qwen3.5 9b good-qwen3.5)"
    if [ "$pre" != "-" ]; then
        python3 -I "$st/mkstore.py" "$st/models" nomic-embed-text latest "$pre" >/dev/null
        echo "nomic-embed-text:latest    0a109f422b47    274 MB    1 day ago" > "$st/list"
    fi
    PATH="$W/bin:/usr/bin:/bin" STATE="$st" OLLAMA_MODELS="$st/models" SEED_qwen3_5="$chat" \
    GE="$ge" GC="$gc" FNS="$W/fns.sh" SEC="$W/section.sh" STRINGS="$STRINGS" bash -c '
        set -Eeuo pipefail
        trap "echo x >> \"\$STATE/errs\"" ERR
        . "$STRINGS"
        OSTLER_GUI=0; PULL_MODEL=y; AI_MODEL=qwen3.5:9b; AI_MODEL_SIZE="~6.6 GB"
        OSTLER_DIR="$STATE"; INSTALL_LOG="$STATE/log"
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
if grep -qx 'EXIT 0' <<<"$r" && grep -q '^PULLS .*nomic-embed-text' <<<"$r"; then
    pass "C stale pre-installed embed model is re-pulled and then verified, not trusted"
else
    bad "C stale pre-installed embed model: $(tr '\n' ';' <<<"$r")"
fi

r="$(scenario fresh good-nomic-embed-text good-qwen3.5)"
if grep -qx 'EXIT 0' <<<"$r" && ! grep -q '^PULLS .*nomic-embed-text' <<<"$r"; then
    pass "C control: a correct pre-installed embed model is verified and NOT re-pulled"
else
    bad "C control, correct pre-installed embed model: $(tr '\n' ';' <<<"$r")"
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAIL"; exit 1
