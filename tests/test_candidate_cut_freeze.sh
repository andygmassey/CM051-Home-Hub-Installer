#!/usr/bin/env bash
# tests/test_candidate_cut_freeze.sh -- scripts/candidate.sh freeze <version> against synthetic fixtures.
#
# A real git repo with a bare origin; gh is a stub (CANDIDATE_GH) that answers the
# way the real one does, INCLUDING a 404 as a JSON body on stdout with exit 1.
# Every refusal has a fixture that trips it and asserts the exit code, the
# runbook step named, and a fragment of the words, so a script that refuses for
# the wrong reason (or crashes) does not pass. No network, no real data.
#
# FREEZE_SCRIPT overrides the script under test (used to show the guards are what
# make the refusal tests pass: see the PR description).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="${FREEZE_SCRIPT:-$HERE/scripts/candidate.sh}"
W="$(mktemp -d "${TMPDIR:-/tmp}/cand-freeze-test.XXXXXX")"; trap 'rm -rf "${W:?}"' EXIT
REALGIT="$(command -v git)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/    /' | head -14; }
# expect <name> <rc> <fragment|-> -- cmd...
expect() { local name="$1" rc="$2" frag="$3"; shift 4; OUT="$("$@" 2>&1)"; local got=$?
	if [ "$got" -ne "$rc" ]; then bad "$name: exit $got, wanted $rc" "$OUT"; return 1; fi
	if [ "$frag" != "-" ] && ! printf '%s' "$OUT" | grep -qF -- "$frag"; then bad "$name: output lacks '$frag'" "$OUT"; return 1; fi
	ok; }
lacks() { if printf '%s' "$OUT" | grep -qF -- "$2"; then bad "$1: output contains '$2'" "$OUT"; else ok; fi; }
check() { # check <name> <cmd...> : passes when the command succeeds
	local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$n"; fi; }

D1="1111111111111111111111111111111111111111"; D2="2222222222222222222222222222222222222222"
NOT_FOUND='{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'

# ---- stubs ------------------------------------------------------------------
mkdir -p "$W/bin"
cat > "$W/bin/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = push ] && { printf '%s\n' "\$*" >> "$W/gitlog"; break; }; done
exec "$REALGIT" "\$@"
STUB
cat > "$W/gh" <<'STUB'
#!/usr/bin/env bash
# stub for: gh api <path> [-X POST ...] [--jq X]; prints what the real call would print AFTER --jq.
p="$2"; post=0; for a in "$@"; do [ "$a" = POST ] && post=1; done
notfound() { echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'; exit 1; }
serve() { # serve <file>: the file's first line is a mode: OK | 404 | FAIL | RAWOK(body printed, exit 0)
	[ -f "$1" ] || notfound; m="$(head -1 "$1")"
	case "$m" in OK) tail -n +2 "$1" ;; 404) notfound ;; FAIL) echo "gh: Bad Gateway (HTTP 502)"; exit 1 ;; RAWOK) tail -n +2 "$1" ;; esac; }
