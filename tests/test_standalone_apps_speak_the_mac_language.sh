#!/usr/bin/env bash
# tests/test_standalone_apps_speak_the_mac_language.sh
#
# L10N audit 2026-11-04: the Ostler Uninstaller app, the Recover Ostler app,
# the move-to-Applications alerts (SelfRelocator) and the log drawer's Copy
# button were English in every language: 21+ literals outside any catalogue.
# They now read ViewCopy (uninstaller.*, recovery_app.*, relocator.*,
# log_drawer.*) through the installer's own loader and language resolver,
# which project.yml compiles and bundles into both standalone apps.
#
# Two halves:
#   1. SWEEP: none of the old English literals is left in those sources.
#      Negative control first: the same sweep must find a planted literal.
#   2. CONSUMER: swiftc-compile the REAL ViewCopy.swift + InstallerLanguage.swift
#      with a small main and resolve every key of those four sections, from the
#      REAL catalogue files, for a Mac whose first language is each of the 13.
#      A prose string (three or more words) must not come back in English, and
#      no key may come back as itself. Control: English still resolves.
#
# Exit 0 PASS, 1 FAIL, 2 CANNOT-RUN (no swiftc). CANNOT-RUN is never a pass.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUI="${REPO_ROOT}/gui"
RES="${GUI}/OstlerInstaller/Resources"
cannot() { echo "CANNOT-RUN: $*" >&2; exit 2; }
fail=0

SOURCES=(
    "${GUI}/Uninstaller/ContentView.swift"
    "${GUI}/Uninstaller/UninstallerApp.swift"
    "${GUI}/Uninstaller/UninstallerCoordinator.swift"
    "${GUI}/Recovery/RecoveryRootView.swift"
    "${GUI}/Recovery/RecoveryApp.swift"
    "${GUI}/OstlerInstaller/Bootstrap/SelfRelocator.swift"
    "${GUI}/OstlerInstaller/Views/LogDrawerView.swift"
)
for f in "${SOURCES[@]}"; do [[ -r "$f" ]] || cannot "source not readable: $f"; done

# The literals the audit found, one per line (exact, case-sensitive).
OLD_LITERALS='"Uninstall Ostler"
Also delete the shared Docker VM
Also delete my imported knowledge data
"Uninstalling
Removing background services
Uninstall did not finish
Ostler has been removed
"Data stores"
kept for a reinstall
The uninstaller could not confirm consent
"Recover Ostler"
"Recovery key"
"Unlock my data"
Checking your recovery key
That key wasn
Couldn'"'"'t check your key
Move Ostler Installer to your Applications folder
"Move to Applications"
"Don'"'"'t Move"
An older Ostler Installer is already installed
Could not move Ostler Installer
"Copy log"
Copy the whole log buffer'

sweep() {  # sweep FILE... -> prints hits
    local lit
    while IFS= read -r lit; do
        [[ -z "$lit" ]] && continue
        # comment lines (// and ///) are not customer copy
        /usr/bin/grep -nHF -- "$lit" "$@" | /usr/bin/grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true
    done <<< "$OLD_LITERALS"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1a. negative control: the sweep sees a planted literal.
printf 'Text("Uninstall Ostler")\nalert.messageText = "Move Ostler Installer to your Applications folder?"\n' > "${WORK}/planted.swift"
planted="$(sweep "${WORK}/planted.swift" | wc -l | tr -d ' ')"
if [[ "$planted" -lt 2 ]]; then
    echo "FAIL: control: the sweep found ${planted} of 2 planted literals; it cannot see them" >&2
    fail=1
else
    echo "control ok: the sweep found ${planted} planted literals"
fi

# 1b. the real sources.
hits="$(sweep "${SOURCES[@]}")"
if [[ -n "$hits" ]]; then
    echo "FAIL: English literals left outside the catalogue:" >&2
    echo "$hits" >&2
    fail=1
else
    echo "sweep ok: 0 old literals in ${#SOURCES[@]} sources"
fi

# 2. consumer: resolve every key through the real loader for each language.
xcrun --find swiftc >/dev/null 2>&1 || cannot "swiftc not found in the active toolchain"
cat > "${WORK}/main.swift" <<'SWIFT'
import Foundation

let res = CommandLine.arguments[1]
func load(_ name: String) -> [String: Any] {
    let url = URL(fileURLWithPath: res).appendingPathComponent(name + ".json")
    guard let d = try? Data(contentsOf: url),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        print("FAIL: cannot read \(name).json"); exit(1)
    }
    return o
}
let sections = ["uninstaller", "recovery_app", "relocator", "log_drawer"]
let root = load("ViewCopy")
var keys: [String] = []
for s in sections {
    guard let sec = root[s] as? [String: Any] else { print("FAIL: ViewCopy.json lacks \(s)"); exit(1) }
    for k in sec.keys where !k.hasPrefix("_") { keys.append("\(s).\(k)") }
}
let english = ViewCopy(root: root, localized: [:])
func words(_ s: String) -> Int {
    s.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 2 && $0.allSatisfy { $0.isASCII } }.count
}
var bad = 0, examined = 0
for k in keys where english.string(for: k) == k { print("FAIL: en \(k) resolves to its key"); bad += 1 }
let macs: [(String, String)] = [
    ("de-DE", "de"), ("fr-FR", "fr"), ("es-ES", "es"), ("it-IT", "it"), ("nl-NL", "nl"),
    ("pt-BR", "pt-BR"), ("pt-PT", "pt-PT"), ("ja-JP", "ja"), ("ko-KR", "ko"),
    ("zh-Hans-CN", "zh-Hans"), ("zh-Hant-TW", "zh-Hant"), ("zh-Hant-HK", "zh-HK"), ("ar-AE", "ar"),
]
for (tag, want) in macs {
    // The language the apps pick on a Mac whose first language is `tag`.
    let lang = InstallerLanguage.resolve(preferred: [tag, "en-GB"], override: nil)
    guard lang == want, let name = InstallerLanguage.resourceName("ViewCopy", lang: lang) else {
        print("FAIL: a \(tag) Mac resolves to \(lang), want \(want)"); bad += 1; continue
    }
    let vc = ViewCopy(root: root, localized: load(name))
    for k in keys {
        examined += 1
        let v = vc.string(for: k), e = english.string(for: k)
        if v == k { print("FAIL: \(lang) \(k) resolves to its key"); bad += 1 }
        else if v == e && words(e) >= 3 { print("FAIL: \(lang) \(k) is still English: \(e)"); bad += 1 }
    }
    let filled = vc.string(for: "uninstaller.not_found_at", fills: ["path": "/tmp/x"])
    if !filled.contains("/tmp/x") || filled.contains("{path}") { print("FAIL: \(lang) not_found_at fill: \(filled)"); bad += 1 }
}
print("examined \(examined) key-language pairs (\(keys.count) keys x \(macs.count) languages); \(bad) failure(s)")
exit(bad == 0 && examined > 0 ? 0 : 1)
SWIFT
BIN="${WORK}/resolve"
if ! xcrun swiftc -O "${GUI}/OstlerInstaller/Steps/ViewCopy.swift" "${GUI}/OstlerInstaller/Steps/InstallerLanguage.swift" \
        "${WORK}/main.swift" -o "$BIN" 2>"${WORK}/cc.err"; then
    cat "${WORK}/cc.err" >&2
    cannot "swiftc could not compile ViewCopy.swift + InstallerLanguage.swift"
fi
if ! "$BIN" "$RES"; then
    fail=1
fi

if [[ "$fail" -ne 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
