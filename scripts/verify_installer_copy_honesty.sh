#!/usr/bin/env bash
# Installer customer copy must (1) not claim a log is "attached" when it is
# only copied to the clipboard, and (2) never send the customer to "support"
# without an address. hello@ostler.ai is the verified address; the older
# support@ostler.ai strings are tolerated here but not added to.
# rc=0 clean, rc=1 a line breaks the rule, rc=2 a surface is missing.
# Controls: scripts/tests/test_installer_copy_honesty.sh
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SURFACES=(gui/OstlerInstaller/Resources/ViewCopy.json gui/Recovery/RecoveryRootView.swift gui/OstlerInstaller/InstallerCoordinator.swift gui/OstlerInstaller/Views/DeviceLimitReachedView.swift install.sh)
rc=0
for s in "${SURFACES[@]}"; do
  [[ -f "$ROOT/$s" ]] || { echo "MISSING surface: $s"; rc=2; continue; }
done
[[ $rc -eq 2 ]] && exit 2
while IFS= read -r hit; do echo "FAIL attached-claim: $hit"; rc=1; done < <(/usr/bin/grep -nHi 'already attached' "$ROOT/${SURFACES[0]}")
for s in "${SURFACES[@]}"; do
  while IFS= read -r hit; do
    # a mention of support is only allowed if the same line carries the address
    case "$hit" in *hello@ostler.ai*|*support@ostler.ai*) continue;; esac
    echo "FAIL support-without-address: $s:$hit"; rc=1
  done < <(/usr/bin/grep -nEi '(ask|contact) (the )?support|and ask support' "$ROOT/$s")
done
[[ $rc -eq 0 ]] && echo "installer copy honesty: OK (${#SURFACES[@]} surfaces)"
exit $rc
