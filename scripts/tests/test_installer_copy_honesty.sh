#!/usr/bin/env bash
# Controls for verify_installer_copy_honesty.sh: clean tree passes (rc 0);
# each planted defect fails (rc 1); a missing surface is rc 2.
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
G="$R/scripts/verify_installer_copy_honesty.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
S=(gui/OstlerInstaller/Resources/ViewCopy.json gui/Recovery/RecoveryRootView.swift gui/OstlerInstaller/InstallerCoordinator.swift gui/OstlerInstaller/Views/DeviceLimitReachedView.swift install.sh)
fresh(){ rm -rf "$T/t"; for f in "${S[@]}"; do mkdir -p "$T/t/$(dirname "$f")"; cp "$R/$f" "$T/t/$f"; done; }
fail=0
chk(){ bash "$G" "$T/t" >/dev/null 2>&1; got=$?; [[ $got -eq $2 ]] && echo "ok   $1 (rc=$got)" || { echo "FAIL $1 want $2 got $got"; fail=1; }; }
fresh; chk "real tree clean" 0
fresh; echo '"x": "a log already attached"' >> "$T/t/${S[0]}"; chk "already attached" 1
fresh; echo 'echo "Contact support to fix"' >> "$T/t/install.sh"; chk "support without address" 1
fresh; echo 'x = "email hello@ostler.ai"' >> "$T/t/${S[2]}"; chk "second address" 1
fresh; rm "$T/t/install.sh"; chk "missing surface" 2
exit $fail
