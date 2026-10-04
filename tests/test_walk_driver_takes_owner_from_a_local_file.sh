#!/usr/bin/env bash
# The walk's owner identity comes from an operator-local file, never from this
# repo, and never reaches the Q&A record. Without the file the walk installs a
# synthetic owner and SAYS so, so the owner-in-People probe reads CANNOT-RUN.
#
# Measured 2026-10-04: walks installed with the cast owner over a box holding a
# real person's data, so owner exclusion could never fire and probe (c) passed
# or failed on a guess. All values below are synthetic.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
run_py() {  # $1 = HOME for walk_drive
    HOME="$1" python3 - "$PWD/scripts" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wd", sys.argv[1] + "/walk_drive.py")
wd = importlib.util.module_from_spec(spec); spec.loader.exec_module(wd)
src = wd.record_owner_source()
name = wd.resolve("@owner_name"); allowed = wd.resolve("@owner_allowed")
table = dict(wd.build_table())
print(src); print(name); print(allowed)
print(table.get("Full name"), table.get("Allowed contacts"))
print(wd.shown_for("Full name", name, True))
print(wd.shown_for("Allowed contacts", allowed, True))
print(open(wd.OWNER_SOURCE_FILE).read().strip())
PY
}
mkdir -p "$T/none" "$T/with"
A=(); while IFS= read -r l; do A+=("$l"); done < <(run_py "$T/none")
[ "${A[0]:-}" = synthetic ] && [ "${A[6]:-}" = synthetic ] && ok "no owner file: the walk records a SYNTHETIC owner" || bad "no owner file recorded '${A[0]:-}'/'${A[6]:-}'"
[ "${A[1]:-}" = "Sam Doe" ] && [ "${A[2]:-}" = "+447700900000" ] && ok "no owner file: the cast name and the fictional number are answered" || bad "no owner file answered '${A[1]:-}' / '${A[2]:-}'"
[ "${A[3]:-}" = "@owner_name @owner_allowed" ] && ok "the table carries tokens, not identity values" || bad "table carries '${A[3]:-}'"

printf 'OWNER_NAME="Jane Doe"\nOWNER_EMAIL=jane.doe@example.com\nOWNER_PHONE=+447700900123\n' > "$T/with/.walk-owner.env"
B=(); while IFS= read -r l; do B+=("$l"); done < <(run_py "$T/with")
[ "${B[0]:-}" = configured ] && [ "${B[6]:-}" = configured ] && ok "with an owner file: the walk records a CONFIGURED owner" || bad "with file recorded '${B[0]:-}'/'${B[6]:-}'"
[ "${B[1]:-}" = "Jane Doe" ] && [ "${B[2]:-}" = "+447700900123,jane.doe@example.com" ] && ok "with an owner file: name and phone,email come from it" || bad "with file answered '${B[1]:-}' / '${B[2]:-}'"
[ "${B[4]:-}" = "<OWNER IDENTITY WITHHELD>" ] && [ "${B[5]:-}" = "<OWNER IDENTITY WITHHELD>" ] && ok "the owner's answers are withheld from the Q&A record" || bad "recorded '${B[4]:-}' / '${B[5]:-}'"

# ttywalk streams the local file over ssh stdin (never argv), defaults to
# ~/walkdriver/owner_identity.env, and removes a stale one when it is absent.
grep -q 'OWNER_FILE_LOCAL="${OSTLER_WALK_OWNER_FILE:-$HOME/walkdriver/owner_identity.env}"' scripts/ttywalk.sh \
  && grep -q '< "$OWNER_FILE_LOCAL"' scripts/ttywalk.sh && grep -q 'rm -f ~/.walk-owner.env' scripts/ttywalk.sh \
  && ok "ttywalk stages the driver-local file over stdin and clears a stale one" || bad "ttywalk owner staging block is missing or passes the file another way"
git check-ignore -q "$HOME/walkdriver/owner_identity.env" 2>/dev/null; case "$HOME/walkdriver" in "$PWD"*) bad "the owner file path is inside the repo";; *) ok "the owner file lives outside the repo (cannot be committed)";; esac

[ "$FAIL" = 0 ] && echo "PASS: the walk owner comes from a local file, is withheld, and synthetic is declared" || { echo FAIL; exit 1; }
