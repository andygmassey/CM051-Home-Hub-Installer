#!/usr/bin/env bash
# tests/test_candidate_scripts.sh -- the scripts/candidate*.sh steps against synthetic fixtures.
# Every step gets a happy path, an idempotent re-run, and at least one REFUSAL, and
# each refusal asserts the exit code AND a fragment of the words, so a script that
# refuses for the wrong reason (or crashes) does not pass. No network: gh and the
# registry are stubs (CANDIDATE_GH, CANDIDATE_REGISTRY_CMD). No real data.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$HERE/scripts"
W="$(mktemp -d "${TMPDIR:-/tmp}/cand-test.XXXXXX")"; trap 'rm -rf "${W:?}"' EXIT
command -v jq >/dev/null 2>&1 || { echo "CANNOT-RUN: jq is required" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/    /' | head -12; }

# expect <name> <rc> <fragment|-> -- cmd...
expect() {
	local name="$1" rc="$2" frag="$3"; shift 4
	local out; out="$("$@" 2>&1)"; local got=$?
	if [ "$got" -ne "$rc" ]; then bad "$name: exit $got, wanted $rc" "$out"; return; fi
	if [ "$frag" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$frag"; then bad "$name: output lacks '$frag'" "$out"; return; fi
	ok
}
has() { # has <name> <file> <fixed string> <wanted count>
	local n; n="$(grep -cF -- "$3" "$2" || true)"
	[ "$n" -eq "$4" ] && ok || bad "$1: '$3' appears $n time(s) in ${2#"$W"/}, wanted $4"
}

SITE_OLD="sha256:$(printf 'a%.0s' $(seq 64))"; COMP_OLD="sha256:$(printf 'b%.0s' $(seq 64))"
SITE_NEW="sha256:$(printf 'c%.0s' $(seq 64))"; COMP_NEW="sha256:$(printf 'd%.0s' $(seq 64))"
CM044_SHA="$(printf '1%.0s' $(seq 40))"; OLD_SHA="$(printf '2%.0s' $(seq 40))"

# --- stubs ---------------------------------------------------------------
cat > "$W/gh" <<'STUB'
#!/usr/bin/env bash
# args: api <path> [--jq .sha]
p="$2"
case "$p" in
	repos/owner/wiki/commits/v0.1.43) echo "$STUB_CM044_SHA" ;;
	repos/owner/hub/commits/hub-v0.5.2) echo "$(printf '3%.0s' $(seq 40))" ;;
	repos/owner/src/commits/new) echo "$STUB_NEW_SHA" ;;
	repos/owner/src/compare/*) cat "$STUB_COMPARE" ;;
	*) echo "stub: no answer for $p" >&2; exit 1 ;;
esac
STUB
cat > "$W/reg" <<'STUB'
#!/usr/bin/env bash
case "$1:$2" in
	*ostler-wiki-site:0.1.43) echo "$STUB_SITE" ;;
	*ostler-wiki-compiler:0.1.43) echo "$STUB_COMP" ;;
	*) exit 1 ;;
esac
STUB
chmod +x "$W/gh" "$W/reg"
export CANDIDATE_GH="$W/gh" CANDIDATE_REGISTRY_CMD="$W/reg" STUB_CM044_SHA="$CM044_SHA" STUB_SITE="$SITE_NEW" STUB_COMP="$COMP_NEW"
export CANDIDATE_CM044_REPO=owner/wiki

mkroot() { # fresh fixture tree in $W/root
	rm -rf "${W:?}/root"; mkdir -p "$W/root/scripts" "$W/root/gui" "$W/root/cuts/v9.9.9" "$W/root/cut-manifests" "$W/root/vendor/divergences"
	cp "$S"/candidate*.sh "$W/root/scripts/"; cp "$S/candidate_sources.tsv" "$W/root/scripts/"
	cat > "$W/root/install.sh" <<IN
services:
  wiki-site:
    image: ghcr.io/org/ostler-wiki-site@$SITE_OLD
  wiki-compiler:
    image: ghcr.io/org/ostler-wiki-compiler@$COMP_OLD
# fingerprint line for the manifest tests
echo "synthetic marker v1"
IN
	printf 'wiki-compiler\t%s\t%s\nwiki-site\t%s\t%s\n' "$COMP_OLD" "$OLD_SHA" "$SITE_OLD" "$OLD_SHA" > "$W/root/scripts/wiki_image_provenance.tsv"
	printf 'DAEMON_VERSION       ?= 0.5.1\nHUB_APP_REPO         ?= owner/hub\n' > "$W/root/gui/Makefile"
	printf 'CUT_VERSION=9.9.9\nDAEMON_COMMIT=aaaaaaaa\nCM051=bbbbbbbb\n# comment kept\n' > "$W/root/cuts/v9.9.9/cut.env"
	printf 'version: v9.9.9\ndescription: |\n  synthetic\n# a comment that must survive\nentries:\n  - id: existing-row\n    title: x\n    proof:\n      kind: box_walk_probe\n      probe: p\n\nopen_issues:\n  - issue: 1\n' > "$W/root/cut-manifests/v9.9.9.yaml"
	export CANDIDATE_ROOT="$W/root"
}
R() { bash "$W/root/scripts/$1" "${@:2}"; }

# ======================= candidate_repin_wiki.sh =======================
mkroot
expect "wiki dry-run shows the diff and writes nothing" 0 "+wiki-site" -- R candidate_repin_wiki.sh --tag 0.1.43 --dry-run
has "wiki dry-run left install.sh alone" "$W/root/install.sh" "$SITE_OLD" 1
expect "wiki real run" 0 "written and read back" -- R candidate_repin_wiki.sh --tag 0.1.43
has "wiki new site digest in install.sh" "$W/root/install.sh" "$SITE_NEW" 1
has "wiki new compiler digest in install.sh" "$W/root/install.sh" "$COMP_NEW" 1
has "wiki old digest gone" "$W/root/install.sh" "$COMP_OLD" 0
has "wiki provenance rows carry the API-resolved commit" "$W/root/scripts/wiki_image_provenance.tsv" "$CM044_SHA" 2
expect "wiki re-run is a no-op" 0 "nothing to do" -- R candidate_repin_wiki.sh --tag 0.1.43
has "wiki re-run did not duplicate rows" "$W/root/scripts/wiki_image_provenance.tsv" "$CM044_SHA" 2
mkroot; export STUB_COMP="$SITE_NEW"
expect "wiki refuses identical site and compiler digests" 1 "same digest" -- R candidate_repin_wiki.sh --tag 0.1.43
export STUB_COMP="$COMP_NEW"
expect "wiki refuses a tag the registry does not have" 1 "no manifest for" -- R candidate_repin_wiki.sh --tag 0.9.9
expect "wiki refuses a malformed tag" 1 "bare version" -- R candidate_repin_wiki.sh --tag v0.1.43
expect "wiki refuses a tag CM044 cannot resolve" 1 "could not resolve" -- env CANDIDATE_CM044_REPO=owner/nope bash "$W/root/scripts/candidate_repin_wiki.sh" --tag 0.1.43
mkroot; printf 'wiki-compiler\t%s\t%s\n' "$COMP_NEW" "$OLD_SHA" >> "$W/root/scripts/wiki_image_provenance.tsv"
expect "wiki refuses a digest already bound to another commit" 1 "DIFFERENT CM044 commit" -- R candidate_repin_wiki.sh --tag 0.1.43
mkroot; sed -i.bak "s#ostler-wiki-site@$SITE_OLD#ostler-wiki-site@$SITE_NEW#" "$W/root/install.sh"
expect "wiki refuses a half-applied tree" 1 "half-applied" -- R candidate_repin_wiki.sh --tag 0.1.43

# ======================= candidate_repin_hub.sh =======================
mkroot
expect "hub refuses a version older than the pin" 1 "OLDER" -- R candidate_repin_hub.sh --version 0.4.0
expect "hub refuses a tag the API cannot resolve" 1 "could not resolve" -- R candidate_repin_hub.sh --version 0.5.9
sed -i.bak '/^DAEMON_COMMIT/d' "$W/root/cuts/v9.9.9/cut.env"
expect "hub refuses a cut.env with no DAEMON_COMMIT" 1 "exactly one DAEMON_COMMIT" -- R candidate_repin_hub.sh --version 0.5.1 --cut v9.9.9
mkroot; printf 'DAEMON_VERSION       ?= 0.5.2\nHUB_APP_REPO         ?= owner/hub\n' > "$W/root/gui/Makefile"
expect "hub dry-run (version already pinned) shows the cut.env change" 0 "+DAEMON_COMMIT=33333333" -- R candidate_repin_hub.sh --version 0.5.2 --cut v9.9.9 --dry-run
has "hub dry-run left cut.env alone" "$W/root/cuts/v9.9.9/cut.env" "DAEMON_COMMIT=aaaaaaaa" 1
expect "hub real run writes DAEMON_COMMIT from the API" 0 - -- R candidate_repin_hub.sh --version 0.5.2 --cut v9.9.9
has "hub cut.env commit" "$W/root/cuts/v9.9.9/cut.env" "DAEMON_COMMIT=33333333" 1
has "hub cut.env other lines kept" "$W/root/cuts/v9.9.9/cut.env" "# comment kept" 1
expect "hub re-run is a no-op" 0 "already 33333333" -- R candidate_repin_hub.sh --version 0.5.2 --cut v9.9.9

# ======================= candidate_manifest_row.sh =======================
mkroot
expect "manifest dry-run" 0 "adding 'wiki-marker'" -- R candidate_manifest_row.sh v9.9.9 --id wiki-marker --title "A fix" --source-pr "owner/repo#1" --grep-installer 'synthetic marker v[0-9]' --dry-run
has "manifest dry-run wrote nothing" "$W/root/cut-manifests/v9.9.9.yaml" "wiki-marker" 0
expect "manifest add" 0 - -- R candidate_manifest_row.sh v9.9.9 --id wiki-marker --title "A fix" --source-pr "owner/repo#1" --grep-installer 'synthetic marker v[0-9]'
has "manifest entry present" "$W/root/cut-manifests/v9.9.9.yaml" "id: wiki-marker" 1
has "manifest comment survived" "$W/root/cut-manifests/v9.9.9.yaml" "# a comment that must survive" 1
expect "manifest result still parses with the entry last" 0 "wiki-marker 2" -- python3 -I -c "import yaml; d=yaml.safe_load(open('$W/root/cut-manifests/v9.9.9.yaml')); print(d['entries'][-1]['id'], len(d['entries']))"
expect "manifest re-run is a no-op" 0 "nothing to do" -- R candidate_manifest_row.sh v9.9.9 --id wiki-marker --title "A fix" --source-pr "owner/repo#1" --grep-installer 'synthetic marker v[0-9]'
expect "manifest refuses the same id with another proof" 1 "different proof" -- R candidate_manifest_row.sh v9.9.9 --id wiki-marker --title "A fix" --grep-installer 'synthetic'
expect "manifest refuses a pattern that matches nothing" 1 "matches 0 lines" -- R candidate_manifest_row.sh v9.9.9 --id other-row --title t --grep-installer 'no such line anywhere'
expect "manifest refuses an absence entry that matches" 1 "absence entry" -- R candidate_manifest_row.sh v9.9.9 --id gone-row --title t --absent-installer 'synthetic marker'
expect "manifest refuses an invalid regex" 1 "not a valid extended regex" -- R candidate_manifest_row.sh v9.9.9 --id bad-re --title t --grep-installer 'a(b'
expect "manifest refuses a non-kebab id" 1 "kebab-case" -- R candidate_manifest_row.sh v9.9.9 --id Bad_Id --title t --grep-installer synthetic
expect "manifest cannot run without a manifest" 2 "no cut manifest" -- R candidate_manifest_row.sh v8.8.8 --id some-row --title t --grep-installer synthetic

# ======================= candidate_pin.sh and candidate_freeze.sh (real git) =======================
mkroot; cd "$W/root" || exit 2
git init -q . && git config user.email t@example.invalid && git config user.name t
git add -A && git commit -qm base && printf '# edit\n' >> install.sh && git commit -qam "change install.sh"
INS8="$(git log -1 --format=%H -- install.sh | cut -c1-8)"
expect "pin dry-run names the install.sh commit" 0 "CM051 bbbbbbbb -> $INS8" -- R candidate_pin.sh v9.9.9 --dry-run
expect "pin real run" 0 - -- R candidate_pin.sh v9.9.9
has "pin written" cuts/v9.9.9/cut.env "CM051=$INS8" 1
git commit -qam pin
expect "pin re-run is a no-op" 0 "already pinned" -- R candidate_pin.sh v9.9.9
printf '# dirty\n' >> install.sh
expect "pin refuses an uncommitted install.sh" 1 "uncommitted" -- R candidate_pin.sh v9.9.9
git checkout -q install.sh
echo CM051=x >> cuts/v9.9.9/cut.env
expect "pin refuses a cut.env with two CM051 lines" 1 "exactly one CM051" -- R candidate_pin.sh v9.9.9
git checkout -q cuts/v9.9.9/cut.env
printf 'x\n' > untracked.txt
expect "freeze refuses a dirty tree" 1 "dirty" -- R candidate_freeze.sh v9.9.9
rm untracked.txt
expect "freeze reports the branch and the dispatch command" 0 "gh workflow run cut.yml --ref cut/v9.9.9" -- R candidate_freeze.sh v9.9.9 --dry-run
expect "freeze refuses --dispatch without --push" 1 "needs --push" -- R candidate_freeze.sh v9.9.9 --dispatch
git branch cut/v9.9.9 HEAD~1
expect "freeze refuses to move a frozen branch" 1 "not moved" -- R candidate_freeze.sh v9.9.9
git branch -q -D cut/v9.9.9
printf '# newer\n' >> install.sh && git commit -qam "newer install.sh"
expect "freeze refuses a pin whose install.sh is not HEAD's" 1 "NOT the one at HEAD" -- R candidate_freeze.sh v9.9.9
expect "freeze refuses a bad version" 1 "version must look like" -- R candidate_freeze.sh 9.9.9
cd "$HERE" || exit 2

# ======================= candidate_vendor.sh =======================
mkroot
SRC="$W/src"; git init -q "$SRC" && git -C "$SRC" config user.email t@example.invalid && git -C "$SRC" config user.name t
mkdir -p "$SRC/pkg"; echo a > "$SRC/pkg/a.py"; git -C "$SRC" add -A; git -C "$SRC" commit -qm one
P_SHA="$(git -C "$SRC" rev-parse HEAD)"; echo b > "$SRC/pkg/b.py"; git -C "$SRC" add -A; git -C "$SRC" commit -qm two
N_SHA="$(git -C "$SRC" rev-parse HEAD)"
printf '# placeholder\tslug\nSRC\towner/src\n' > "$W/root/scripts/candidate_sources.tsv"
touch "$W/root/vendor/divergences/t_pkg.patch"
vm() { # vm [extra tree lines...]
	{ printf '[[tree]]\nname             = "t/pkg"\nvendor_path      = "vendor/t/pkg"\nsource_repo      = "$SRC"\nsource_path      = "pkg"\npinned_sha = "%s"\ndivergence_patch = "vendor/divergences/t_pkg.patch"\nverify = "full"\n' "$P_SHA"; for l in "$@"; do printf '%s\n' "$l"; done; } > "$W/root/vendor/VENDOR_MANIFEST.toml"
}
vm
export STUB_NEW_SHA="$N_SHA" STUB_COMPARE="$W/compare.json"
echo '{"status":"ahead","files":[{"filename":"pkg/b.py"},{"filename":"elsewhere/x.py"}]}' > "$W/compare.json"
expect "vendor dry-run lists only files under the tree" 0 "(1 file(s) under pkg)" -- R candidate_vendor.sh t/pkg --to new --dry-run
expect "vendor dry-run names the sync command" 0 "would run: scripts/sync_vendor.sh t/pkg --to-sha $N_SHA" -- R candidate_vendor.sh t/pkg --to new --dry-run
printf '#!/usr/bin/env bash\necho "SYNCED $*" > "%s/synced"\n' "$W" > "$W/sync_stub.sh"
expect "vendor real run hands the resolved sha to sync_vendor.sh" 0 - -- env SRC="$SRC" CANDIDATE_SYNC_VENDOR="$W/sync_stub.sh" bash "$W/root/scripts/candidate_vendor.sh" t/pkg --to new
has "vendor sync got the full API-resolved sha" "$W/synced" "--to-sha $N_SHA" 1
expect "vendor refuses a source checkout that lacks the sha" 1 "does not contain" -- env SRC="$W/root" CANDIDATE_SYNC_VENDOR="$W/sync_stub.sh" bash "$W/root/scripts/candidate_vendor.sh" t/pkg --to new
expect "vendor cannot run without the source checkout variable" 2 "set \$SRC" -- env -u SRC CANDIDATE_SYNC_VENDOR="$W/sync_stub.sh" bash "$W/root/scripts/candidate_vendor.sh" t/pkg --to new
expect "vendor refuses an unknown tree" 1 "not in" -- R candidate_vendor.sh t/nope --to new
echo '{"status":"behind","files":[]}' > "$W/compare.json"
expect "vendor refuses a target that is not ahead" 1 "not ahead" -- R candidate_vendor.sh t/pkg --to new
echo '{"status":"ahead","files":[{"filename":"elsewhere/x.py"}]}' > "$W/compare.json"
expect "vendor refuses a change outside the tree" 1 "nothing to graft" -- R candidate_vendor.sh t/pkg --to new
expect "vendor is a no-op when already pinned" 0 "nothing to do" -- env STUB_NEW_SHA="$P_SHA" bash "$W/root/scripts/candidate_vendor.sh" t/pkg --to new
vm 'regenerate_forbidden = true'
expect "vendor refuses a regenerate_forbidden tree" 1 "regenerate_forbidden" -- R candidate_vendor.sh t/pkg --to new
vm; sed -i.bak 's/verify = "full"/verify = "skip"/' "$W/root/vendor/VENDOR_MANIFEST.toml"
expect "vendor refuses a verify = skip tree" 1 "verify = \"skip\"" -- R candidate_vendor.sh t/pkg --to new
vm; sed -i.bak '/divergence_patch/d' "$W/root/vendor/VENDOR_MANIFEST.toml"
expect "vendor refuses a tree with no divergence record" 1 "records no divergence" -- R candidate_vendor.sh t/pkg --to new
vm; printf '# placeholder\tslug\n' > "$W/root/scripts/candidate_sources.tsv"
expect "vendor refuses a source with no slug" 1 "no GitHub slug" -- R candidate_vendor.sh t/pkg --to new

# ======================= candidate.sh (the chain) =======================
mkroot; cd "$W/root" && git init -q . && git config user.email t@example.invalid && git config user.name t && git add -A && git commit -qm base; cd "$HERE" || exit 2
printf 'wiki-marker\tA fix\towner/repo#1\tgrep\tsynthetic marker v[0-9]\n' > "$W/rows.tsv"
expect "chain --dry-run prints the whole change set" 0 "+++ b/cut-manifests/v9.9.9.yaml" -- R candidate.sh v9.9.9 --wiki-tag 0.1.43 --manifest-rows "$W/rows.tsv" --dry-run
has "chain --dry-run changed nothing" "$W/root/install.sh" "$SITE_OLD" 1
expect "chain --dry-run includes the wiki diff" 0 "+    image: ghcr.io/org/ostler-wiki-site@$SITE_NEW" -- R candidate.sh v9.9.9 --wiki-tag 0.1.43 --dry-run
expect "chain real run" 0 - -- R candidate.sh v9.9.9 --wiki-tag 0.1.43 --manifest-rows "$W/rows.tsv"
has "chain real run pinned the wiki" "$W/root/install.sh" "$SITE_NEW" 1
expect "chain re-run is idempotent end to end" 0 "nothing to do" -- R candidate.sh v9.9.9 --wiki-tag 0.1.43 --manifest-rows "$W/rows.tsv"
expect "chain stops at the first refusal and says so" 1 "later steps NOT run" -- R candidate.sh v9.9.9 --wiki-tag 0.9.9 --manifest-rows "$W/rows.tsv"
expect "chain refuses content and pin in one invocation" 1 "phase two" -- R candidate.sh v9.9.9 --wiki-tag 0.1.43 --pin
expect "chain refuses a bad version" 2 "usage" -- R candidate.sh 9.9.9

echo "candidate scripts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
