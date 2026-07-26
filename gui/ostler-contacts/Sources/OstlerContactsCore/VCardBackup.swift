import Foundation
import Contacts

/// vCard (de)serialisation wrappers around `CNContactVCardSerialization`
/// (spec §3).
///
/// Serialising an in-memory `[CNContact]` does NOT require Contacts
/// authorisation — only *fetching* from `CNContactStore` does. So this
/// layer is unit-testable against synthetic `CNMutableContact` fixtures,
/// which is how the test target exercises it without a TCC prompt.
///
/// NOTE (boundary): this file is read/serialise ONLY. There is no
/// CNSaveRequest, no `.update`, no `.delete`, no mutation of the live
/// store anywhere in this package. That destructive half lands in a later
/// PR (spec §9 item 3).
public enum VCardBackup {

    /// The vCard keys we serialise. `CNContactVCardSerialization` requires
    /// the contacts to have been fetched with these keys available; the
    /// executable target fetches with exactly this descriptor.
    public static var vcardKeys: [CNKeyDescriptor] {
        [CNContactVCardSerialization.descriptorForRequiredKeys()]
    }

    /// Serialise contacts to vCard bytes.
    public static func serialise(_ contacts: [CNContact]) throws -> Data {
        try CNContactVCardSerialization.data(with: contacts)
    }

    /// Parse vCard bytes back into contacts. Used by the round-trip
    /// integrity check — a backup that cannot be read back is not a backup
    /// (spec §3).
    public static func parse(_ data: Data) throws -> [CNContact] {
        try CNContactVCardSerialization.contacts(with: data)
    }

    /// Verify a freshly-written backup: it must be non-empty AND parse back
    /// into at least as many contacts as we serialised. Returns the
    /// parsed-back count so callers can log it.
    ///
    /// Returns `.ok(count)` or a `.failed(reason)` — never throws on a
    /// "bad backup", because the caller wants to *refuse to proceed*, not
    /// crash.
    public static func verifyRoundTrip(
        data: Data,
        expectedCount: Int
    ) -> RoundTripResult {
        guard !data.isEmpty else {
            return .failed("backup vCard is empty (0 bytes)")
        }
        let parsed: [CNContact]
        do {
            parsed = try parse(data)
        } catch {
            return .failed("backup vCard does not parse back: \(error)")
        }
        guard !parsed.isEmpty else {
            return .failed("backup vCard parsed back to 0 contacts")
        }
        // vCard serialisation is lossless on count for unified contacts;
        // a smaller parse-back means corruption.
        guard parsed.count >= expectedCount else {
            return .failed(
                "backup vCard parsed back \(parsed.count) contacts, "
                + "expected at least \(expectedCount)")
        }
        return .ok(parsed.count)
    }

    public enum RoundTripResult: Equatable {
        case ok(Int)
        case failed(String)

        public var isOK: Bool {
            if case .ok = self { return true }
            return false
        }
    }
}
