import Foundation
import Contacts

/// Conservative, lossless-toward-survivor field union (spec §2.2).
///
/// This is the heart of the destructive feature, and it is deliberately
/// PURE: it takes an in-memory survivor `CNContact` plus victim
/// `CNContact`s and returns a `CNMutableContact` (the union) plus a record
/// of what was added and what conflicted. It never touches CNContactStore,
/// so the whole union policy is unit-testable against synthetic contacts
/// with no TCC prompt. The executable target fetches the live contacts and
/// hands them here; the only thing that needs Contacts authorisation is the
/// fetch + the eventual CNSaveRequest, NOT this logic.
///
/// LOSSLESS TOWARD SURVIVOR (the contract, spec §2.2):
///   * Never drop a survivor value. Only add.
///   * Multi-value fields (phones, emails, postal addresses, URLs, social
///     profiles, IM, dates) are unioned; identical labelled values are
///     de-duplicated so we do not produce two identical rows.
///   * The survivor photo is kept unless it is empty AND a victim has one.
///   * Conflicting SINGLE-value fields (given/family name, organisation,
///     birthday, note ...) keep the survivor's value; the victim's differing
///     value is surfaced as a `Conflict` ("kept A, discarded B") and NEVER
///     silently overwritten.
public enum FieldUnion {

    /// A single-value field where survivor and a victim disagreed. The
    /// survivor's value is kept; the discarded victim value is surfaced so
    /// the UI/output can show "kept A, discarded B" at confirm time.
    public struct Conflict: Equatable, Codable {
        public let field: String
        public let kept: String
        public let discarded: String
        public init(field: String, kept: String, discarded: String) {
            self.field = field
            self.kept = kept
            self.discarded = discarded
        }
    }

    /// A multi-value value that the union added from a victim (it was not
    /// already present on the survivor).
    public struct Addition: Equatable, Codable {
        public let field: String
        public let value: String
        public init(field: String, value: String) {
            self.field = field
            self.value = value
        }
    }

    /// The result of unioning victims into a survivor.
    public struct Result {
        /// The merged contact, ready to feed to a CNSaveRequest `.update`.
        public let merged: CNMutableContact
        /// Single-value fields where the survivor won and a victim value was
        /// discarded (surfaced, never silently dropped).
        public let conflicts: [Conflict]
        /// Multi-value values pulled in from victims.
        public let additions: [Addition]
    }

    /// Union all `victims` into a mutable copy of `survivor`.
    ///
    /// The survivor is copied via `mutableCopy()` so the caller's object is
    /// never mutated in place. The returned `merged` carries the survivor's
    /// identifier, which is what `CNSaveRequest.update` requires.
    public static func union(
        survivor: CNContact,
        victims: [CNContact]
    ) -> Result {
        // mutableCopy preserves the identifier (essential for .update()).
        guard let merged = survivor.mutableCopy() as? CNMutableContact else {
            // Defensive: CNContact.mutableCopy always yields a
            // CNMutableContact in practice. If it ever does not, we still
            // must not silently produce a contact missing the survivor's
            // data, so we crash loudly rather than return a half-built one.
            fatalError("CNContact.mutableCopy() did not yield CNMutableContact")
        }

        var conflicts: [Conflict] = []
        var additions: [Addition] = []

        for victim in victims {
            // ---- multi-value fields: union, de-dup identical labelled rows
            mergeLabelledPhones(into: merged, from: victim, additions: &additions)
            mergeLabelledEmails(into: merged, from: victim, additions: &additions)
            mergeLabelledPostal(into: merged, from: victim, additions: &additions)
            mergeLabelledURLs(into: merged, from: victim, additions: &additions)
            mergeLabelledIM(into: merged, from: victim, additions: &additions)
            mergeSocialProfiles(into: merged, from: victim, additions: &additions)
            mergeLabelledDates(into: merged, from: victim, additions: &additions)

            // ---- photo: keep survivor's unless empty and victim has one
            mergePhoto(into: merged, from: victim, additions: &additions)

            // ---- single-value fields: survivor wins, surface the discard
            mergeSingleValue(
                field: "givenName",
                survivorValue: merged.givenName,
                victimValue: victim.givenName,
                set: { merged.givenName = $0 },
                conflicts: &conflicts, additions: &additions)
            mergeSingleValue(
                field: "familyName",
                survivorValue: merged.familyName,
                victimValue: victim.familyName,
                set: { merged.familyName = $0 },
                conflicts: &conflicts, additions: &additions)
            mergeSingleValue(
                field: "middleName",
                survivorValue: merged.middleName,
                victimValue: victim.middleName,
                set: { merged.middleName = $0 },
                conflicts: &conflicts, additions: &additions)
            mergeSingleValue(
                field: "namePrefix",
                survivorValue: merged.namePrefix,
                victimValue: victim.namePrefix,
                set: { merged.namePrefix = $0 },
                conflicts: &conflicts, additions: &additions)
            mergeSingleValue(
                field: "nameSuffix",
                survivorValue: merged.nameSuffix,
                victimValue: victim.nameSuffix,
                set: { merged.nameSuffix = $0 },
                conflicts: &conflicts, additions: &additions)
            mergeSingleValue(
                field: "nickname",
                survivorValue: merged.nickname,
                victimValue: victim.nickname,
                set: { merged.nickname = $0 },
                conflicts: &conflicts, additions: &additions)
            mergeSingleValue(
                field: "organizationName",
                survivorValue: merged.organizationName,
                victimValue: victim.organizationName,
                set: { merged.organizationName = $0 },
                conflicts: &conflicts, additions: &additions)
            mergeSingleValue(
                field: "departmentName",
                survivorValue: merged.departmentName,
                victimValue: victim.departmentName,
                set: { merged.departmentName = $0 },
                conflicts: &conflicts, additions: &additions)
            mergeSingleValue(
                field: "jobTitle",
                survivorValue: merged.jobTitle,
                victimValue: victim.jobTitle,
                set: { merged.jobTitle = $0 },
                conflicts: &conflicts, additions: &additions)
            mergeSingleValue(
                field: "note",
                survivorValue: merged.note,
                victimValue: victim.note,
                set: { merged.note = $0 },
                conflicts: &conflicts, additions: &additions)

            // Birthday is a DateComponents single-value field.
            mergeBirthday(into: merged, from: victim,
                          conflicts: &conflicts, additions: &additions)
        }

        return Result(merged: merged, conflicts: conflicts, additions: additions)
    }

