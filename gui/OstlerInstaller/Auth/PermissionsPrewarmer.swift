// PermissionsPrewarmer.swift
//
// CX-14 Section E1 (2026-05-23). Mid-install auth pre-warm.
//
// PROBLEM (Studio retest #5 + #6, 2026-05-21 + 22): macOS surfaces
// TCC prompts (Contacts, Calendar, Reminders, Photos) the first time
// a process touches the relevant framework. During Ostler install
// these touches are scattered across install.sh phases that run 5
// to 15 minutes after the customer started clicking. The customer
// has often walked away by then ("you can walk away after Q17"
// reassurance copy explicitly tells them they can). They come back
// to a paused install waiting on a TCC dialog they did not notice,
// or worse, a silently-denied prompt that timed out.
//
// FIX (option (a) from the brief): request all four permissions in
// a concerted burst from the OstlerInstaller process at app launch,
// BEFORE install.sh spawns. macOS shows the dialogs up-front while
// the customer is still attentive at the welcome screen. install.sh
// then inherits the resulting TCC state (Ostler's Hub agents read
// the same on-disk databases via the customer's user-level grants).
//
// CROSS-REF: this also closes C4 (TCC subprocess attribution). The
// install.sh subprocess is spawned via Process from this same .app
// bundle; when the customer has already granted Contacts/Calendar/
// Reminders/Photos to OstlerInstaller, the subprocess inherits that
// grant via parent-bundle attribution. (FDA is separate -- it has
// no requestAccess API and is granted manually via System Settings
// through the existing FullDiskAccessSheet flow.)
//
// FRAMEWORKS USED + AVAILABILITY (locked memory
// feedback_check_framework_availability_before_dispatch -- probed
// against the macOS 14.0 deployment target):
//   - Contacts.framework:   CNContactStore.requestAccess
//                           (macOS 10.11+; available)
//   - EventKit.framework:   EKEventStore.requestFullAccessToEvents
//                           + requestFullAccessToReminders
//                           (macOS 14.0+; available at deployment
//                           target)
//   - Photos.framework:     PHPhotoLibrary.requestAuthorization
//                           (macOS 10.13+; .readWrite available
//                           macOS 11.0+; available)
//
// NOT INCLUDED:
//   - Mail-FDA: there is no TCC requestAccess API for Full Disk
//     Access. FDA is granted manually via System Settings. The
//     existing FullDiskAccessSheet handles that flow.
//   - AppleEvents (System Events / Mail / Messages): pre-warmed
//     implicitly by AuthorizationHelper at the admin gate; not in
//     the customer-walked-away window.
//
// LOCKED MEMORY: feedback_customer_strings_extractable_from_day_one
// -- every log line emitted here reads from ViewCopy.permissions_prewarm
// rather than being inlined.

import Foundation
import Contacts
import EventKit
import Photos

@MainActor
final class PermissionsPrewarmer {
    /// Log-line emitter. Wired to InstallerCoordinator.appendLog so
    /// the LogDrawer surfaces the per-permission outcomes. Tests
    /// inject a capturing closure.
    typealias LogLineEmitter = @MainActor (_ level: String, _ msg: String) -> Void

    private let emitLog: LogLineEmitter

    init(emitLog: @escaping LogLineEmitter) {
        self.emitLog = emitLog
    }

    /// Fire the four permission requests concurrently. Each one is
    /// independent (no ordering required) and each returns a Bool.
    /// We log per-permission outcomes but do NOT block install on
    /// any single denial -- install.sh has its own fallback paths
    /// for missing TCC grants (e.g. contacts pipeline skips with a
    /// warn if Contacts is denied).
    ///
    /// Returns when all four requests have completed (granted or
    /// denied). Caller (InstallerCoordinator) awaits this before
    /// proceeding to verifyExistingLicenseOnLaunch().
    func prewarm() async {
        emitLog("info", ViewCopy.shared.string(for: "permissions_prewarm.starting"))

        // Run all four requests concurrently. async-let gives us a
        // single-task fan-out that joins at the suspension below.
        async let contactsGranted = requestContactsAccess()
        async let calendarGranted = requestCalendarAccess()
        async let remindersGranted = requestRemindersAccess()
        async let photosGranted = requestPhotosAccess()

        let (c, cal, r, p) = await (contactsGranted, calendarGranted, remindersGranted, photosGranted)

        log(granted: c,
            grantedKey: "permissions_prewarm.contacts_granted",
            deniedKey: "permissions_prewarm.contacts_denied")
        log(granted: cal,
            grantedKey: "permissions_prewarm.calendar_granted",
            deniedKey: "permissions_prewarm.calendar_denied")
        log(granted: r,
            grantedKey: "permissions_prewarm.reminders_granted",
            deniedKey: "permissions_prewarm.reminders_denied")
        log(granted: p,
            grantedKey: "permissions_prewarm.photos_granted",
            deniedKey: "permissions_prewarm.photos_denied")

        emitLog("info", ViewCopy.shared.string(for: "permissions_prewarm.finished"))
    }

    private func log(granted: Bool, grantedKey: String, deniedKey: String) {
        if granted {
            emitLog("info", ViewCopy.shared.string(for: grantedKey))
        } else {
            // info, not warn: a deny is a customer choice, not a
            // failure. The Hub falls back to skip-on-deny everywhere.
            emitLog("info", ViewCopy.shared.string(for: deniedKey))
        }
    }

    // MARK: - Per-framework requestAccess wrappers

    /// Wraps the CNContactStore completion-handler API in an async
    /// continuation. Returns granted == true on user-allow; false on
    /// deny, restricted, or error.
    private func requestContactsAccess() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let store = CNContactStore()
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// EventKit requestFullAccessToEvents is the macOS 14+ API. It
    /// replaces the deprecated requestAccess(to:.event). Returns
    /// granted == true on user-allow; false on deny or error.
    private func requestCalendarAccess() async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    /// EventKit requestFullAccessToReminders is the macOS 14+ API.
    private func requestRemindersAccess() async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    /// Photos requestAuthorization(for:.readWrite) returns a status
    /// enum; .authorized is the only granted outcome. .limited is
    /// counted as denied here because the install pipeline reads
    /// EXIF metadata across the full library; partial-grant is a
    /// post-launch v1.0.1 surface.
    private func requestPhotosAccess() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
