// PermissionsPrewarmer.swift
//
// CX-14 Section E1 (2026-05-23). Mid-install auth pre-warm.
// CX-17 (2026-05-23). Sequenced requests + intro screen.
// CX-18 (2026-05-23). Pre-check authorization status + AppleEvent
// Contacts pre-warm.
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
// CX-17 FIX: replace the concurrent async-let burst with a SERIAL
// loop. Request Contacts -> await -> 800ms gap -> Calendar -> await
// -> 800ms gap -> Reminders -> 800ms gap -> Photos. The delay gives
// macOS time to render each popup and gives the customer time to
// read + decide. The serial order is asserted in
// PermissionsPrewarmSequencingTest via a protocol-injected spy.
//
// CX-18 THIRD PROBLEM (Studio retest #13, 2026-05-23): the founder
// clicked "Grant permissions", saw ONLY the Reminders prompt fire,
// the installer then claimed Contacts/Calendar/Photos were denied,
// and LATER (when install.sh ran osascript to read the contact
// card) TWO Contacts prompts fired -- the white-icon TCC "Access
// to Contacts" AND the blue-icon AppleEvent "wants to control
// Contacts". So the founder got a denied-for-no-reason intro then
// got bombarded with prompts the intro should have pre-warmed.
//
// CX-18 FIX (this file): two changes.
//   1) PRE-CHECK each permission's current authorization status
//      via the framework's authorizationStatus API. If macOS has
//      already decided (granted, denied, restricted), the
//      requestAccess call returns the cached value WITHOUT
//      rendering a popup. We log the cached outcome rather than
//      calling requestAccess at all, which means the serial loop
//      ONLY pauses on permissions that actually need a customer
//      decision. On a fresh Mac Studio install with no prior TCC
//      record, all four prompts fire in sequence; on a Mac with
//      stale grants from a prior install, the loop short-circuits
//      and the customer sees only the unsettled prompts (in
//      sequence). This kills the "Reminders fires but the other
//      three silently came back denied" failure shape.
//   2) Add an AppleEvent CONTACTS probe BEFORE the TCC pre-warm
//      loop. install.sh's contact-card auto-detect uses osascript
//      `tell application "Contacts"` which triggers the SEPARATE
//      AppleEvent automation TCC scope. Without the probe, the
//      customer gets the white-icon TCC prompt during the intro
//      but the blue-icon AppleEvent prompt mid-install. The probe
//      fires a no-op AppleScript that triggers the blue-icon
//      prompt up-front so all Contacts-related prompts cluster at
//      the same point in the flow.
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
import AppKit       // NSAppleScript (CX-18 AppleEvent Contacts probe)
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
///
/// CX-18 (2026-05-23): each request method now PRE-CHECKS the
/// current authorisation status. If macOS has already decided
/// (granted, denied, restricted), the request short-circuits and
/// returns the cached outcome immediately rather than going into
/// requestAccess (which would also return the cached outcome but
/// after a brief opaque pause that reads as "popup that did not
/// render"). This keeps the serial-loop semantics honest: the loop
/// only PAUSES on permissions that actually need a customer
/// decision, so the founder sees the prompts one at a time in
/// canonical order and never a "denied for no reason" silent skip.
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
    /// deny, restricted, or error. CX-18: short-circuits on cached
    /// .authorized / .denied / .restricted to avoid the "silent
    /// pause then denied" failure shape from Studio retest #13.
    private func requestContactsAccess() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: break
        @unknown default: break
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let store = CNContactStore()
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// EventKit requestFullAccessToEvents is the macOS 14+ API. It
    /// replaces the deprecated requestAccess(to:.event). Returns
    /// granted == true on user-allow; false on deny or error. CX-18:
    /// pre-checks authorizationStatus(for:.event) so a cached deny
    /// does not slip past as an opaque "popup did not fire" outcome.
    private func requestCalendarAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        // EKAuthorizationStatus on macOS 14+: .notDetermined,
        // .restricted, .denied, .fullAccess, .writeOnly, and the
        // deprecated .authorized (still a case for backwards-compat
        // with apps built against earlier SDKs). Treat .authorized
        // as fullAccess so a legacy grant short-circuits cleanly.
        switch status {
        case .fullAccess, .authorized: return true
        case .denied, .restricted: return false
        case .writeOnly:
            // writeOnly is a partial grant on macOS 14+; the install
            // pipeline needs read access (briefs, link-to-events on
            // the wiki) so we treat it as denied for now. Post-launch
            // v1.0.1 may surface a softer message here.
            return false
        case .notDetermined: break
        @unknown default: break
        }
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    /// EventKit requestFullAccessToReminders is the macOS 14+ API.
    /// CX-18: pre-check + short-circuit identical to calendar above.
    private func requestRemindersAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess: return true
        case .denied, .restricted: return false
        case .writeOnly: return false
        case .notDetermined: break
        @unknown default: break
        }
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
    /// post-launch v1.0.1 surface. CX-18: pre-check + short-circuit.
    private func requestPhotosAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized: return true
        case .denied, .restricted, .limited: return false
        case .notDetermined: break
        @unknown default: break
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