case "$p" in
	repos/rc/mirror/git/ref/tags/*) serve "$FX/rc_ref" ;;
	repos/rc/mirror/git/tags/*) serve "$FX/rc_tag" ;;
	repos/rc/mirror/compare/*) serve "$FX/rc_compare" ;;
	repos/own/repo/pulls\?state=open*) serve "$FX/prs_open" ;;
	repos/other/two/pulls\?state=open*) serve "$FX/prs_other" ;;
	repos/own/repo/pulls\?state=all*) serve "$FX/prs_all" ;;
	repos/own/repo/pulls) if [ "$post" -eq 1 ]; then printf '%s\n' "$*" >> "$FX/created.log"; echo 77; else exit 1; fi ;;
	repos/own/repo/issues*) serve "$FX/issues" ;;
	*) echo "stub: no answer for $p" >&2; exit 1 ;;
esac
STUB
chmod +x "$W/bin/git" "$W/gh"

plist() { cat <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Fixture</string>
	<key>CFBundleShortVersionString</key>
	<string>$1</string>
	<key>CFBundleVersion</key>
	<string>$2</string>
</dict>
</plist>
P
}

# mkfx [current-version] [current-build]: fresh origin + clone with a coherent v1.0.108 cut
mkfx() {
	local cv="${1:-1.0.107}" cb="${2:-10700}"
	rm -rf "${W:?}/origin.git" "$W/work" "$W/fx" "$W/os003" "$W/gitlog"; mkdir -p "$W/fx" "$W/os003"
	"$REALGIT" init -q --bare "$W/origin.git"
	"$REALGIT" init -q -b main "$W/work" && cd "$W/work" || exit 2
	"$REALGIT" config user.email t@example.invalid; "$REALGIT" config user.name t
	"$REALGIT" remote add origin "$W/origin.git"
	mkdir -p gui/OstlerInstaller gui/OstlerInstaller.xcodeproj scripts cuts/v1.0.108 cut-manifests
	echo 'OSTLER_REMOTECAPTURE_VERSION="${OSTLER_REMOTECAPTURE_VERSION:-0.1.5}"' > install.sh
	plist "$cv" "$cb" > gui/OstlerInstaller/Info.plist
	printf 'settings:\n  base:\n    CURRENT_PROJECT_VERSION: "%s"\n    MARKETING_VERSION: "%s"\ntargets:\n  App:\n    info:\n      properties:\n        CFBundleShortVersionString: "%s"\n        CFBundleVersion: "%s"\n' "$cb" "$cv" "$cv" "$cb" > gui/project.yml
	printf '\t\t\t\tCURRENT_PROJECT_VERSION = %s;\n\t\t\t\tMARKETING_VERSION = %s;\n\t\t\t\tCURRENT_PROJECT_VERSION = %s;\n\t\t\t\tMARKETING_VERSION = %s;\n' "$cb" "$cv" "$cb" "$cv" > gui/OstlerInstaller.xcodeproj/project.pbxproj
	# the PR-age gate's own repo list, in the gate's own format (see scripts/verify_pr_age.sh DEFAULT_REPOS)
	printf 'DEFAULT_REPOS="own/repo\nother/two"\n' > scripts/verify_pr_age.sh
	printf '#!/usr/bin/env bash\n[ "${FX_BOM_SYNC_RC:-0}" -eq 0 ] || { echo STALE >&2; exit "$FX_BOM_SYNC_RC"; }\n[ -n "${OS003_DIR:-}" ] && exit 0\nexit 2\n' > scripts/sync_cut_bom.sh
	printf '#!/usr/bin/env bash\necho "  rows        : 3"\n[ "${FX_BOM_NOABSENT:-0}" = 1 ] || echo "  ABSENT      : ${FX_BOM_ABSENT:-0}"\nexit "${FX_BOM_RC:-0}"\n' > scripts/verify_bom_rows_are_in_the_pin.sh
	cat > scripts/sync_rollforward_registry.sh <<'SYNC'
#!/usr/bin/env bash
# fixture stand-in for the real sync: same contract (--check, exit 2 on refusal)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "${FX_SYNC_FAIL:-0}" = 1 ] && { echo "ERROR: OS003 checkout is 3 commit(s) behind origin/main" >&2; exit 2; }
if [ "${1:-}" = "--check" ]; then cmp -s "$FX_OS003/DEFECTS" "$HERE/cuts/DEFECTS_ROLLFORWARD.md"; exit $?; fi
cp "$FX_OS003/DEFECTS" "$HERE/cuts/DEFECTS_ROLLFORWARD.md"
printf 'os003_sha\t%s\n' "$(cat "$FX_OS003/SHA")" > "$HERE/cuts/REGISTRY_PIN"
[ "${FX_SYNC_EXTRA:-0}" = 1 ] && echo '# smuggled' >> "$HERE/install.sh"
exit 0
SYNC
	echo "defects v1" > cuts/DEFECTS_ROLLFORWARD.md; echo "defects v2" > "$W/os003/DEFECTS"; echo "$D2" > "$W/os003/SHA"
	printf 'os003_sha\t%s\n' "$D1" > cuts/REGISTRY_PIN
	"$REALGIT" add -A && "$REALGIT" commit -qm "product commit"
	local pin; pin="$("$REALGIT" rev-parse --short=8 HEAD)"
	printf 'CUT_VERSION=1.0.108\nDAEMON_COMMIT=aaaaaaaa\nCM051=%s\n' "$pin" > cuts/v1.0.108/cut.env
	printf 'version: v1.0.108\nentries:\n  - id: existing-row\n    title: x\n\nopen_issues:\n  - issue: 300\n    repo: CM051\n    title: old\n    gate: PR #1 merged\n' > cut-manifests/v1.0.108.yaml
	printf 'deferrals: []\n\npr_exemptions:\n  - ref: "repo#5"\n    reason: "valid row"\n    review_by: 2026-12-01\n' > cut-deferrals.yaml
	"$REALGIT" add -A && "$REALGIT" commit -qm "open the cut (cuts/ only)"
	"$REALGIT" push -q origin main 2>/dev/null; "$REALGIT" fetch -q origin
	# gh answers
	printf 'OK\ncommit %s\n' "$D1" > "$W/fx/rc_ref"
	printf 'OK\nbehind\n' > "$W/fx/rc_compare"
	printf '404\n' > "$W/fx/rc_tag"
	printf 'OK\n11\t2026-10-01T00:00:00Z\tfalse\tfix/old\tAn old PR\n12\t2026-10-08T06:00:00Z\tfalse\tfix/young\tA young PR\n5\t2026-09-01T00:00:00Z\tfalse\tfix/exempt\tAn exempt PR\n' > "$W/fx/prs_open"
	printf 'OK\n' > "$W/fx/prs_all"; printf 'OK\n' > "$W/fx/prs_other"
	printf 'OK\n300\told\n301\tA new issue\n' > "$W/fx/issues"
	export CANDIDATE_ROOT="$W/work" CANDIDATE_GH="$W/gh" CANDIDATE_CM051_REPO=own/repo CANDIDATE_RC_REPO=rc/mirror \
		FX="$W/fx" FX_OS003="$W/os003" CANDIDATE_NOW="$(date -u -d 2026-10-08T12:00:00Z +%s 2>/dev/null || date -j -u -f %Y-%m-%dT%H:%M:%SZ 2026-10-08T12:00:00Z +%s)" \
		CANDIDATE_TODAY=2026-10-08 PATH="$W/bin:$PATH"
	unset FX_SYNC_FAIL FX_SYNC_EXTRA FX_BOM_RC FX_BOM_ABSENT FX_BOM_SYNC_RC FX_BOM_NOABSENT
	cd "$HERE" || exit 2
}
FS() { bash "$SUT" freeze v1.0.108 "$@"; }
F() { FS --os003-dir "$W/os003" "$@"; }
orig() { "$REALGIT" -C "$W/origin.git" "$@"; }
branch_file() { orig show "cut/v1.0.108:$1"; }

# ======================= happy path =======================
mkfx
expect "dry-run: prints the plan, names the person steps, and finishes" 0 "DRY RUN complete" -- F --dry-run
for s in "step  2  PERSON" "step  3  VERIFY" "steps 10-14" "would open a NEW draft PR"; do
	printf '%s' "$OUT" | grep -qF -- "$s" && ok || bad "dry-run plan lacks '$s'" "$OUT"; done
check "dry-run pushed nothing" test -z "$(orig for-each-ref refs/heads/cut)"
check "dry-run opened no PR" test ! -f "$W/fx/created.log"
check "dry-run left no local branch" test -z "$("$REALGIT" -C "$W/work" branch --list 'cut/*')"
check "dry-run left the tree clean" test -z "$("$REALGIT" -C "$W/work" status --porcelain)"

expect "real run completes through step 9" 0 "FREEZE v1.0.108 DONE" -- F
HEAD1="$(orig rev-parse refs/heads/cut/v1.0.108 2>/dev/null)"
check "cut branch is on origin" test -n "$HEAD1"
check "Info.plist bumped (version and build)" bash -c "$REALGIT -C $W/origin.git show cut/v1.0.108:gui/OstlerInstaller/Info.plist | grep -q '<string>1.0.108</string>' && $REALGIT -C $W/origin.git show cut/v1.0.108:gui/OstlerInstaller/Info.plist | grep -q '<string>10800</string>'"
check "project.yml bumped on all four keys" test "$(branch_file gui/project.yml | grep -c -E '"(1\.0\.108|10800)"')" -eq 4
check "pbxproj bumped on both configs" test "$(branch_file gui/OstlerInstaller.xcodeproj/project.pbxproj | grep -c -E '= (1\.0\.108|10800);')" -eq 4
check "registry synced" test "$(branch_file cuts/DEFECTS_ROLLFORWARD.md)" = "defects v2"
check "registry pin rewritten" bash -c "$REALGIT -C $W/origin.git show cut/v1.0.108:cuts/REGISTRY_PIN | grep -q $D2"
check "over-48h PR got a row" bash -c "$REALGIT -C $W/origin.git show cut/v1.0.108:cut-deferrals.yaml | grep -qF 'ref: \"repo#11\"'"
check "the row carries a review_by" bash -c "$REALGIT -C $W/origin.git show cut/v1.0.108:cut-deferrals.yaml | grep -qF 'review_by: 2026-10-15'"
check "young PR got no row" bash -c "! $REALGIT -C $W/origin.git show cut/v1.0.108:cut-deferrals.yaml | grep -qF 'repo#12'"
check "already exempt PR was not duplicated" test "$(branch_file cut-deferrals.yaml | grep -cF 'ref: "repo#5"')" -eq 1
check "unregistered issue got a deferred checklist row" bash -c "$REALGIT -C $W/origin.git show cut/v1.0.108:cut-manifests/v1.0.108.yaml | grep -qF 'issue: 301'"
check "registered issue was not duplicated" test "$(branch_file cut-manifests/v1.0.108.yaml | grep -cE 'issue: 300')" -eq 1
check "the new row says NOT BLOCKING and DEFERRED" bash -c "$REALGIT -C $W/origin.git show cut/v1.0.108:cut-manifests/v1.0.108.yaml | grep -F 'issue: 301' -A4 | grep -qF 'NOT BLOCKING for v1.0.108; DEFERRED to v1.0.109'"
check "exactly one draft PR was opened, as a draft, from cut/v1.0.108 to main" bash -c "test \$(wc -l < $W/fx/created.log) -eq 1 && grep -q 'draft=true' $W/fx/created.log && grep -q 'head=cut/v1.0.108' $W/fx/created.log && grep -q 'base=main' $W/fx/created.log && grep -q 'DO NOT MERGE' $W/fx/created.log"
check "the push used --force-with-lease and never a bare force" bash -c "grep -q -- '--force-with-lease=refs/heads/cut/v1.0.108:' $W/gitlog && ! grep -qE -- '(^| )(-f|--force)( |$)' $W/gitlog"

# idempotent re-run: the PR is now open at the head
printf 'OK\n77\topen\t%s\n' "$HEAD1" > "$W/fx/prs_all"
printf 'OK\n11\t2026-10-01T00:00:00Z\tfalse\tfix/old\tAn old PR\n12\t2026-10-08T06:00:00Z\tfalse\tfix/young\tA young PR\n5\t2026-09-01T00:00:00Z\tfalse\tfix/exempt\tAn exempt PR\n77\t2026-10-01T00:00:00Z\ttrue\tcut/v1.0.108\tDO NOT MERGE\n' > "$W/fx/prs_open"
printf 'OK\n300\told\n301\tA new issue\n' > "$W/fx/issues"
"$REALGIT" -C "$W/work" branch -f cut/v1.0.108 "$HEAD1" >/dev/null 2>&1
expect "re-run on the same inputs is a no-op that still passes" 0 "already at the cut head" -- F
check "re-run opened no second PR" test "$(wc -l < "$W/fx/created.log")" -eq 1

# ======================= step 1 =======================
mkfx; printf '404\n' > "$W/fx/rc_ref"
expect "S1: a 404 on the mirror tag is ABSENT and refuses" 1 "runbook step 1" -- F; lacks "S1: the 404 body is never echoed as a value" "documentation_url"
printf '%s' "$OUT" | grep -qF "ABSENT" && ok || bad "S1: says ABSENT" "$OUT"
mkfx; printf 'RAWOK\n%s\n' "$NOT_FOUND" > "$W/fx/rc_ref"
expect "S1: a 404 JSON body that arrives with exit 0 is not a sha" 1 "not a type and a 40-hex sha" -- F
mkfx; printf 'FAIL\n' > "$W/fx/rc_ref"
expect "S1: a gateway error is CANNOT-RUN, not absent and not a pass" 2 "CANNOT-RUN at runbook step 1" -- F
mkfx; printf 'OK\nahead\n' > "$W/fx/rc_compare"
expect "S1: a tag whose commit is not an ancestor of the mirror main refuses" 1 "fast-forwarded" -- F
mkfx; printf '404\n' > "$W/fx/rc_compare"
expect "S1: a build commit that was never mirrored (404) refuses" 1 "never mirrored" -- F
mkfx
expect "S1: a peel that is not the build commit refuses" 1 "must peel to the build commit itself" -- F --rc-build-commit "$D2"
mkfx; printf 'OK\ntag %s\n' "$D2" > "$W/fx/rc_ref"; printf 'OK\ncommit %s\n' "$D1" > "$W/fx/rc_tag"
expect "S1: an annotated tag is peeled to its commit and passes" 0 "-> 11111111" -- F --dry-run --rc-build-commit "$D1"

# ======================= step 3 =======================
mkfx
expect "S3: with --os003-dir the BOM check runs and passes" 0 "0 ABSENT" -- FS --dry-run --os003-dir "$W/os003"
mkfx
expect "S3: no flag at all refuses, naming both ways out" 1 "runbook step 3" -- FS --dry-run
printf '%s' "$OUT" | grep -qF -- "--no-bom-check" && ok || bad "S3: names --no-bom-check" "$OUT"
check "S3: a refused step 3 changed nothing" test -z "$(orig for-each-ref refs/heads/cut)"
mkfx; export FX_BOM_RC=1 FX_BOM_ABSENT=2
expect "S3: verify rc=1 refuses" 1 "exited 1, not 0" -- FS --dry-run --os003-dir "$W/os003"
mkfx; export FX_BOM_RC=0 FX_BOM_ABSENT=2
expect "S3: rc=0 but ABSENT>0 still refuses" 1 "2 ABSENT" -- FS --dry-run --os003-dir "$W/os003"
mkfx; export FX_BOM_NOABSENT=1
expect "S3: rc=0 with no ABSENT count printed is not a measured zero" 1 "no ABSENT count" -- FS --dry-run --os003-dir "$W/os003"
mkfx; export FX_BOM_SYNC_RC=1
expect "S3: a vendored BOM that differs from OS003 refuses" 1 "not the one in" -- FS --dry-run --os003-dir "$W/os003"
mkfx
expect "S3: --os003-dir that is not a directory is CANNOT-RUN" 2 "not a directory" -- FS --dry-run --os003-dir "$W/nope"
expect "S3: the two flags together are CANNOT-RUN" 2 "contradict" -- FS --dry-run --os003-dir "$W/os003" --no-bom-check
mkfx; export FX_BOM_RC=1
expect "S3: --no-bom-check skips, and says SKIPPED on the step" 0 "!! SKIPPED: step 3" -- FS --dry-run --no-bom-check
printf '%s' "$OUT" | grep -qF "!! SKIPPED STEPS: step 3 (OS003 BOM rows)" && ok || bad "S3: the summary carries the SKIPPED line" "$OUT"
mkfx; FS --no-bom-check >/dev/null 2>&1
check "S3: a real run with --no-bom-check still completes" test -n "$(orig rev-parse refs/heads/cut/v1.0.108 2>/dev/null)"

# ======================= step 7: every repo the PR-age gate scans =======================
mkfx; printf 'OK\n41\t2026-10-01T00:00:00Z\tfalse\tfix/x\tAn old PR in a sibling repo\n' > "$W/fx/prs_other"
expect "S7: an over-48h PR in a NON-CM051 repo the gate scans gets a row" 0 "deferral row: two#41" -- F --dry-run
mkfx; printf 'OK\n41\t2026-10-01T00:00:00Z\tfalse\tfix/x\tAn old PR in a sibling repo\n' > "$W/fx/prs_other"; F >/dev/null 2>&1
check "S7: the sibling-repo row is in the pushed cut-deferrals.yaml" bash -c "$REALGIT -C $W/origin.git show cut/v1.0.108:cut-deferrals.yaml | grep -qF 'ref: \"two#41\"'"
mkfx; printf 'OK\n41\t2026-10-01T00:00:00Z\tfalse\tfix/x\tx\n' > "$W/fx/prs_other"
( cd "$W/work" && printf '  - ref: "two#41"\n    reason: "old"\n    review_by: 2026-10-02\n' >> cut-deferrals.yaml && "$REALGIT" add -A && "$REALGIT" commit -qm r && "$REALGIT" push -q origin main )
expect "S7: an expired exemption in a sibling repo refuses too" 1 "two#41 is over 48h and its exemption EXPIRED" -- F --dry-run
mkfx; printf '404\n' > "$W/fx/prs_other"
expect "S7: a sibling repo the gate scans but cannot be read is CANNOT-RUN, not skipped" 2 "other/two" -- F --dry-run
mkfx; printf 'DEFAULT_REPOS="own/repo\nother/three"\n' > "$W/work/scripts/verify_pr_age.sh"
( cd "$W/work" && "$REALGIT" add -A && "$REALGIT" commit -qm g && "$REALGIT" push -q origin main && sed -i.bak "s/^CM051=.*/CM051=$("$REALGIT" rev-parse --short=8 HEAD)/" cuts/v1.0.108/cut.env && rm -f cuts/v1.0.108/cut.env.bak && "$REALGIT" add -A && "$REALGIT" commit -qm p && "$REALGIT" push -q origin main )
expect "S7: the repo list follows the gate file, not a copy (other/three is asked for)" 2 "other/three" -- F --dry-run