    // MARK: - single-value helper

    /// Survivor wins. If the survivor field is empty and the victim has a
    /// value, ADD it (lossless toward survivor: filling a blank is an add,
    /// not an overwrite). If both have differing non-empty values, keep the
    /// survivor's and record the discard.
    private static func mergeSingleValue(
        field: String,
        survivorValue: String,
        victimValue: String,
        set: (String) -> Void,
        conflicts: inout [Conflict],
        additions: inout [Addition]
    ) {
        let v = victimValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        let s = survivorValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty {
            set(victimValue)
            additions.append(Addition(field: field, value: victimValue))
        } else if s != v {
            conflicts.append(Conflict(field: field, kept: survivorValue, discarded: victimValue))
        }
        // s == v: identical, nothing to do.
    }

    // MARK: - multi-value helpers
    //
    // Each appends victim values not already present (by normalised value +
    // label) onto the survivor's existing array, preserving the survivor's
    // order first. We compare on a normalised key so "+44 7700 900111" and
    // "+447700900111" with the same label do not produce a duplicate row,
    // while genuinely different values are kept.

    private static func mergeLabelledPhones(
        into merged: CNMutableContact,
        from victim: CNContact,
        additions: inout [Addition]
    ) {
        var existing = merged.phoneNumbers
        var seen = Set(existing.map {
            key(label: $0.label, value: normalisePhone($0.value.stringValue))
        })
        for lv in victim.phoneNumbers {
            let k = key(label: lv.label, value: normalisePhone(lv.value.stringValue))
            if !seen.contains(k) {
                existing.append(lv)
                seen.insert(k)
                additions.append(Addition(field: "phone", value: lv.value.stringValue))
            }
        }
        merged.phoneNumbers = existing
    }

    private static func mergeLabelledEmails(
        into merged: CNMutableContact,
        from victim: CNContact,
        additions: inout [Addition]
    ) {
        var existing = merged.emailAddresses
        var seen = Set(existing.map {
            key(label: $0.label, value: ($0.value as String).lowercased())
        })
        for lv in victim.emailAddresses {
            let k = key(label: lv.label, value: (lv.value as String).lowercased())
            if !seen.contains(k) {
                existing.append(lv)
                seen.insert(k)
                additions.append(Addition(field: "email", value: lv.value as String))
            }
        }
        merged.emailAddresses = existing
    }

    private static func mergeLabelledPostal(
        into merged: CNMutableContact,
        from victim: CNContact,
        additions: inout [Addition]
    ) {
        var existing = merged.postalAddresses
        var seen = Set(existing.map { key(label: $0.label, value: postalKey($0.value)) })
        for lv in victim.postalAddresses {
            let k = key(label: lv.label, value: postalKey(lv.value))
            if !seen.contains(k) {
                existing.append(lv)
                seen.insert(k)
                additions.append(Addition(field: "postalAddress", value: postalKey(lv.value)))
            }
        }
        merged.postalAddresses = existing
    }

