#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_uninstaller_app_decoder_and_flags.sh
#
# Uninstaller.app has two pieces of pure logic that must be right or the app
# lies to the customer or hands the uninstaller the wrong flags:
#
#   ProgressProtocol.decode()   must turn each UNINSTALL_* #OSTLER marker into
#                               the matching InstallerEvent with the right
#                               fields (so the app renders what happened).
#   UninstallFlags.build()      must ALWAYS pass an explicit colima decision
#                               (never rely on --yes, which the uninstaller
#                               refuses as colima consent) and must only add
#                               --remove-colima / --purge-data when the box is
#                               ticked.
#
# Both are value types with no UI dependency, so this compiles just those two
# source files plus a test main with `swiftc` and runs the assertions -- the
# same approach tests/test_installer_output_buffer_is_bounded.sh uses.
#
# macOS + a Swift toolchain only. No toolchain -> CANNOT-RUN (exit 2), never a
# false pass.
#
# EXIT: 0 all assertions held; 1 an assertion failed; 2 could not run.
# ---------------------------------------------------------------------------
set -uo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; OFF=$'\033[0m'
[[ -n "${NO_COLOR:-}" ]] && { RED=""; GRN=""; YEL=""; OFF=""; }
cannot() { printf '%sCANNOT-RUN%s %s\n' "$YEL" "$OFF" "$*" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO="${REPO_ROOT}/gui/OstlerInstaller/ProgressProtocol.swift"
FLAGS="${REPO_ROOT}/gui/Uninstaller/UninstallFlags.swift"
[[ -r "$PROTO" ]] || cannot "ProgressProtocol.swift not readable at ${PROTO}"
[[ -r "$FLAGS" ]] || cannot "UninstallFlags.swift not readable at ${FLAGS}"
command -v xcrun >/dev/null 2>&1 || cannot "xcrun not found (needs a macOS Swift toolchain)"
xcrun --find swiftc >/dev/null 2>&1 || cannot "swiftc not found in the active toolchain"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

cat > "${WORK}/main.swift" <<'SWIFT'
import Foundation

var failures = 0
func check(_ cond: Bool, _ what: String) {
    if cond { print("  PASS  \(what)") }
    else { print("  FAIL  \(what)"); failures += 1 }
}

// ── decoder: each UNINSTALL_* marker decodes to the right event ────────────
func ev(_ s: String) -> InstallerEvent { ProgressDecoder.decode(line: s) }

if case let .uninstallConsent(value, source) =
    ev("#OSTLER\tUNINSTALL_CONSENT\tvalue=granted\tsource=flag") {
    check(value == "granted" && source == "flag", "UNINSTALL_CONSENT decodes value+source")
} else { check(false, "UNINSTALL_CONSENT decodes to .uninstallConsent") }

if case let .uninstallPhase(name, meta) =
    ev("#OSTLER\tUNINSTALL_PHASE\tname=knowledge_staging\toutcome=purged") {
    check(name == "knowledge_staging" && meta["outcome"] == "purged",
          "UNINSTALL_PHASE decodes name + carries outcome in metadata")
} else { check(false, "UNINSTALL_PHASE decodes to .uninstallPhase") }

if case let .uninstallColima(result) =
    ev("#OSTLER\tUNINSTALL_COLIMA\tresult=removed") {
    check(result == "removed", "UNINSTALL_COLIMA decodes result")
} else { check(false, "UNINSTALL_COLIMA decodes to .uninstallColima") }

if case let .uninstallDone(removed, content, staging, colima) =
    ev("#OSTLER\tUNINSTALL_DONE\tstores_removed=1\tcontent=keep\tknowledge_staging=preserved\tcolima=kept") {
    check(removed == true && content == "keep" && staging == "preserved" && colima == "kept",
          "UNINSTALL_DONE decodes all four fields")
} else { check(false, "UNINSTALL_DONE decodes to .uninstallDone") }

// stores_removed anything-but-1 must read as NOT removed (privacy-safe)
if case let .uninstallDone(removed, _, _, _) =
    ev("#OSTLER\tUNINSTALL_DONE\tstores_removed=0\tcontent=keep") {
    check(removed == false, "UNINSTALL_DONE stores_removed=0 -> false")
} else { check(false, "UNINSTALL_DONE (stores_removed=0) still decodes") }

// CONTROL: a marker the decoder does not know must NOT masquerade as one of ours
if case .unknown = ev("#OSTLER\tUNINSTALL_BOGUS\tx=y") {
    check(true, "CONTROL: an unknown UNINSTALL_* event decodes to .unknown, not a real case")
} else { check(false, "CONTROL: unknown event should be .unknown") }

// ── flag builder ──────────────────────────────────────────────────────────
func flags(_ o: UninstallOptions) -> [String] { UninstallFlags.build(o) }

let base = flags(UninstallOptions())
check(base.contains("--yes"), "build always passes --yes (GUI already consented)")
check(base.contains("--keep-colima") && !base.contains("--remove-colima"),
      "default: explicit --keep-colima, never --remove-colima")
check(base.contains("--keep-content"), "default: --keep-content")
check(!base.contains("--purge-data"), "default: no --purge-data")

var wantColima = UninstallOptions(); wantColima.removeColima = true
let fc = flags(wantColima)
check(fc.contains("--remove-colima") && !fc.contains("--keep-colima"),
      "removeColima ticked -> --remove-colima, not --keep-colima")

var wantPurge = UninstallOptions(); wantPurge.purgeKnowledgeData = true
check(flags(wantPurge).contains("--purge-data"), "purgeKnowledgeData ticked -> --purge-data")

// SAFETY: even with everything set, a colima decision is ALWAYS explicit, so
// the uninstaller never falls through to an (unanswerable) prompt.
for rc in [false, true] {
    var o = UninstallOptions(); o.removeColima = rc
    let f = flags(o)
    let hasColima = f.contains("--remove-colima") || f.contains("--keep-colima")
    check(hasColima, "SAFETY: an explicit colima flag is present when removeColima=\(rc)")
}

if failures == 0 { print("\nPASS: uninstaller decoder + flag builder"); exit(0) }
print("\nFAIL: \(failures) assertion(s)"); exit(1)
SWIFT

BIN="${WORK}/uninstaller_logic_test"
if ! xcrun swiftc -O "$PROTO" "$FLAGS" "${WORK}/main.swift" -o "$BIN" 2>"${WORK}/cc.err"; then
    echo "${RED}compile failed:${OFF}" >&2
    cat "${WORK}/cc.err" >&2
    cannot "swiftc could not compile the decoder + flag builder"
fi
"$BIN"