/// CX-18 (2026-05-23). AppleEvent Contacts pre-warm probe.
///
/// install.sh's contact-card auto-detect (around install.sh:1060)
/// uses osascript `tell application "Contacts"` which triggers the
/// SEPARATE AppleEvent automation TCC scope ("OstlerInstaller wants
/// to access to control Contacts", blue icon) on top of the regular
/// CNContact TCC scope ("Access to Contacts", white icon) that
/// CNContactStore.requestAccess handles. Without an up-front probe,
/// the customer hits both prompts -- the TCC one during the intro,
/// the AppleEvent one mid-install when they have walked away.
///
/// This probe runs a no-op AppleScript that asks Contacts for its
/// person count. The script does NOT need a real result (we
/// discard the output + any error); the side effect is that macOS
/// renders the AppleEvent permission prompt at pre-warm time, so
/// the blue-icon dialog stacks with the four TCC dialogs at a
/// predictable moment in the install flow.
///
/// Idempotent: macOS short-circuits the AppleEvent prompt once
/// the customer has answered once. A re-launch of the installer
/// will not re-prompt unless the customer has reset privacy
/// settings.
///
/// Returns true if the AppleScript executed without an error
/// (which means the customer either granted, or the prompt is
/// pending). false means scripting was actively denied. We log
/// the outcome but do NOT fail the install on false -- install.sh
/// has its own MSG_WARN_MACOS_CONTACTS_PERMISSION_WAS_DECLINED
/// fallback that surfaces a cleaner message at the point of use.
@MainActor
enum AppleEventContactsProbe {
    static func probe() -> Bool {
        // The no-op script. `count of every person` is the cheapest
        // read that still requires the AppleEvent permission to be
        // granted -- a `tell application "Contacts"` alone does not
        // trigger the prompt; a property access is required.
        let source = "tell application \"Contacts\" to count of every person"
        guard let script = NSAppleScript(source: source) else { return false }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        // If errorInfo is nil, scripting succeeded (granted, or
        // running on a Mac with Contacts open + accessible). If
        // errorInfo has a -1743 (errAEEventNotPermitted) the
        // customer denied; we surface that as false. Other error
        // codes (Contacts.app launch failure, etc.) are treated as
        // false too -- the install can continue without the
        // AppleEvent grant; install.sh degrades the contact-card
        // auto-detect step gracefully.
        return errorInfo == nil
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

        // CX-18 (2026-05-23): fire the AppleEvent Contacts probe
        // FIRST. install.sh's contact-card auto-detect uses
        // osascript `tell application "Contacts"` which triggers
        // the separate AppleEvent automation TCC scope on top of
        // the regular CNContact TCC scope. Without the probe the
        // customer hits the AppleEvent prompt mid-install when
        // they have walked away. The probe runs the same no-op
        // AppleScript install.sh would later run, so the customer
        // sees the blue-icon prompt at pre-warm time and the
        // install can complete without surprise mid-flight popups.
        //
        // We probe BEFORE the TCC sequence (not interleaved) so
        // the AppleEvent prompt and the TCC Contacts prompt do
        // not stack on top of each other. macOS handles
        // AppleEvent prompts on the main thread; spinning it up
        // first lets the runloop settle before the TCC popup
        // sequence begins.
        if Self.appleEventContactsProbeEnabled {
            let probeOk = AppleEventContactsProbe.probe()
            let key = probeOk
                ? "permissions_prewarm.applescript_contacts_granted"
                : "permissions_prewarm.applescript_contacts_denied"
            emitLog("info", ViewCopy.shared.string(for: key))
        }

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

    /// CX-18 test seam. Production fires the AppleEvent Contacts
    /// probe at the top of prewarm(); the sequencing test disables
    /// it so the test does not pop a real macOS prompt during
    /// xcodebuild test runs. Toggle is a static so the test can
    /// flip it via `PermissionsPrewarmer.appleEventContactsProbeEnabled = false`
    /// in setUp + restore in tearDown.
    static var appleEventContactsProbeEnabled: Bool = true

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
