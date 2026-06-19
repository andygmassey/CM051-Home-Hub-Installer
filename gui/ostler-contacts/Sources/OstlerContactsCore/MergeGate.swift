import Foundation

/// Pure precondition gate for a merge request (spec §7 / contract rules 3 +
/// 4). Combines the feature flag and the confirm-token check into a single
/// decision so the executable's write path has exactly one place to refuse,
/// and so the refusal logic is unit-testable without TCC.
///
/// Every failure mode maps to a distinct, non-zero exit reason so the
/// daemon (and tests) can tell WHY a write was refused.
public enum MergeGate {

    public enum Decision: Equatable {
        case allow
        case refuseFlagOff
        case refuseNoVictims
        case refuseSurvivorInVictims
        case refuseBadToken

        public var isAllowed: Bool { self == .allow }

        /// A short, stable message + a distinct non-zero exit code for each
        /// refusal (rule: refuse with a clear nonzero exit + message).
        public var message: String {
            switch self {
            case .allow:
                return "ok"
            case .refuseFlagOff:
                return "Tidy Contacts is OFF. Refusing to write. "
                    + "Set OSTLER_TIDY_CONTACTS_ENABLED=true to enable (default is off)."
            case .refuseNoVictims:
                return "no victims supplied; a merge needs a survivor and at least one victim."
            case .refuseSurvivorInVictims:
                return "the survivor id also appears in the victim list; refusing."
            case .refuseBadToken:
                return "missing or invalid --confirm-token for this exact group. "
                    + "Refusing to write."
            }
        }

        public var exitCode: Int32 {
            switch self {
            case .allow: return 0
            case .refuseFlagOff: return 10
            case .refuseNoVictims: return 11
            case .refuseSurvivorInVictims: return 12
            case .refuseBadToken: return 13
            }
        }
    }

    /// Evaluate the gate. Order matters: flag first (cheapest + the headline
    /// safety property), then structural sanity, then the cryptographic
    /// token bound to THIS exact group.
    public static func evaluate(
        flagEnabled: Bool,
        survivorID: String,
        victimIDs: [String],
        presentedToken: String?
    ) -> Decision {
        guard flagEnabled else { return .refuseFlagOff }

        let cleanVictims = victimIDs.filter { !$0.isEmpty }
        guard !cleanVictims.isEmpty else { return .refuseNoVictims }
        guard !cleanVictims.contains(survivorID) else { return .refuseSurvivorInVictims }

        guard let token = presentedToken, !token.isEmpty else { return .refuseBadToken }
        guard ConfirmToken.verify(
            presented: token, survivorID: survivorID, victimIDs: cleanVictims)
        else { return .refuseBadToken }

        return .allow
    }
}
