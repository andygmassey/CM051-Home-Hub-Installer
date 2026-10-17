#!/usr/bin/env bash
# scripts/candidate_manifest_row.sh <version> --id ID --title T --source-pr P
#                                   (--grep-installer PATTERN | --absent-installer PATTERN)
#                                   [--why TEXT] [--dry-run]
# ============================================================================
# STEP (d): add a cut-manifest entry for a fix that is visible in install.sh.
#
# The entry is a grep_in_installer proof. It is inserted at the end of the
# `entries:` list in cut-manifests/<version>.yaml, before `open_issues:`, as
# text, so every comment in the file survives.
#
# Refuses on: a manifest that does not exist or does not parse; an id that is
# not kebab-case or already exists (the same id with the same proof is a no-op,
# the same id with a different proof is a refusal); a pattern that is not a
# valid ERE; and a pattern whose match count in install.sh contradicts the
# entry (present must match at least once, absent must match none) -- a
# fingerprint that cannot pass today would only fail the cut later.
#
# It writes proofs of the grep_in_installer shape only. Other proof kinds name
# artefacts or probes that need a person's judgement; add those by hand.
#
# Exit: 0 done / already done, 1 refused, 2 CANNOT-RUN.
# ============================================================================
set -uo pipefail
CAND_ROOT="${CANDIDATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=scripts/candidate_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/candidate_lib.sh"

VER=""; ID=""; TITLE=""; PR=""; PAT=""; MUST="true"; WHY=""
while [ $# -gt 0 ]; do
	case "$1" in
		--id) ID="${2:-}"; shift 2 ;;
		--title) TITLE="${2:-}"; shift 2 ;;
		--source-pr) PR="${2:-}"; shift 2 ;;
		--why) WHY="${2:-}"; shift 2 ;;
		--grep-installer) PAT="${2:-}"; MUST="true"; shift 2 ;;
		--absent-installer) PAT="${2:-}"; MUST="false"; shift 2 ;;
		--dry-run) CAND_DRY=1; shift ;;
		-h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) cand_cannot "unknown argument: $1" ;;
		*) VER="$1"; shift ;;
	esac
done
[ -n "$VER" ] && [ -n "$ID" ] && [ -n "$TITLE" ] && [ -n "$PAT" ] || cand_cannot "need <version>, --id, --title and --grep-installer/--absent-installer"
[[ "$ID" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || cand_refuse "id '$ID' is not kebab-case."

MAN="${CANDIDATE_MANIFEST:-$CAND_ROOT/cut-manifests/$VER.yaml}"
INSTALL_SH="${OSTLER_INSTALL_SH:-$CAND_ROOT/install.sh}"
[ -f "$MAN" ] || cand_cannot "no cut manifest at $MAN (open the cut first with scripts/new_cut.sh)"
[ -f "$INSTALL_SH" ] || cand_cannot "no install.sh at $INSTALL_SH"

rc=0; printf '' | grep -E -- "$PAT" >/dev/null 2>&1 || rc=$?
[ "$rc" -le 1 ] || cand_refuse "pattern is not a valid extended regex: $PAT"
hits="$(grep -cE -- "$PAT" "$INSTALL_SH" || true)"
if [ "$MUST" = "true" ] && [ "$hits" -lt 1 ]; then cand_refuse "pattern matches 0 lines of install.sh, so the entry would fail the cut: $PAT"; fi
if [ "$MUST" = "false" ] && [ "$hits" -gt 0 ]; then cand_refuse "absence entry, but the pattern matches $hits line(s) of install.sh: $PAT"; fi

python3 -I - "$MAN" "$CAND_TMP/new.yaml" "$ID" "$TITLE" "$PR" "$PAT" "$MUST" "$WHY" <<'PY'
import sys, yaml
man, out, id_, title, pr, pat, must, why = sys.argv[1:9]
text = open(man).read()
try:
    doc = yaml.safe_load(text)
except Exception as e:
    print("REFUSED: %s does not parse as YAML: %s" % (man, e), file=sys.stderr); sys.exit(1)
entries = doc.get("entries") if isinstance(doc, dict) else None
if not isinstance(entries, list):
    print("REFUSED: %s has no entries: list" % man, file=sys.stderr); sys.exit(1)
want = {"kind": "grep_in_installer", "pattern": pat}
if must == "false":
    want["must_match"] = False
for e in entries:
    if e.get("id") == id_:
        same = {k: v for k, v in (e.get("proof") or {}).items()} == want
        if same:
            print("ALREADY"); sys.exit(0)
        print("REFUSED: entry '%s' already exists with a different proof" % id_, file=sys.stderr); sys.exit(1)
def q(s): return "'" + s.replace("'", "''") + "'"
lines = ["  - id: " + id_, "    title: " + q(title)]
if pr: lines.append("    source_pr: " + q(pr))
if why:
    lines.append("    why: |")
    lines += ["      " + l for l in why.splitlines()]
lines += ["    proof:", "      kind: grep_in_installer", "      pattern: " + q(pat)]
if must == "false": lines.append("      must_match: false")
block = "\n".join(lines) + "\n"
marker = "\nopen_issues:"
i = text.find(marker)
if i < 0:
    print("REFUSED: %s has no open_issues: key to insert before" % man, file=sys.stderr); sys.exit(1)
head = text[:i].rstrip("\n") + "\n" + block
new = head + text[i:]
try:
    d2 = yaml.safe_load(new)
except Exception as e:
    print("REFUSED: the insertion would break the YAML: %s" % e, file=sys.stderr); sys.exit(1)
assert len(d2["entries"]) == len(entries) + 1 and d2["entries"][-1]["id"] == id_
open(out, "w").write(new)
print("ADD")
PY
r=$?
[ "$r" -eq 0 ] || exit "$r"
if [ ! -f "$CAND_TMP/new.yaml" ]; then cand_say "[manifest] '$ID' already in $VER with the same proof -- nothing to do"; exit 0; fi
cand_say "[manifest] adding '$ID' to $VER"
cand_apply "$MAN" "$CAND_TMP/new.yaml"
exit 0
