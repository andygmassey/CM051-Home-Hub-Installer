// swift-tools-version:5.9
//
// ostler-contacts — native macOS CNContact helper (Big Win BW-A).
//
// STEP 1 OF N: read + vCard backup ONLY. There is deliberately NO write
// path in this package yet — no CNSaveRequest, no delete, no field-union,
// no merge. See BIG_WINS_BW-A_apply_spec.md §9 build order (item 1) and the
// PR body for the explicit boundary.
//
// Why a standalone SwiftPM executable (and not a target inside the
// OstlerInstaller xcodegen project): the spec (§2.3) wants "a thin,
// auditable, single-purpose binary" — keeping the Contacts-writer surface
// small and reviewable is itself a safety property. A dedicated package
// makes the write surface a separately-signed, separately-reviewable
// artefact, and lets the pure path/serialisation logic be unit-tested in
// OstlerContactsCore without a live CNContactStore / TCC prompt.
//
// The binary is signed with the addressbook entitlement
// (com.apple.security.personal-information.addressbook) and shipped in the
// DMG. The entitlement + NSContactsUsageDescription already exist in
// gui/project.yml / OstlerInstaller.entitlements; see Entitlements/.
import PackageDescription

let package = Package(
    name: "ostler-contacts",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Pure, framework-light logic that is testable without TCC:
        // backup directory/path derivation, manifest construction,
        // timestamp formatting. CNContactVCardSerialization itself does
        // not require Contacts authorisation to *serialise* an in-memory
        // array of contacts, so the serialisation round-trip is testable
        // here against synthetic CNContact fixtures.
        .target(
            name: "OstlerContactsCore"
        ),
        // Thin CLI entry point: argument parsing + live CNContactStore
        // reads. Kept deliberately small.
        .executableTarget(
            name: "ostler-contacts",
            dependencies: ["OstlerContactsCore"]
        ),
        .testTarget(
            name: "OstlerContactsCoreTests",
            dependencies: ["OstlerContactsCore"]
        ),
    ]
)
