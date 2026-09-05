#!/usr/bin/env bash
# A BROKEN CI QUERY MUST NOT READ AS A GREEN MAIN.
#
# WHY THIS EXISTS. `scripts/report_red_main_as_issues.sh` is the thing that
# notices a red main so that a person does not have to. Its whole value is the
# case where it finds nothing, and "found nothing" and "could not look" print
# identically unless something forces them apart.
#
# TWO REAL DEFECTS ARE PINNED HERE, both MEASURED while the script was written,
# both of which made it report a clean main while main was red:
#
#   1. THE PAGE IS NOT THE WINDOW. One push fires 136 workflows in the same
#      second, so `per_page=60` on main spanned ONE SECOND and `per_page=100`
#      filtered to successes spanned FIVE. A count-bounded lookback cannot
#      reach yesterday at any page size. Recovery must be asked per workflow.
#
#   2. A REFUSAL THAT EXITS 0 IS A PASS. The sibling defect TNM measured on
#      #1580: the script printed CANNOT-RUN and returned 0, so the step was
#      green while measuring nothing, and the words were in a log nobody reads.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO_ROOT}/scripts/report_red_main_as_issues.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no script at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
mkdir -p "${WORK}/bin"

# `jq` is required by the subject; without it every arm below would exit 2 for
# the wrong reason and the suite would look like it had run.
command -v jq >/dev/null 2>&1 || { echo "CANNOT-RUN: jq is not on PATH, so nothing here was measured." >&2; exit 2; }

_run() {   # _run <label> ; echoes rc
    env PATH="${WORK}/bin:${PATH}" \
        OSTLER_RED_MAIN_DRY_RUN=1 \
        OSTLER_RED_MAIN_REPO="o/r" \
        bash "$SUBJECT" > "${WORK}/out" 2> "${WORK}/err"
    printf '%s' "$?"
}

echo "== refusals must refuse, and must not exit 0 =="

# ── ARM 1: gh missing entirely ──────────────────────────────────────────────
# A PATH that still has the base toolchain but NOT gh. Stripping the whole PATH
# would make the script die at 127 on some other missing binary, and the arm
# would pass for a reason that has nothing to do with gh.
BAREPATH="/usr/bin:/bin:/usr/sbin:/sbin"
if env PATH="$BAREPATH" command -v gh >/dev/null 2>&1; then
    echo "CANNOT-RUN: gh is present on ${BAREPATH}, so this arm cannot construct a gh-absent PATH." >&2
    exit 2
fi
env PATH="$BAREPATH" command -v mktemp >/dev/null 2>&1 || {
    echo "CANNOT-RUN: mktemp is absent from ${BAREPATH}; the arm would fail for the wrong reason." >&2
    exit 2
}
rc="$(env PATH="$BAREPATH" OSTLER_RED_MAIN_DRY_RUN=1 bash "$SUBJECT" >/dev/null 2>&1; printf '%s' "$?")"
[ "$rc" = "2" ] && ok "gh absent exits 2, not 0, and the rest of the toolchain was present so that is the reason" \
                || bad "gh absent exits ${rc}; a check that could not run reported as if it had"

# ── ARM 2: the API answers, but with zero runs on a branch that is never idle ─
cat > "${WORK}/bin/gh" <<'STUB'
#!/bin/sh
case "$*" in
  *"actions/runs"*) echo '{"workflow_runs":[]}' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "${WORK}/bin/gh"
rc="$(_run)"
[ "$rc" = "2" ] && ok "zero runs on main exits 2: a busy branch answering empty is a broken instrument" \
                || bad "zero runs on main exits ${rc}, so a dead query reads as a clean branch"

# ── ARM 3: the API answers with something that is not JSON ──────────────────
cat > "${WORK}/bin/gh" <<'STUB'
#!/bin/sh
echo 'error: not json'
STUB
chmod +x "${WORK}/bin/gh"
rc="$(_run)"
[ "$rc" = "2" ] && ok "a non-JSON answer exits 2 rather than parsing to nothing" \
                || bad "a non-JSON answer exits ${rc}"

# ── ARM 4: gh exits non-zero, the shape of an expired token ─────────────────
cat > "${WORK}/bin/gh" <<'STUB'
#!/bin/sh
echo 'HTTP 401: Bad credentials' >&2
exit 1
STUB
chmod +x "${WORK}/bin/gh"
rc="$(_run)"
[ "$rc" = "2" ] && ok "an auth failure exits 2; expired credentials are not a green main" \
                || bad "an auth failure exits ${rc}"

