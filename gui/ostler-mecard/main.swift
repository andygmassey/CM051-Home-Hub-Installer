// ostler-mecard — read the operator's macOS "me card" for install-time pre-fill.
//
// Why this exists (BW2-1, box-walk recut #2, 2026-07-25)
// -----------------------------------------------------
// install.sh used to read the me-card with AppleScript:
//     osascript -e 'tell application "Contacts" ... my card ...'
// On macOS 26.5 the `my card` AppleEvent broke (-1728, "can't get my
// card"), so the pre-fill silently produced nothing on the .185 box-walk:
// blank name/country defaults, an empty wiki title, empty self-handles.
//
// This helper replaces that read with a framework call that is stable
// across macOS versions. It is bundled INSIDE OstlerInstaller.app and
// signed with the app's Developer ID + hardened runtime, so when
// install.sh (a grandchild of the app) invokes it, the read is attributed
// to the app as the TCC "responsible process" and inherits the Contacts
// grant the installer's permission pre-warm already obtained — no second
// consent prompt, no Contacts.app launch race.
//
// Why AddressBook and not Contacts (CNContactStore)
// -------------------------------------------------
// The modern Contacts framework deliberately does NOT expose a usable
// Swift me-card API: `-[CNContactStore unifiedMeContactWithKeysToFetch:
// error:]` exists in the ObjC headers but the Swift importer drops it
// (verified: `CNContactStore has no member 'unifiedMeContact'` on the
// macOS 26 SDK). AddressBook's `-[ABAddressBook me]` is the only framework
// API that returns the "My Card" record, it imports cleanly into Swift,
// and it was verified reading the correct card on macOS 26. It is marked
// deprecated (since 10.11) but remains fully functional; if a future macOS
// ever removes it, install.sh's own osascript read is still the outer
// fallback.
//
// Output contract (one line on stdout), matching install.sh's `cut -d'|'`:
//     name|first|country|email|phone
// Any field may be empty. Exit 0 when a me-card was found (even partial);
// exit 1 with no output when there is no me-card / no read access, so
// install.sh's `[[ -n "$CARD_DATA" ]]` guard falls back cleanly.
//
// The bundle carries its own NSContactsUsageDescription (embedded via
// `-sectcreate __TEXT __info_plist` at build time) as belt-and-braces: if
// this ever ran before the app had a grant it would prompt with a sane
// string rather than crash the hardened-runtime process.

import Foundation
import AddressBook

// Collapse anything that could break the 5-field `|`-delimited contract
// install.sh parses with `cut`. Pipes become slashes; newlines/CRs/tabs
// become spaces; surrounding whitespace is trimmed.
private func clean(_ s: String) -> String {
    return s
        .replacingOccurrences(of: "|", with: "/")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// First value of an ABMultiValue property as a String, or "".
private func firstValue(_ person: ABRecord, _ property: String) -> String {
    guard let multi = person.value(forProperty: property) as? ABMultiValue,
          multi.count() > 0 else {
        return ""
    }
    return (multi.value(at: 0) as? String) ?? ""
}

// Country from the first postal address dictionary, or "".
private func firstCountry(_ person: ABRecord) -> String {
    guard let multi = person.value(forProperty: kABAddressProperty) as? ABMultiValue,
          multi.count() > 0,
          let dict = multi.value(at: 0) as? [String: Any],
          let country = dict[kABAddressCountryKey] as? String else {
        return ""
    }
    return country
}

// ── Read ────────────────────────────────────────────────────────────
guard let book = ABAddressBook.shared() else {
    // No addressbook available (e.g. read access denied → nil book).
    exit(1)
}
guard let me = book.me() else {
    // "My Card" was never set.
    exit(1)
}

let first = (me.value(forProperty: kABFirstNameProperty) as? String) ?? ""
let last = (me.value(forProperty: kABLastNameProperty) as? String) ?? ""
let name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")

// A card is "found" only if it yielded a name — install.sh keys the whole
// pre-fill off DETECTED_NAME, and an all-empty line is worse than no line
// (it would suppress the osascript fallback for nothing).
if name.isEmpty && first.isEmpty {
    exit(1)
}

let country = firstCountry(me)
let email = firstValue(me, kABEmailProperty)
let phone = firstValue(me, kABPhoneProperty)

print("\(clean(name))|\(clean(first))|\(clean(country))|\(clean(email))|\(clean(phone))")
exit(0)
