#!/usr/bin/env bash
#
# tests/test_owner_language_from_installer.sh (NEW-119)
#
# The installer language the customer picked (OSTLER_LANG, from the GUI) must
# reach the assistant's `owner_language` config key, so the first morning
# brief (a cron agent job with no incoming message) is written in that
# language. Without it the daemon falls back to the language of the owner's
# sent messages, of which there are none on day one, then English.
#
# Consumer: ostler-assistant crates/zeroclaw-runtime/src/agent/language.rs
#   owner_language_note_for_config reads Config.owner_language (top-level key,
#   crates/zeroclaw-config/src/schema.rs `pub owner_language`), Lang::parse
#   takes the head of the code ("zh-Hant" -> zh), and English yields no note.
#
# This test RUNS the real emitter lines of install.sh (the TOML preamble and
# the customer-identity block of the `{ ... } > "$ASSISTANT_CONFIG"` body),
# parses the result as TOML, and resolves it with a port of Lang::parse.
# Set NEW119_CFG_OUT=<dir> to keep the rendered files (used to feed the real
# daemon Config type in a consumer-side check).

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# The emitter body from the TOML preamble down to the providers block.
awk '
    /^    cat <<.TOMLPREAMBLE.$/ { on = 1 }
    /^    # ── Providers: Ollama fallback/ { if (on) exit }
    on { print }
' "$INSTALL_SCRIPT" > "${WORK}/emit.sh"
if ! grep -q 'user_assistant_name' "${WORK}/emit.sh"; then
    echo "FAIL [extract]: could not locate the config.toml identity emitter in install.sh" >&2
    exit 1
fi

render() {  # $1 = case name, $2 = OSTLER_LANG value or __UNSET__
    local out="${WORK}/${1}.toml"
    if [[ "$2" == "__UNSET__" ]]; then
        env -u OSTLER_LANG USER_FIRST_NAME=Sam ASSISTANT_NAME=Ada /bin/bash -euo pipefail "${WORK}/emit.sh" > "$out"
    else
        env OSTLER_LANG="$2" USER_FIRST_NAME=Sam ASSISTANT_NAME=Ada /bin/bash -euo pipefail "${WORK}/emit.sh" > "$out"
    fi
}
render ja ja
render default __UNSET__
render en-GB en-GB
render zh-Hant zh-Hant
render pt-BR pt-BR
render injected 'ja"
[gateway]
port = 1'

if [[ -n "${NEW119_CFG_OUT:-}" ]]; then mkdir -p "$NEW119_CFG_OUT"; cp "${WORK}"/*.toml "$NEW119_CFG_OUT"/; fi

python3 -I - "$WORK" <<'PY'
import sys, tomllib, pathlib
work = pathlib.Path(sys.argv[1])
# Port of ostler-assistant language.rs Lang::parse + owner_language_note (codes and names).
LANGS = [("en","English"),("fr","French"),("de","German"),("es","Spanish"),("it","Italian"),
         ("pt","Portuguese"),("nl","Dutch"),("ja","Japanese"),("zh","Chinese"),("ko","Korean"),
         ("ru","Russian"),("ar","Arabic"),("he","Hebrew"),("hi","Hindi"),("th","Thai"),("el","Greek")]
def parse(s):
    v = s.strip().lower().replace("_", "-"); head = v.split("-")[0]
    for code, name in LANGS:
        if head == code or head == name.lower() or v == name.lower():
            return code, name
    return None
def brief_language(cfg):
    got = parse(cfg["owner_language"]) if isinstance(cfg.get("owner_language"), str) else None
    return got[1] if got else "English (no owner_language)"
want = {"ja": ("ja", "Japanese"), "default": ("en-GB", "English"), "en-GB": ("en-GB", "English"),
        "zh-Hant": ("zh-Hant", "Chinese"), "pt-BR": ("pt-BR", "Portuguese"), "injected": ("en-GB", "English")}
bad = 0
for case, (val, lang) in want.items():
    cfg = tomllib.loads((work / f"{case}.toml").read_text())
    got_val = cfg.get("owner_language"); got_lang = brief_language(cfg)
    ok = got_val == val and got_lang == lang and "gateway" not in cfg
    print(f"{'PASS' if ok else 'FAIL'} [{case}]: owner_language={got_val!r} -> first brief in {got_lang} (want {val!r} -> {lang})")
    bad += not ok
sys.exit(1 if bad else 0)
PY
echo "PASS: installer language reaches owner_language; default en-GB; unsafe value refused"
