// UninstallFlags.swift
//
// The pure, testable core of Uninstaller.app: turn the two GUI checkboxes into
// the exact argument vector handed to ~/.ostler/bin/ostler-uninstall.
//
// WHY EVERY DECISION IS PASSED EXPLICITLY
// ---------------------------------------------------------------------------
// The app runs the uninstaller with stdin detached (a windowed app has no
// tty), so the uninstaller MUST NOT reach an interactive prompt. Two of its
// decisions would otherwise prompt: the keep-content question and the colima
// question. We therefore always pass a content flag AND a colima flag, so no
// prompt is ever reached.
//
// 🔴 --yes IS NOT COLIMA CONSENT. The uninstaller deliberately refuses to read
// --yes as permission to delete the SHARED colima `default` VM, because that VM
// may hold Docker data that predates Ostler. So the checkbox state is passed as
// its OWN flag (--remove-colima / --keep-colima); --yes only covers the ordinary
// Ostler teardown. If the user did not tick "delete the VM", we pass
// --keep-colima, never merely omit it.

import Foundation

/// The two choices the confirm screen offers, plus the always-safe content
/// default. Content is kept unless a future screen offers to remove it; the
/// uninstaller's own default is also keep, so this matches it.
struct UninstallOptions: Equatable {
    var removeColima: Bool = false
    var purgeKnowledgeData: Bool = false
    /// ~/Documents/Ostler (generated wiki, transcripts). Kept by default; the
    /// minimal confirm screen does not offer to remove it, so this stays false.
    var removeUserContent: Bool = false
}

enum UninstallFlags {
    /// Build the argument vector. Order is stable so it is trivially testable.
    static func build(_ o: UninstallOptions) -> [String] {
        var args: [String] = []
        // The GUI's confirm click IS the consent for the ordinary teardown.
        args.append("--yes")
        // Content decision, always explicit so no prompt is reached.
        args.append(o.removeUserContent ? "--remove-content" : "--keep-content")
        // Colima decision, always explicit. --keep-colima when unticked so the
        // intent is unambiguous and --yes is never mistaken for VM consent.
        args.append(o.removeColima ? "--remove-colima" : "--keep-colima")
        // Knowledge-staging purge is opt-in; only add it when ticked.
        if o.purgeKnowledgeData {
            args.append("--purge-data")
        }
        return args
    }
}