# ======================= step 4 =======================
mkfx; cd "$W/work" && echo more >> scripts/extra.sh && "$REALGIT" add -A && "$REALGIT" commit -qm "a later product commit" && "$REALGIT" push -q origin main && cd "$HERE" || exit 2
expect "S4: a pin that is not the last product commit refuses" 1 "runbook step 4" -- F --dry-run
mkfx; sed -i.bak 's/^CM051=.*/CM051=deadbeef/' "$W/work/cuts/v1.0.108/cut.env"; rm -f "$W/work/cuts/v1.0.108/cut.env.bak"
( cd "$W/work" && "$REALGIT" add -A && "$REALGIT" commit -qm x && "$REALGIT" push -q origin main )
expect "S4: a pin that resolves to nothing refuses" 1 "does not resolve" -- F --dry-run
mkfx; ( cd "$W/work" && "$REALGIT" rm -q cut-manifests/v1.0.108.yaml && "$REALGIT" commit -qm x && "$REALGIT" push -q origin main )
expect "S4: a cut with no manifest refuses" 1 "no cut-manifests/v1.0.108.yaml" -- F --dry-run

# ======================= step 5 =======================
mkfx 1.0.109 10900
expect "S5: a freeze never lowers the version" 1 "runbook step 5" -- F --dry-run
mkfx; sed -i.bak '/CFBundleVersion:/d' "$W/work/gui/project.yml"; rm -f "$W/work/gui/project.yml.bak"
( cd "$W/work" && "$REALGIT" add -A && "$REALGIT" commit -qm "gui change" && "$REALGIT" push -q origin main && sed -i.bak "s/^CM051=.*/CM051=$("$REALGIT" rev-parse --short=8 HEAD)/" cuts/v1.0.108/cut.env && rm -f cuts/v1.0.108/cut.env.bak && "$REALGIT" add -A && "$REALGIT" commit -qm "repin" && "$REALGIT" push -q origin main )
expect "S5: a project.yml missing a version key refuses instead of half-bumping" 1 "four version keys" -- F --dry-run
mkfx 2.0.1 100
expect "S5: a version outside 1.0.P is not guessed" 1 "not a 1.0.P version" -- F --dry-run

