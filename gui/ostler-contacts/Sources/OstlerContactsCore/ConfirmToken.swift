import Foundation
import CryptoKit

/// One-shot confirm-token derivation + verification (spec §4.2 step 5,
/// contract rule 3).
///
/// A merge MUST NOT run unless the caller presents a `--confirm-token` that
/// is bound to EXACTLY this (survivor, victims) group. The token is the
/// stable group hash: any drift in the chosen survivor or the victim set
/// produces a different token, so a token minted for one group cannot be
/// replayed against another. This is the same value as the spec's
/// `group_hash` ("sha256(sorted member ids + survivor)") so the daemon can
/// mint it and the helper can re-derive + compare it with no shared secret.
///
/// Pure / no TCC: this is plain hashing over identifier strings, so it is
/// fully unit-testable without a live CNContactStore.
public enum ConfirmToken {

    /// Canonicalise a group to its stable token.
    ///
    /// - The survivor id is pinned first (re-picking the survivor changes
    ///   the token, which is correct: a different survivor is a different
    ///   merge).
    /// - Victim ids are sorted so member ordering does not change the token.
    /// - Duplicate ids are collapsed so a caller cannot pad the set.
    public static func derive(survivorID: String, victimIDs: [String]) -> String {
        let cleanVictims = Set(victimIDs.filter { !$0.isEmpty }).sorted()
        // A survivor that also appears in the victim list is nonsensical and
        // must not be silently tolerated; callers validate that separately,
        // but the canonical form drops it so the hash cannot be gamed.
        let victimsWithoutSurvivor = cleanVictims.filter { $0 != survivorID }
        let canonical = "survivor=" + survivorID
            + "\nvictims=" + victimsWithoutSurvivor.joined(separator: ",")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time-ish comparison of a presented token against the freshly
    /// derived one for this group. Returns true only on an exact match.
    public static func verify(
        presented: String,
        survivorID: String,
        victimIDs: [String]
    ) -> Bool {
        let expected = derive(survivorID: survivorID, victimIDs: victimIDs)
        // Compare on UTF-8 bytes; both are fixed-length lowercase hex so a
        // simple length-then-bytes compare avoids a trivial timing leak.
        let a = Array(expected.utf8)
        let b = Array(presented.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
