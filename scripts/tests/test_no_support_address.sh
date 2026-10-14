#!/usr/bin/env bash
# Controls for verify_no_support_address.sh: clean tree rc 0; each planted
# defect rc 1; a missing surface rc 2.
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
G="$R/scripts/verify_no_support_address.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
S=(gui/OstlerInstaller/Resources/ViewCopy.json gui/OstlerInstaller/InstallerCoordinator.swift gui/OstlerInstaller/Views/ContentView.swift gui/OstlerInstaller/Views/DeviceLimitReachedView.swift gui/Recovery/RecoveryRootView.swift install.sh install.sh.strings.en-GB.sh vendor/doctor/agent/web_ui.py vendor/doctor/agent/.env.example)
fresh(){ rm -rf "$T/t"; for f in "${S[@]}"; do mkdir -p "$T/t/$(dirname "$f")"; cp "$R/$f" "$T/t/$f"; done; }
fail=0
chk(){ bash "$G" "$T/t" >/dev/null 2>&1; got=$?; [[ $got -eq $2 ]] && echo "ok   $1 (rc=$got)" || { echo "FAIL $1 want $2 got $got"; fail=1; }; }
fresh; chk "real tree clean" 0
fresh; echo 'x = "support@ostler.ai"' >> "$T/t/${S[0]}"; chk "support@ostler.ai in copy" 1
fresh; echo 'echo "mail support@ostler.ai"' >> "$T/t/install.sh"; chk "support@ostler.ai in install.sh" 1
fresh; echo 'X = "support@creativemachines.ai"' >> "$T/t/vendor/doctor/agent/web_ui.py"; chk "creativemachines support@" 1
fresh; rm "$T/t/install.sh"; chk "missing surface" 2
exit $fail