# ======================= step 6 =======================
mkfx; export FX_SYNC_FAIL=1
expect "S6: a refused registry sync stops the freeze" 1 "runbook step 6" -- F --dry-run
unset FX_SYNC_FAIL

# ======================= step 7 =======================
mkfx; printf 'OK\n11\t2026-10-01T00:00:00Z\tfalse\tfix/old\tAn old PR\n' > "$W/fx/prs_open"
( cd "$W/work" && printf '  - ref: "repo#11"\n    reason: "was decided"\n    review_by: 2026-10-02\n' >> cut-deferrals.yaml && "$REALGIT" add -A && "$REALGIT" commit -qm "old row" && "$REALGIT" push -q origin main )
expect "S7: an EXPIRED exemption is not silently renewed" 1 "EXPIRED on 2026-10-02" -- F --dry-run
mkfx; printf 'OK\n11\t2026-10-01T00:00:00Z\tfalse\tfix/old\tAn old PR\n' > "$W/fx/prs_open"
( cd "$W/work" && printf '  - ref: "repo#11"\n    reason: "no date"\n' >> cut-deferrals.yaml && "$REALGIT" add -A && "$REALGIT" commit -qm "undated row" && "$REALGIT" push -q origin main )
expect "S7: an undated exemption refuses" 1 "no review_by date" -- F --dry-run
mkfx; printf 'OK\n' > "$W/fx/issues"
expect "S7: an EMPTY open-issue list is CANNOT-RUN, not a clean register" 2 "came back EMPTY" -- F --dry-run
mkfx; printf '404\n' > "$W/fx/issues"
expect "S7: a 404 on the issue list is CANNOT-RUN" 2 "answered 404" -- F --dry-run
mkfx; ( cd "$W/work" && printf 'trailer:\n  - x: 1\n' >> cut-manifests/v1.0.108.yaml && "$REALGIT" add -A && "$REALGIT" commit -qm t && "$REALGIT" push -q origin main )
expect "S7: open_issues not last refuses to append blindly" 1 "not the last top-level key" -- F --dry-run
mkfx; printf '404\n' > "$W/fx/prs_open"
expect "S7: a 404 on the PR list is CANNOT-RUN" 2 "answered 404" -- F --dry-run