    private static func mergeLabelledURLs(
        into merged: CNMutableContact,
        from victim: CNContact,
        additions: inout [Addition]
    ) {
        var existing = merged.urlAddresses
        var seen = Set(existing.map {
            key(label: $0.label, value: ($0.value as String).lowercased())
        })
        for lv in victim.urlAddresses {
            let k = key(label: lv.label, value: (lv.value as String).lowercased())
            if !seen.contains(k) {
                existing.append(lv)
                seen.insert(k)
                additions.append(Addition(field: "url", value: lv.value as String))
            }
        }
        merged.urlAddresses = existing
    }

    private static func mergeLabelledIM(
        into merged: CNMutableContact,
        from victim: CNContact,
        additions: inout [Addition]
    ) {
        var existing = merged.instantMessageAddresses
        var seen = Set(existing.map {
            key(label: $0.label,
                value: ($0.value.service + ":" + $0.value.username).lowercased())
        })
        for lv in victim.instantMessageAddresses {
            let k = key(label: lv.label,
                        value: (lv.value.service + ":" + lv.value.username).lowercased())
            if !seen.contains(k) {
                existing.append(lv)
                seen.insert(k)
                additions.append(Addition(field: "instantMessage", value: lv.value.username))
            }
        }
        merged.instantMessageAddresses = existing
    }

    private static func mergeSocialProfiles(
        into merged: CNMutableContact,
        from victim: CNContact,
        additions: inout [Addition]
    ) {
        var existing = merged.socialProfiles
        var seen = Set(existing.map {
            key(label: $0.label,
                value: ($0.value.service + ":" + $0.value.username).lowercased())
        })
        for lv in victim.socialProfiles {
            let k = key(label: lv.label,
                        value: (lv.value.service + ":" + lv.value.username).lowercased())
            if !seen.contains(k) {
                existing.append(lv)
                seen.insert(k)
                additions.append(Addition(field: "socialProfile", value: lv.value.username))
            }
        }
        merged.socialProfiles = existing
    }

    private static func mergeLabelledDates(
        into merged: CNMutableContact,
        from victim: CNContact,
        additions: inout [Addition]
    ) {
        var existing = merged.dates
        var seen = Set(existing.map { key(label: $0.label, value: dateKey($0.value)) })
        for lv in victim.dates {
            let k = key(label: lv.label, value: dateKey(lv.value))
            if !seen.contains(k) {
                existing.append(lv)
                seen.insert(k)
                additions.append(Addition(field: "date", value: dateKey(lv.value)))
            }
        }
        merged.dates = existing
    }

    private static func mergePhoto(
        into merged: CNMutableContact,
        from victim: CNContact,
        additions: inout [Addition]
    ) {
        // Keep survivor's photo unless it is empty and a victim has one.
        let survivorHasPhoto = (merged.imageData?.isEmpty == false)
        guard !survivorHasPhoto else { return }
        if let victimImage = victim.imageData, !victimImage.isEmpty {
            merged.imageData = victimImage
            additions.append(Addition(field: "photo", value: "<image \(victimImage.count) bytes>"))
        }
    }

    private static func mergeBirthday(
        into merged: CNMutableContact,
        from victim: CNContact,
        conflicts: inout [Conflict],
        additions: inout [Addition]
    ) {
        guard let vb = victim.birthday, vb.day != nil || vb.month != nil else { return }
        if let sb = merged.birthday, sb.day != nil || sb.month != nil {
            if !sameDateComponents(sb, vb) {
                conflicts.append(Conflict(
                    field: "birthday",
                    kept: birthdayString(sb),
                    discarded: birthdayString(vb)))
            }
        } else {
            merged.birthday = vb
            additions.append(Addition(field: "birthday", value: birthdayString(vb)))
        }
    }

    // MARK: - normalisation / key helpers

    private static func key(label: String?, value: String) -> String {
        (CNLabeledValue<NSString>.localizedString(forLabel: label ?? "")) + "\u{1F}" + value
    }

    /// Phone equality is by digits only (ignoring spaces, dashes, parens) so
    /// label-equal numbers that differ only in formatting de-dupe.
    private static func normalisePhone(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { CharacterSet(charactersIn: "+0123456789").contains($0) }
        return String(String.UnicodeScalarView(kept))
    }

    private static func postalKey(_ a: CNPostalAddress) -> String {
        [a.street, a.subLocality, a.city, a.subAdministrativeArea,
         a.state, a.postalCode, a.country, a.isoCountryCode]
            .joined(separator: "|")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dateKey(_ c: DateComponents) -> String {
        "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// `CNContact.dates` is labelled with `NSDateComponents`; bridge it.
    private static func dateKey(_ c: NSDateComponents) -> String {
        dateKey(c as DateComponents)
    }

    private static func sameDateComponents(_ a: DateComponents, _ b: DateComponents) -> Bool {
        a.year == b.year && a.month == b.month && a.day == b.day
    }

    private static func birthdayString(_ c: DateComponents) -> String {
        dateKey(c)
    }
}
