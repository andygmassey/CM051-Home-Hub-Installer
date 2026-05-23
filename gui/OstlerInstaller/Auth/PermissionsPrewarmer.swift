// PermissionsPrewarmer.swift
//
// CX-14 Section E1 (2026-05-23). Mid-install auth pre-warm.
// CX-17 (2026-05-23). Sequenced requests + intro screen.
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
// CX-17 SECOND PROBLEM (Studio retest 2026-05-23): the first pass
// of the pre-warm fired all four requestAccess calls concurrently
// via async let. All four popups appeared and were processed in
// the SAME SECOND -- Andy did not see the Calendar / Photos popups
// at all in his retest. Either the system focus race made macOS
// auto-deny them, or the popups stacked and one click landed on
// the wrong dialog. Either way, the customer cannot read a popup
// they did not see, and a silent deny is exactly the failure shape
// E1 was meant to prevent.
//
// CX-17 FIX (this file): replace the concurrent async-let burst
// with a SERIAL loop. Request Contacts -> await -> 800ms gap ->
// Calendar -> await -> 800ms gap -> Reminders -> 800ms gap ->
// Photos. The delay gives macOS time to render each popup and
// gives the customer time to read + decide. The serial order is
// asserted in PermissionsPrewarmSequencingTest via a protocol-
// injected spy.
//
// CX-17 ALSO ADDS: an intro screen rendered BEFORE this code fires
// (see PermissionsIntroView). The intro tells the customer "four
// macOS dialogs are about to appear" with one-liner explanations
// of why each is needed, and a primary "Grant permissions" button
// that drives `prewarm()`. The Swift state machine for that lives
// in InstallerCoordinator -- this file does not know about the
// intro; the intro view calls into the coordinator which calls
// into this file.
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

/// One of the four permissions the pre-warmer requests. Used by the
/// `PermissionRequester` protocol so the sequencing test can identify
/// which request the spy received without reaching into framework
/// types.
enum PrewarmPermission: String, CaseIterable {
    case contacts
    case calendar
    case reminders
    case photos
}

/// Top-level state for the intro / pre-warm flow. Owned by
/// InstallerCoordinator so the App-level onAppear can advance it.
/// Lives in this file (not in PermissionsIntroView.swift) so the
/// coordinator can reference it without depending on the view
/// module compile order.
///
/// State machine:
///   .intro          -> intro screen visible, awaiting customer click
///   .requesting     -> "Grant permissions" tapped, prewarm() in flight
///   .summary        -> pre-warm done with one or more denials; show
///                      summary screen with Continue button
///   .complete       -> all granted OR customer acknowledged summary;
///                      flow falls through to licence + install gates
///   .skipped        -> customer tapped "Skip for now"; same downstream
///                      effect as .complete but logged differently
enum PermissionsIntroState: Equatable {
    case intro
    case requesting
    case summary(denials: [PrewarmPermission])
    case complete
    case skipped
}

/// Protocol-injected request driver. Production uses
/// `SystemPermissionRequester` which calls the real macOS TCC APIs;
/// tests inject a spy that records the order + timing of calls and
/// returns canned results.
@MainActor
protocol PermissionRequester {
    /// Returns `true` if the user granted the permission, `false` on
    /// any non-granted outcome (deny, restricted, limited, error).
    func request(_ permission: PrewarmPermission) async -> Bool
}

/// Production driver. Wraps the four framework requestAccess APIs.
@MainActor
final class SystemPermissionRequester: PermissionRequester {
    func request(_ permission: PrewarmPermission) async -> Bool {
        switch permission {
        case .contacts:  return await requestContactsAccess()
        case .calendar:  return await requestCalendarAccess()
        case .reminders: return await requestRemindersAccess()
        case .photos:    return await requestPhotosAccess()
        }
    }

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

@MainActor
final class PermissionsPrewarmer {
    /// Log-line emitter. Wired to InstallerCoordinator.appendLog so
    /// the LogDrawer surfaces the per-permission outcomes. Tests
    /// inject a capturing closure.
    typealias LogLineEmitter = @MainActor (_ level: String, _ msg: String) -> Void

    /// Result of a single permission request. Captured per-permission
    /// so InstallerCoordinator can surface a one-line denial summary
    /// BEFORE the install starts (CX-17 brief: "Better UX for
    /// denials"). The view layer reads these via
    /// `InstallerCoordinator.permissionsPrewarmResults`.
    struct Result: Equatable {
        let permission: PrewarmPermission
        let granted: Bool
    }

