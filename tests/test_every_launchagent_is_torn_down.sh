#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_every_launchagent_is_torn_down.sh
#
# Every LaunchAgent label install.sh WRITES must also be torn down by it.
#
# WHY (2026-08-08, MUST-B partial)
# ---------------------------------------------------------------------------
# install.sh writes agents under TWO label domains -- com.creativemachines.ostler.*
# and com.ostler.* -- and removes them by naming each one explicitly. Nothing
# checked that the two lists agreed. They did not: 25 written, 23 removed.
#
# com.ostler.ollama-logrotate was found PRESENT and LOADED on the .208
# box-walk, on a machine that had been installed more than once. An agent that
# survives uninstall means a reinstall runs the old one alongside the new --
# two schedulers, same job, neither aware of the other. That is the shape that
# produced the duplicate-ingest incidents.
#
# The real cure is one label domain. That rename needs a launchd migration on
# every existing install, so it is deferred; this gate holds the line until
# then, and keeps holding it afterwards.
#
# EXIT CODES
#   0  every written label is torn down
#   1  at least one label is written and never removed
#   2  could not run (install.sh missing). NOT a pass.
#
# USAGE
#   tests/test_every_launchagent_is_torn_down.sh [path/to/install.sh]
#   tests/test_every_launchagent_is_torn_down.sh --self-test
# ---------------------------------------------------------------------------
set -uo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
[[ -n "${NO_COLOR:-}" ]] && { RED=""; GRN=""; YEL=""; OFF=""; }

cannot() { printf '%sUNAVAILABLE%s %s\n' "$YEL" "$OFF" "$*" >&2
           printf '  A gate that could not run is NOT a pass.\n' >&2; exit 2; }

# Labels that are deliberately never torn down by us, each with a reason.
# An unexplained entry here is how a real orphan gets waved through.
declare -a IGNORE_REASONS=(
  "homebrew.mxcl.ollama|installed by Homebrew, not by us; removed via brew uninstall"
)
_is_ignored() {
  local label="$1" entry
  for entry in "${IGNORE_REASONS[@]}"; do
    [[ "$label" == "${entry%%|*}" ]] && return 0
  done
  return 1
}

audit() {
  local sh="$1"
  [[ -f "$sh" ]] || cannot "no install.sh at: $sh"

  # WRITTEN: a label whose .plist path is the target of a redirect/creation.
  local written torn label
  written="$(grep -oE 'LaunchAgents/(com\.[a-z0-9.-]+)\.plist' "$sh" \
             | sed -E 's|LaunchAgents/||; s|\.plist$||' | sort -u)"

  # TORN DOWN: a label named on a bootout / unload / rm -f line, OR declared
  # in the uninstaller's OSTLER_LAUNCHAGENT_LABELS register. The register
  # replaced the two hand-maintained walls this gate was written against
  # (2026-08-15): its loop names labels via ${_label}, so the line-level
  # predicate below cannot see them and every label would read as an orphan.
  #
  # The register is a teardown declaration, not prose -- it is the array the
  # loop iterates. Only the array body is read, so a comment mentioning an
  # agent still cannot satisfy this gate.
  torn="$( { grep -hE 'launchctl[[:space:]]+(bootout|unload|disable)|rm[[:space:]]+-f.*LaunchAgents' "$sh" \
               | grep -oE 'com\.[a-z0-9.-]+'
             awk '/^OSTLER_LAUNCHAGENT_LABELS=\(/ {inreg=1; next} inreg && /^\)/ {inreg=0} inreg' "$sh" \
               | sed -e 's/[[:space:]]*#.*$//' | grep -oE 'com\.[a-z0-9.-]+'
           } | sed -E 's|\.plist$||' | sort -u)"

  local missing=0 checked=0
  while IFS= read -r label; do
    [[ -n "$label" ]] || continue
    _is_ignored "$label" && continue
    checked=$((checked+1))
    if ! printf '%s\n' "$torn" | grep -qxF "$label"; then
      printf '%s  ORPHAN%s %s -- written, never torn down\n' "$RED" "$OFF" "$label" >&2
      missing=$((missing+1))
    fi
  done <<< "$written"

  if (( missing > 0 )); then
    printf '\n%s%d of %d LaunchAgent label(s) survive uninstall.%s\n' "$RED" "$missing" "$checked" "$OFF" >&2
    printf 'A surviving agent means a reinstall runs the old one alongside the\n' >&2
    printf 'new: two schedulers, same job, neither aware of the other.\n' >&2
    return 1
  fi
  printf '%s  ok%s  all %d written LaunchAgent label(s) are torn down\n' "$GRN" "$OFF" "$checked"
  return 0
}

