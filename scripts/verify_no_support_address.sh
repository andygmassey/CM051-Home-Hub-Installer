#!/usr/bin/env bash
# Customer-facing files must not carry support@ostler.ai or
# support@creativemachines.ai: only hello@, contact@ and feedback@ @ostler.ai
# are verified, so a support@ address points a customer at a dead inbox.
# rc=0 clean, rc=1 a file carries one, rc=2 a surface is missing.
# Controls: scripts/tests/test_no_support_address.sh
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SURFACES=(gui/OstlerInstaller/Resources/ViewCopy.json gui/OstlerInstaller/InstallerCoordinator.swift gui/OstlerInstaller/Views/ContentView.swift gui/OstlerInstaller/Views/DeviceLimitReachedView.swift gui/Recovery/RecoveryRootView.swift install.sh install.sh.strings.en-GB.sh vendor/doctor/agent/web_ui.py vendor/doctor/agent/.env.example)
rc=0
for s in "${SURFACES[@]}"; do
  [[ -f "$ROOT/$s" ]] || { echo "MISSING surface: $s"; rc=2; }
done
[[ $rc -eq 2 ]] && exit 2
for s in "${SURFACES[@]}"; do
  while IFS= read -r hit; do echo "FAIL support-address: $s:$hit"; rc=1; done < <(/usr/bin/grep -nE 'support@(ostler\.ai|creativemachines\.ai)' "$ROOT/$s")
done
[[ $rc -eq 0 ]] && echo "no support@ address: OK (${#SURFACES[@]} surfaces)"
exit $rc