# ======================= step 8 =======================
mkfx; export FX_SYNC_EXTRA=1
expect "S8: a diff outside version/registry/deferral files refuses" 1 "runbook step 8" -- F --dry-run
unset FX_SYNC_EXTRA

# ======================= step 9 =======================
mkfx; F >/dev/null 2>&1
( cd "$W/work" && "$REALGIT" commit -q --allow-empty -m "main moved" ) ; "$REALGIT" -C "$W/work" push -q origin main; "$REALGIT" -C "$W/work" fetch -q origin
printf 'OK\n' > "$W/fx/prs_all"
OLD="$(orig rev-parse refs/heads/cut/v1.0.108)"
( cd "$W/work" && "$REALGIT" branch -f cut/v1.0.108 "$OLD" >/dev/null )
expect "S9: a re-freeze without --refreeze refuses and pushes nothing" 1 "RE-freeze" -- F
check "S9: origin cut branch unmoved" test "$(orig rev-parse refs/heads/cut/v1.0.108)" = "$OLD"
: > "$W/gitlog"
expect "S9: --refreeze replaces it with a lease pinned to the sha just read" 0 "force-with-lease against ${OLD:0:8}" -- F --refreeze
check "S9: the lease names the old sha" grep -qF -- "--force-with-lease=refs/heads/cut/v1.0.108:$OLD" "$W/gitlog"
check "S9: origin now holds the new freeze" test "$(orig rev-parse refs/heads/cut/v1.0.108)" != "$OLD"

