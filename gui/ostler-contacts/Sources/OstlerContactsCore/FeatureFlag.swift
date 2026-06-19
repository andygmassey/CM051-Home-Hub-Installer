import Foundation

/// Feature-flag plumbing for Tidy Contacts (spec §7).
///
/// `OSTLER_TIDY_CONTACTS_ENABLED` defaults to `false` everywhere. In a
/// later PR the *write* subcommands (`merge`) hard-refuse unless this is
/// `true`. In THIS PR there is no write path, so the flag is defined and
/// surfaced for completeness/diagnostics but does NOT gate `backup` or
/// `list` — both are pure reads and harmless regardless of the flag.
public enum FeatureFlag {
    public static let envName = "OSTLER_TIDY_CONTACTS_ENABLED"

    /// True only when the env var is explicitly a truthy value.
    /// Anything else (unset, empty, "false", "0", "no") is OFF.
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[envName]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return raw == "true" || raw == "1" || raw == "yes"
    }
}