self_test() {
  # Prove the audit DISCRIMINATES: it must pass a balanced fixture and fail an
  # unbalanced one. A gate never observed failing is indistinguishable from a
  # gate that always passes.
  local tmp pass=0 total=0
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

  cat > "$tmp/balanced.sh" <<'EOF'
cat > "${HOME}/Library/LaunchAgents/com.ostler.alpha.plist" <<PL
PL
launchctl bootout "gui/501/com.ostler.alpha" || true
rm -f "${HOME}/Library/LaunchAgents/com.ostler.alpha.plist"
EOF

  cat > "$tmp/orphaned.sh" <<'EOF'
cat > "${HOME}/Library/LaunchAgents/com.ostler.alpha.plist" <<PL
PL
launchctl bootout "gui/501/com.ostler.alpha" || true
rm -f "${HOME}/Library/LaunchAgents/com.ostler.alpha.plist"
cat > "${HOME}/Library/LaunchAgents/com.ostler.orphan.plist" <<PL
PL
EOF

  total=$((total+1))
  if audit "$tmp/balanced.sh" >/dev/null 2>&1; then
    printf '  %sok%s   balanced fixture passes\n' "$GRN" "$OFF"; pass=$((pass+1))
  else
    printf '  %sBAD%s  balanced fixture FAILED -- gate is over-strict\n' "$RED" "$OFF"
  fi

  total=$((total+1))
  if audit "$tmp/orphaned.sh" >/dev/null 2>&1; then
    printf '  %sBAD%s  orphaned fixture PASSED -- gate detects nothing\n' "$RED" "$OFF"
  else
    printf '  %sok%s   orphaned fixture is caught\n' "$GRN" "$OFF"; pass=$((pass+1))
  fi

  # The register shape. Same two controls again, because a predicate that
  # only ever sees the wall shape would silently stop discriminating the day
  # the uninstaller was refactored -- which is exactly what happened here.
  cat > "$tmp/register_balanced.sh" <<'EOF'
cat > "${HOME}/Library/LaunchAgents/com.ostler.alpha.plist" <<PL
PL
OSTLER_LAUNCHAGENT_LABELS=(
    com.ostler.alpha
)
for _label in "${OSTLER_LAUNCHAGENT_LABELS[@]}"; do
    launchctl bootout "gui/$(id -u)/${_label}" || true
    rm -f "${HOME}/Library/LaunchAgents/${_label}.plist"
done
EOF

  cat > "$tmp/register_orphaned.sh" <<'EOF'
cat > "${HOME}/Library/LaunchAgents/com.ostler.alpha.plist" <<PL
PL
cat > "${HOME}/Library/LaunchAgents/com.ostler.orphan.plist" <<PL
PL
# com.ostler.orphan is mentioned here and nowhere else. A comment is not
# a teardown.
OSTLER_LAUNCHAGENT_LABELS=(
    com.ostler.alpha
)
for _label in "${OSTLER_LAUNCHAGENT_LABELS[@]}"; do
    launchctl bootout "gui/$(id -u)/${_label}" || true
    rm -f "${HOME}/Library/LaunchAgents/${_label}.plist"
done
EOF

  total=$((total+1))
  if audit "$tmp/register_balanced.sh" >/dev/null 2>&1; then
    printf '  %sok%s   register fixture passes\n' "$GRN" "$OFF"; pass=$((pass+1))
  else
    printf '  %sBAD%s  register fixture FAILED -- gate cannot read the label register\n' "$RED" "$OFF"
  fi

  total=$((total+1))
  if audit "$tmp/register_orphaned.sh" >/dev/null 2>&1; then
    printf '  %sBAD%s  register fixture with a comment-only label PASSED -- prose satisfies the gate\n' "$RED" "$OFF"
  else
    printf '  %sok%s   a label named only in a comment is still an orphan\n' "$GRN" "$OFF"; pass=$((pass+1))
  fi

  printf '\n'
  if (( pass == total )); then
    printf '%sself-test: %d/%d controls behave%s\n' "$GRN" "$pass" "$total" "$OFF"; return 0
  fi
  printf '%sself-test: only %d/%d behave -- gate cannot be trusted%s\n' "$RED" "$pass" "$total" "$OFF"
  return 1
}

main() {
  [[ "${1:-}" == "--self-test" ]] && { self_test; exit $?; }
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  audit "${1:-$here/install.sh}"
}

main "$@"
