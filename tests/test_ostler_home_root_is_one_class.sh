#!/usr/bin/env bash
# ============================================================================
# THE SOURCE-STATE ROOT IS ONE ROOT ACROSS THE DOCTOR RESOLVER FAMILY (task #325)
#
# #325: "OSTLER_HOME carries two meanings in the same product." The Doctor's
# state/secret resolvers treat OSTLER_HOME as the ostler BASE root (an override
# for OSTLER_DIR); install.sh:24702 sets OSTLER_HOME="$HOME" for the ostler_fda
# email subprocess, where it means the USER HOME. Those two never collide today
# ONLY because OSTLER_HOME reaches the Doctor process by no route. This is the
# first place the ambiguity was measured reaching an artefact (GET /api/v1/sources
# reads _source_hydrate_dir), so this test is the durable guard for the CLASS,
# not for one resolver.
#
# WHAT IT PINS
#   A. CANNOT-DRIFT (source invariant). The three convention resolvers
#      -- extension_token.token_path, whatsapp_pair.state_path,
#      web_ui._source_hydrate_dir -- derive their root with BYTE-IDENTICAL code.
#      Their docstrings promise they "cannot drift onto different roots"; this
#      enforces the promise instead of trusting it.
#   B. NOT DARK (shipping env). Under the env a real install presents
#      (OSTLER_DIR=~/.ostler, OSTLER_HOME unset), the WRITER dir install.sh
#      writes (${OSTLER_DIR}/state/hydrate) equals the dir the READER
#      (_source_hydrate_dir) reads. The artefact is served from where it is written.
#   C. THE GUARD (what keeps B true). The com.ostler.doctor launchd plist must
#      NOT put OSTLER_HOME in EnvironmentVariables. That absence is the only
#      reason the OSTLER_HOME ambiguity cannot bite. The day a change adds it,
#      this goes red and names #325.
#   D. ANTI-VACUITY (the hazard is real). Under OSTLER_HOME="$HOME" the reader
#      DIVERGES from the writer. If it did not, guard C would be pointless and
#      this test blind.
#
# It does NOT change any resolver. The class-closing fix (one meaning for
# OSTLER_HOME, or OSTLER_DIR-only everywhere) is #325's deliberate scope.
#
# The real code is extracted (AST for the python resolvers, the real assignment
# line eval'd in bash for the writer), never reimplemented.
#
# Exit: 0 invariant holds | 1 broken | 2 CANNOT RUN
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HERE}/.."
INSTALL="${ROOT}/install.sh"
command -v python3 >/dev/null 2>&1 || { echo "CANNOT RUN: python3 not on PATH" >&2; exit 2; }
[ -r "$INSTALL" ] || { echo "CANNOT RUN: install.sh unreadable" >&2; exit 2; }

# ── WRITER: evaluate the REAL assignment line under a chosen env. ────────
# source only that one line so we run install.sh's actual expansion, not a copy.
_writer_hydrate_dir() { # $1=OSTLER_DIR value
    local line
    line="$(grep -m1 '^_HYDRATE_SENTINEL_DIR="' "$INSTALL")" || return 2
    OSTLER_DIR="$1" bash -c "${line}; printf '%s' \"\$_HYDRATE_SENTINEL_DIR\""
}

_w_line="$(grep -m1 '^_HYDRATE_SENTINEL_DIR="' "$INSTALL" || true)"
[ -n "$_w_line" ] || { echo "CANNOT RUN: writer line _HYDRATE_SENTINEL_DIR= not found in install.sh (moved/renamed)" >&2; exit 2; }

# ── The adjudication lives in python: AST-extract the resolvers, eval them,
#    and read the plist env keys out of install.sh. Print PASS/FAIL lines and
#    a final VERDICT the bash layer turns into an exit code. ───────────────
INSTALL="$INSTALL" ROOT="$ROOT" \
WRITER_SHIP="$(_writer_hydrate_dir "/tmp/hu/.ostler")" \
WRITER_HAZ="$(_writer_hydrate_dir "/tmp/hu/.ostler")" \
python3 <<'PY'
import ast, os, re, sys
from pathlib import Path

ROOT = Path(os.environ["ROOT"])
INSTALL = Path(os.environ["INSTALL"])
fails = []
passes = []
def ok(m): passes.append(m); print("  ok    " + m)
def bad(m): fails.append(m); print("  FAIL  " + m)
def cannot(m): print("CANNOT RUN: " + m, file=sys.stderr); sys.exit(2)

def extract_fn(relpath, fnname):
    src = (ROOT / relpath).read_text()
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == fnname:
            return ast.get_source_segment(src, node)
    return None

RESOLVERS = [
    ("vendor/doctor/agent/extension_token.py", "token_path"),
    ("vendor/doctor/agent/whatsapp_pair.py",   "state_path"),
    ("vendor/doctor/agent/web_ui.py",          "_source_hydrate_dir"),
]
segs = {}
for rel, fn in RESOLVERS:
    seg = extract_fn(rel, fn)
    if seg is None:
        cannot(f"{fn} not found in {rel}; the resolver family moved and every verdict below would be about the wrong code")
    segs[fn] = seg