# ── ARM 5: CONTROL. A healthy answer must exit 0. ───────────────────────────
# Without this, every arm above passes if the script simply always exits 2, and
# the suite would prove nothing at all.
cat > "${WORK}/bin/gh" <<'STUB'
#!/bin/sh
case "$*" in
  *"status=failure"*)  echo '{"workflow_runs":[]}' ;;
  *"actions/runs"*)    echo '{"workflow_runs":[{"name":"x","status":"completed","conclusion":"success","created_at":"2026-09-05T00:00:00Z","head_sha":"a","html_url":"u","workflow_id":1}]}' ;;
  *)                   echo '[]' ;;
esac
STUB
chmod +x "${WORK}/bin/gh"
rc="$(_run)"
[ "$rc" = "0" ] && ok "CONTROL: a healthy answer with no failures exits 0, so the 2s above are measurements" \
                || bad "CONTROL: a healthy answer exits ${rc}; this suite cannot distinguish refusal from breakage"

echo "== recovery must be asked PER WORKFLOW, not read off a shared page =="

# ── ARM 6: THE TRUNCATION DEFECT, BEHAVIOURALLY ─────────────────────────────
# The bulk success page carries NO row for this workflow, exactly as the real
# API behaved: 100 successes spanning five seconds, with the recovery older
# than that. Only the per-workflow endpoint knows the workflow recovered.
# A script that decides recovery from the shared page reports this red as still
# open; a script that asks per workflow reports it recovered.
cat > "${WORK}/bin/gh" <<'STUB'
#!/bin/sh
case "$*" in
  *"actions/workflows/77/runs"*)
      echo '{"workflow_runs":[{"created_at":"2026-09-05T12:00:00Z"}]}' ;;
  *"status=failure"*)
      echo '{"workflow_runs":[{"name":"lonely","status":"completed","conclusion":"failure","created_at":"2026-09-05T09:00:00Z","head_sha":"deadbeefcafe","html_url":"u","workflow_id":77}]}' ;;
  *"status=success"*)
      echo '{"workflow_runs":[{"name":"someone-else","created_at":"2026-09-05T23:59:59Z"}]}' ;;
  *"actions/runs"*)
      echo '{"workflow_runs":[{"name":"x","status":"completed","conclusion":"success","created_at":"2026-09-05T00:00:00Z","head_sha":"a","html_url":"u","workflow_id":1}]}' ;;
  *)  echo '[]' ;;
esac
STUB
chmod +x "${WORK}/bin/gh"
rc="$(_run)"
out="$(cat "${WORK}/out")"
case "$out" in
    *"recovered (green at 2026-09-05T12:00:00Z)"*)
        ok "recovery is read from the workflow's OWN endpoint, so a busy neighbour cannot truncate it away" ;;
    *"OPENING"*)
        bad "the recovered red was reported as still open: recovery is being decided from the shared page, which spans seconds" ;;
    *)  bad "neither recovery nor opening was reported (rc=${rc}); output was: ${out}" ;;
esac

# ── ARM 7: CONTROL ON ARM 6. A genuinely unrecovered red must still OPEN. ───
# Arm 6 alone passes if the script called everything recovered.
cat > "${WORK}/bin/gh" <<'STUB'
#!/bin/sh
case "$*" in
  *"actions/workflows/77/runs"*)
      echo '{"workflow_runs":[{"created_at":"2026-09-05T06:00:00Z"}]}' ;;
  *"status=failure"*)
      echo '{"workflow_runs":[{"name":"lonely","status":"completed","conclusion":"failure","created_at":"2026-09-05T09:00:00Z","head_sha":"deadbeefcafe","html_url":"u","workflow_id":77}]}' ;;
  *"actions/runs"*)
      echo '{"workflow_runs":[{"name":"x","status":"completed","conclusion":"success","created_at":"2026-09-05T00:00:00Z","head_sha":"a","html_url":"u","workflow_id":1}]}' ;;
  *)  echo '[]' ;;
esac
STUB
chmod +x "${WORK}/bin/gh"
rc="$(_run)"
out="$(cat "${WORK}/out")"
case "$out" in
    *"OPENING: main is red: lonely at deadbee"*)
        ok "CONTROL: a red whose only green PREDATES it still opens, so arm 6 is a discriminator not a blanket" ;;
    *)  bad "CONTROL: an unrecovered red did not open (rc=${rc}); output was: ${out}" ;;
esac

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
