#!/usr/bin/env bash
# ============================================================================
# THE DRAIN REMOVES ONLY DEAD ROWS, AND LOSES NOTHING ELSE.
#
# scripts/drain_pr_exemptions.sh --retire-closed rewrites cut-deferrals.yaml,
# stripping the exemptions whose PR has merged/closed. A rewrite of a
# hand-maintained, comment-interleaved YAML is exactly where a careless sweep
# "makes matters worse": it can drop a comment, eat a neighbouring entry, or
# silently truncate. This test pins the three properties that make the rewrite
# safe to run unattended:
#   * it removes the merged/closed rows and ONLY those;
#   * every surviving entry AND every comment is preserved byte-for-byte;
#   * it is idempotent and dry-run-by-default (the default touches nothing).
# ============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRAIN="${REPO_ROOT}/scripts/drain_pr_exemptions.sh"

pass=0; fail=0
ok()  { printf '  [ok]     %s\n' "$*"; pass=$(( pass + 1 )); }
bad() { printf '  [FAIL]   %s\n' "$*"; fail=$(( fail + 1 )); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then exit 1; fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    num="$3"
    case " ${GH_MERGED:-} " in *" $num "*) echo MERGED; exit 0 ;; esac
    case " ${GH_CLOSED:-} " in *" $num "*) echo CLOSED; exit 0 ;; esac
    echo OPEN; exit 0
fi
exit 1
SHIM
chmod +x "${WORK}/bin/gh"

SEED="${WORK}/deferrals.yaml"
cat > "${SEED}" <<'YAML'
pr_exemptions_live_cap: 10

pr_exemptions:
  # ---- GROUP A (keep this comment) ----
  - ref: "CM051-Home-Hub-Installer#200"
    reason: "this PR has merged -- dead weight"
    review_by: 2099-01-01
  - ref: "CM051-Home-Hub-Installer#101"
    reason: "still open, a keeper"
    review_by: 2099-01-01
  # ---- GROUP B (keep this comment too) ----
  - ref: "CM051-Home-Hub-Installer#201"
    reason: "this PR was closed -- dead weight"
    review_by: 2000-01-01
  - ref: "CM051-Home-Hub-Installer#102"
    reason: "still open, another keeper"
    review_by: 2099-01-01
YAML

run_drain() { # <mode-flag-or-empty> ; sets OUT, RC
    OUT="$(PATH="${WORK}/bin:${PATH}" \
           GH_MERGED=200 GH_CLOSED=201 \
           PR_AGE_REPOS="owner/CM051-Home-Hub-Installer" \
           OSTLER_CUT_DEFERRALS="${SEED}" \
           bash "${DRAIN}" ${1:+$1} 2>&1)"
    RC=$?
}

echo "== the drain removes only dead rows, and loses nothing else =="
echo ""

# --- 1. DRY RUN touches nothing --------------------------------------------
before="$(cksum < "${SEED}")"
run_drain ""
after="$(cksum < "${SEED}")"
if [[ "${before}" == "${after}" ]] && grep -q 'DRY RUN' <<< "${OUT}"; then
    ok "1. dry-run (default) leaves the file byte-identical and says DRY RUN"
else
    bad "1. dry-run modified the file or did not announce itself"
fi

# --- 2. --retire-closed removes the merged+closed rows ----------------------
run_drain "--retire-closed"
if [[ "${RC}" == "0" ]] \
   && ! grep -q '#200' "${SEED}" \
   && ! grep -q '#201' "${SEED}"; then
    ok "2. --retire-closed removed the merged (#200) and closed (#201) rows"
else
    bad "2. retire-closed did not remove both dead rows (rc=${RC})"
fi

# --- 3. the keepers survive -------------------------------------------------
if grep -q '#101' "${SEED}" && grep -q '#102' "${SEED}"; then
    ok "3. the still-open keepers (#101, #102) survive"
else
    bad "3. a still-open keeper was wrongly removed"
fi

# --- 4. comments and the cap line survive -----------------------------------
if grep -q 'GROUP A (keep this comment)' "${SEED}" \
   && grep -q 'GROUP B (keep this comment too)' "${SEED}" \
   && grep -q '^pr_exemptions_live_cap: 10' "${SEED}"; then
    ok "4. both interleaved comments and the cap line are preserved"
else
    bad "4. a comment or the cap line was lost in the rewrite"
fi

# --- 5. exactly two rows remain ---------------------------------------------
remaining="$(sed -n '/^pr_exemptions:/,$p' "${SEED}" | grep -c '^[[:space:]]*-[[:space:]]*ref:')"
if [[ "${remaining}" == "2" ]]; then
    ok "5. exactly 2 exemption rows remain (4 seeded, 2 retired)"
else
    bad "5. expected 2 rows remaining, found ${remaining}"
fi

# --- 6. idempotent: a second retire-closed is a clean no-op -----------------
cksum_before="$(cksum < "${SEED}")"
run_drain "--retire-closed"
cksum_after="$(cksum < "${SEED}")"
if [[ "${RC}" == "0" ]] && [[ "${cksum_before}" == "${cksum_after}" ]] \
   && grep -q 'Nothing to retire' <<< "${OUT}"; then
    ok "6. a second --retire-closed changes nothing (idempotent)"
else
    bad "6. second retire-closed was not a clean no-op (rc=${RC})"
fi

echo ""
echo "== ${pass} passed, ${fail} failed =="
if (( fail > 0 )); then exit 1; fi
exit 0
