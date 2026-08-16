#!/usr/bin/env bash
#
# test_assistant_config_required_fields.sh
#
# Regression gate for the v1.0.31 launch blocker: `ostler-assistant daemon`
# would not boot on ANY fresh install, crash-looping on the LaunchAgent
# KeepAlive roughly every 10 seconds with:
#
#     Error: Failed to deserialize config file
#     Caused by:
#         TOML parse error at line 1, column 1
#           |
#         1 | schema_version = 2
#           | ^
#         missing field `backend`
#
# ROOT CAUSE, and it is a serde semantics trap worth stating plainly.
#
#   MemoryConfig.backend in zeroclaw-config/src/schema.rs is a plain
#   `pub backend: String` with NO #[serde(default)]. It has been required
#   since the crate was extracted on 2026-04-09; the daemon did not change.
#
#   The Config struct's `memory` FIELD does carry #[serde(default)]. That
#   default fires when the WHOLE [memory] TABLE is absent. It does NOT fire
#   for a field missing from a table that IS present.
#
#   install.sh wrote no [memory] section for months, so MemoryConfig::default()
#   supplied backend = "sqlite" and nobody learned it was mandatory. Commit
#   219ee4e (2026-08-14, the #677 fix that finally pointed memory at the
#   embedder) added a THREE-KEY [memory] block. The table became present and
#   partial, the default stopped applying, and the daemon stopped booting.
#
#   A partial table silently disarms the very default that was covering you.
#
# THE GATE. Renders the config.toml install.sh actually emits, parses it as
# real TOML, and asserts that every table carrying a known-required field
# carries that field. It pins the DEFECT -- a present-but-partial table -- not
# the spelling of any one line, so reformatting the emitter cannot make it go
# green while blind, and adding the key back in a different style cannot make
# it go red while fixed.
#
# Per feedback_check_the_shape_of_a_zero: it refuses to pass on an empty
# extraction, and it carries a NEGATIVE CONTROL that strips the key and
# requires the checker to go red. A gate that has never been observed failing
# is not known to be able to fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

pass=0
fail=0
ok()   { printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }

[ -f "$INSTALL_SH" ] || { echo "CANNOT-RUN: no install.sh at ${INSTALL_SH}" >&2; exit 2; }

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 for TOML parsing" >&2; exit 2; }
"$PY" -c 'import tomllib' 2>/dev/null || { echo "CANNOT-RUN: python3 lacks tomllib (needs 3.11+)" >&2; exit 2; }

# TABLE:FIELD pairs the daemon requires because the field has NO serde default.
#
# THE FIRST VERSION OF THIS LINE SAID ONLY "memory:backend", AND THAT WAS THE
# BUG IN THE GATE. It pinned the instance I had just watched fail instead of the
# class, so it passed over a config missing `auto_save` -- exactly the state that
# sat on main after the first fix and would have shipped a dead Hub again. A
# daemon that reports one missing field at a time will be fixed one field at a
# time unless the set is enumerated.
#
# DERIVED FROM THE SOURCE, NOT FROM THE ERROR MESSAGE. At the shipped daemon
# commit 723c682f, crates/zeroclaw-config/src/schema.rs, struct MemoryConfig:
#
#     pub field declarations        33
#     #[serde( attributes           31
#     fields with NO serde attr      2      backend, auto_save
#
# To re-derive after a daemon bump, take the struct body and list every
# `pub <name>:` with no `#[serde(` in the lines above it. Do NOT infer the set
# from which Default-impl entries look like literals: a bare `#[serde(default)]`
# uses the TYPE's Default, so `search_mode`, `policy`, `qdrant` and six others
# look literal in the impl and are nonetheless defaulted. That heuristic
# over-counts to 12 and would have us freeze ten daemon defaults into install.sh
# for no reason, which is the same silent-divergence trap that caused the
# original outage.
#
# Corroboration, independent of the source read: a live box logged 66 daemon
# restarts at 10s intervals, 56 x "missing field `backend`" then 10 x "missing
# field `auto_save`". Two distinct fields, matching the two derived here.
REQUIRED_PAIRS="memory:backend memory:auto_save"