# ── A. CANNOT-DRIFT: the root-derivation lines are byte-identical. ──────
def root_lines(seg):
    out = []
    for ln in seg.splitlines():
        s = ln.strip()
        if s.startswith("base =") or s.startswith("root ="):
            out.append(s)
    return tuple(out)
rl = {fn: root_lines(seg) for fn, seg in segs.items()}
# every convention resolver must carry the SAME two root lines
ref_fn = "_source_hydrate_dir"
ref = rl[ref_fn]
if not ref or len(ref) != 2:
    cannot(f"could not read the base/root derivation from {ref_fn}: {ref}")
drift = [fn for fn, v in rl.items() if v != ref]
if drift:
    bad(f"CANNOT-DRIFT BROKEN: these resolvers no longer share the root derivation of {ref_fn}: {drift}. "
        f"{ref_fn}={ref}  offenders={{ {', '.join(f'{d}:{rl[d]}' for d in drift)} }}. "
        "The docstrings promise they cannot drift onto different roots (#325).")
else:
    ok(f"cannot-drift: all {len(rl)} convention resolvers share the identical root derivation {ref}")

# Build a callable for the web_ui reader from its real source.
ns = {"os": os, "Path": Path}
exec(segs["_source_hydrate_dir"], ns)
reader = ns["_source_hydrate_dir"]

def reader_under(env):
    for k in ("OSTLER_HOME", "OSTLER_DIR"):
        os.environ.pop(k, None)
    os.environ.update(env)
    try:
        return str(reader())
    finally:
        for k in ("OSTLER_HOME", "OSTLER_DIR"):
            os.environ.pop(k, None)

# ── B. NOT DARK under the shipping env. ────────────────────────────────
writer_ship = os.environ["WRITER_SHIP"]                     # /tmp/hu/.ostler/state/hydrate
reader_ship = reader_under({"OSTLER_DIR": "/tmp/hu/.ostler"})  # OSTLER_HOME unset
if writer_ship == reader_ship:
    ok(f"not dark: writer and reader agree under the shipping env -> {reader_ship}")
else:
    bad(f"ARTEFACT DARK under the shipping env: writer wrote {writer_ship}, reader reads {reader_ship}")

# ── C. THE GUARD: OSTLER_HOME must NOT be a Doctor plist env key. ───────
# Extract the com.ostler.doctor plist heredoc from install.sh and read its
# EnvironmentVariables <key>s. If OSTLER_HOME appears there, the family breaks.
itxt = INSTALL.read_text()
m = re.search(r'DOCTOR_PLIST=.*?cat > "\$DOCTOR_PLIST" <<DOCEOF\n(.*?)\nDOCEOF', itxt, re.S)
if not m:
    cannot("could not extract the com.ostler.doctor plist heredoc from install.sh (anchor moved)")
plist = m.group(1)
# sanity: we grabbed the right plist
if "com.ostler.doctor" not in plist:
    cannot("extracted a heredoc that is not the com.ostler.doctor plist")
env_block = re.search(r'<key>EnvironmentVariables</key>\s*<dict>(.*?)</dict>', plist, re.S)
if not env_block:
    cannot("com.ostler.doctor plist has no EnvironmentVariables dict (structure changed)")
env_keys = re.findall(r'<key>([^<]+)</key>', env_block.group(1))
if "OSTLER_HOME" in env_keys:
    bad("GUARD FIRED (#325): the com.ostler.doctor plist now sets OSTLER_HOME in EnvironmentVariables. "
        "With OSTLER_HOME meaning $HOME (install.sh:24702) the source-status artefact goes dark. "
        f"env keys: {env_keys}")
else:
    ok(f"guard: OSTLER_HOME is not a com.ostler.doctor env key (the absence that keeps the family safe); {len(env_keys)} keys present")

# ── D. ANTI-VACUITY: the hazard is real (reader diverges when OSTLER_HOME set). ─
reader_haz = reader_under({"OSTLER_HOME": "/tmp/hu", "OSTLER_DIR": "/tmp/hu/.ostler"})
if reader_haz != writer_ship and reader_haz == "/tmp/hu/state/hydrate":
    ok(f"anti-vacuity: with OSTLER_HOME=$HOME the reader diverges to {reader_haz} vs writer {writer_ship} -- the #325 hazard this guards is demonstrably reachable")
else:
    bad(f"ANTI-VACUITY FAILED: OSTLER_HOME=$HOME did not produce the expected divergence (reader={reader_haz}). "
        "The guard in C would be pointless and this test blind.")

print()
print(f"{len(passes)} passed, {len(fails)} failed")
sys.exit(1 if fails else 0)
PY