mkfx
mkdir -p "$W/origin.git/hooks"; printf '#!/bin/sh\necho "remote: https://user:SECRETTOKEN@example.invalid/x denied" >&2\nexit 1\n' > "$W/origin.git/hooks/pre-receive"; chmod +x "$W/origin.git/hooks/pre-receive"
BEFORE="$(orig for-each-ref --format='%(refname)')"
expect "S9: a denied push STOPS the run" 1 "PUSH DENIED OR FAILED at runbook step 9" -- F
lacks "S9: no credential is printed" "SECRETTOKEN"
check "S9: no PR was opened after a denied push" test ! -f "$W/fx/created.log"
check "S9: no other ref was created on origin" test "$(orig for-each-ref --format='%(refname)')" = "$BEFORE"
printf '%s' "$OUT" | grep -qF "Not retrying" && ok || bad "S9: says it will not route around" "$OUT"

mkfx; printf 'OK\n60\tclosed\t%s\n' "$D2" > "$W/fx/prs_all"
expect "S9: a CLOSED freeze PR is ignored and a NEW draft is opened" 0 "opened NEW draft PR #77" -- F
printf '%s' "$OUT" | grep -qF "ignoring CLOSED PR #60" && ok || bad "S9: names the closed PR it ignored" "$OUT"
mkfx; printf 'OK\n61\topen\t%s\n' "$D2" > "$W/fx/prs_all"
expect "S9: an open PR at a stale head refuses" 1 "not the cut head" -- F
check "S9: and opened nothing" test ! -f "$W/fx/created.log"

# ======================= the command surface =======================
mkfx
expect "candidate.sh freeze with no version is CANNOT-RUN" 2 "usage" -- bash "$HERE/scripts/candidate.sh" freeze
expect "candidate.sh freeze with a bad version is CANNOT-RUN" 2 "usage" -- bash "$HERE/scripts/candidate.sh" freeze 1.0.108
expect "the old candidate.sh <version> chain still parses" 2 "usage" -- bash "$HERE/scripts/candidate.sh" notaversion

echo "candidate cut freeze: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