# ---------------------------------------------------------------------------
# Render: pull the literal `echo "..."` lines install.sh emits into config.toml.
# We take the emitter block by its anchors rather than by line number so the
# gate survives edits elsewhere in a 20k-line script.
# ---------------------------------------------------------------------------
render_config() {
    awk '
        /echo "\[memory\]"/        { inblock = 1 }
        inblock && /echo "\[channels\]"/ { inblock = 0 }
        inblock {
            line = $0
            # keep only the literal payload of echo "..."
            if (match(line, /echo "/)) {
                rest = substr(line, RSTART + 6)
                sub(/"[[:space:]]*$/, "", rest)
                gsub(/\\"/, "\"", rest)
                print rest
            }
        }
    ' "$INSTALL_SH"
}

RENDERED="$(render_config)"

# A silently-empty extraction must never read as a clean parse.
if [ -z "${RENDERED//[[:space:]]/}" ]; then
    echo "CANNOT-RUN: rendered no [memory] block from install.sh; the anchors moved" >&2
    exit 2
fi
ok "extraction is non-empty ($(printf '%s\n' "$RENDERED" | grep -c .) line(s))"

# The rendered block still carries shell ${VAR:-default} forms. Neutralise them
# to a literal so the TOML parses; the gate is about KEY PRESENCE, not values.
neutralise() { sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}/PLACEHOLDER/g'; }

# The checker script lives in a temp FILE, not on stdin.
#
# It was originally `python3 - "$ARGS" <<'PYEOF'`, which hands the SCRIPT to the
# interpreter on stdin. sys.stdin.buffer.read() then returned empty, tomllib
# parsed an empty document, no tables were present, nothing was missing, and the
# gate reported green on every input including ones with the field deleted. The
# negative control below is the only reason that was caught, on the first run.
CHECKER="$(mktemp -t cfgcheck.XXXXXX.py)"
trap 'rm -f "$CHECKER" /tmp/cfgcheck.err' EXIT
cat > "$CHECKER" <<'PYEOF'
import sys, tomllib
pairs = sys.argv[1].split()
raw = sys.stdin.buffer.read()
if not raw.strip():
    print("checker received an EMPTY document; refusing to call that clean", file=sys.stderr)
    sys.exit(3)
try:
    data = tomllib.loads(raw.decode("utf-8"))
except Exception as exc:                       # noqa: BLE001
    print(f"TOML did not parse: {exc}", file=sys.stderr)
    sys.exit(3)
missing = []
for pair in pairs:
    table, field = pair.split(":", 1)
    if table in data and field not in data[table]:
        missing.append(f"[{table}] is present but has no `{field}`")
if missing:
    for m in missing:
        print(m, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYEOF

check_pairs() {
    # stdin: a TOML document. Returns 0 if every REQUIRED_PAIRS key is present.
    "$PY" "$CHECKER" "$REQUIRED_PAIRS"
}

# ---------------------------------------------------------------------------
# THE ASSERTION
# ---------------------------------------------------------------------------
if printf '%s\n' "$RENDERED" | neutralise | check_pairs 2>/tmp/cfgcheck.err; then
    ok "every required field is present in the emitted config"
else
    rc=$?
    if [ "$rc" = "3" ]; then
        bad "emitted config is not valid TOML: $(cat /tmp/cfgcheck.err)"
    else
        bad "emitted config is missing a required field: $(cat /tmp/cfgcheck.err)"
    fi
fi

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL. Strip `backend` and require the checker to go RED. Without
# this the assertion above could be passing because the checker cannot fail.
# ---------------------------------------------------------------------------
if printf '%s\n' "$RENDERED" | grep -v '^backend' | neutralise | check_pairs 2>/dev/null; then
    bad "NEGATIVE CONTROL DID NOT FIRE: checker passed a config with no backend"
else
    ok "negative control: checker goes red when backend is removed"
fi

# A second control in the other direction: an unrelated table must not trip it.
if printf 'schema_version = 2\n[providers]\nfallback = "ollama"\n' | check_pairs 2>/dev/null; then
    ok "control: a config with no [memory] table at all is accepted (serde default applies)"
else
    bad "false positive: absent [memory] table should be fine, the field default covers it"
fi

echo
echo "== results: ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