    /// Production-default gap between requests. Tests override via
    /// `init(gapMillis:)` to drive the spy without sleeping in real
    /// time. The 800ms figure was picked to be long enough that
    /// macOS finishes rendering the previous TCC popup before the
    /// next request fires (300-500ms in observed practice on macOS
    /// 14 + 15) while staying fast enough that the customer doesn't
    /// perceive a hang between dialogs.
    /// nonisolated so it is reachable from the non-isolated init
    /// default value (Swift's @MainActor class infects every member
    /// with main-actor isolation unless explicitly nonisolated).
    nonisolated static let defaultGapMillis: UInt64 = 800

    /// Canonical order. Drives both the production sequencing and
    /// the spy-order assertion in PermissionsPrewarmSequencingTest.
    /// Defined here as a single source of truth so a future re-order
    /// (or addition) only edits this constant + the test stays
    /// honest. Contacts first because it is the broadest TCC scope
    /// and customers expect it from any productivity app; Photos
    /// last because it is the least-load-bearing for the v1 install.
    /// nonisolated so PermissionsIntroView's iteration of the order
    /// stays main-actor cheap (no detour through the isolation
    /// boundary).
    nonisolated static let requestOrder: [PrewarmPermission] = [
        .contacts,
        .calendar,
        .reminders,
        .photos,
    ]

    private let emitLog: LogLineEmitter
    private let requester: PermissionRequester
    private let gapMillis: UInt64

    /// Convenience init with production defaults. Marked @MainActor
    /// because `SystemPermissionRequester()` is @MainActor-isolated
    /// (it wraps CNContactStore / EKEventStore / PHPhotoLibrary
    /// which are best touched on the main actor). Tests use the
    /// designated init below + inject their own spy + gap so they
    /// can run from any isolation context.
    @MainActor
    convenience init(emitLog: @escaping LogLineEmitter) {
        self.init(
            emitLog: emitLog,
            requester: SystemPermissionRequester(),
            gapMillis: PermissionsPrewarmer.defaultGapMillis
        )
    }

    /// Designated init. Non-isolated so the sequencing test can
    /// build a prewarmer from a non-main context with a stub
    /// requester. Tests must supply BOTH `requester` and
    /// `gapMillis` -- the latter is also non-isolated.
    init(
        emitLog: @escaping LogLineEmitter,
        requester: PermissionRequester,
        gapMillis: UInt64
    ) {
        self.emitLog = emitLog
        self.requester = requester
        self.gapMillis = gapMillis
    }

    /// Fire the four permission requests SERIALLY with an 800ms gap
    /// between each (configurable for tests). The serial loop is the
    /// CX-17 fix for the concurrent-burst regression: macOS rendered
    /// all four popups in the same second and Andy missed two of
    /// them on his Studio retest. Each request returns a Bool; we
    /// log per-permission outcomes but do NOT block install on any
    /// single denial -- install.sh has its own fallback paths for
    /// missing TCC grants (e.g. contacts pipeline skips with a warn
    /// if Contacts is denied).
    ///
    /// Returns the per-permission results so InstallerCoordinator
    /// can surface a one-line denial summary BEFORE the install
    /// starts (rather than burying the deny inside the LogDrawer).
    @discardableResult
    func prewarm() async -> [Result] {
        emitLog("info", ViewCopy.shared.string(for: "permissions_prewarm.starting"))

        var results: [Result] = []
        results.reserveCapacity(Self.requestOrder.count)

        for (idx, permission) in Self.requestOrder.enumerated() {
            // Gap BETWEEN requests, not before the first one. The
            // first popup should appear as fast as possible after
            // the customer clicks Grant permissions on the intro.
            if idx > 0 {
                let nanos = gapMillis * 1_000_000
                try? await Task.sleep(nanoseconds: nanos)
            }
            let granted = await requester.request(permission)
            results.append(Result(permission: permission, granted: granted))
            logResult(permission: permission, granted: granted)
        }

        emitLog("info", ViewCopy.shared.string(for: "permissions_prewarm.finished"))
        return results
    }

    private func logResult(permission: PrewarmPermission, granted: Bool) {
        let key = grantedKey(for: permission, granted: granted)
        // info, not warn: a deny is a customer choice, not a
        // failure. The Hub falls back to skip-on-deny everywhere.
        emitLog("info", ViewCopy.shared.string(for: key))
    }

    private func grantedKey(for permission: PrewarmPermission, granted: Bool) -> String {
        let suffix = granted ? "granted" : "denied"
        return "permissions_prewarm.\(permission.rawValue)_\(suffix)"
    }
}
