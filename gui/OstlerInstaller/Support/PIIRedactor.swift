// PIIRedactor.swift
//
// Pure synchronous `String -> String` transform that strips
// personal data out of a buffer before the customer sends it
// to support@ostler.ai. Used by the failure banner's
// "Email support" + "Copy redacted log" buttons.
//
// Rules (locked 2026-05-21):
//
//   Redacted to `[redacted-email]`
//     - Email addresses (alice@example.com, alice.bob+tag@example.co.uk)
//
//   Redacted to `[redacted-phone]`
//     - E.164 numbers (+447700900000, +12025551234)
//     - UK 07xx and 020 / 0207 / 0117 etc. forms
//     - US-style (555) 123-4567 or 555-123-4567
//     - Hong Kong 8-digit local (eight digits, common forms)
//
//   Redacted to `[redacted-name]`
//     - Display names passed in via `names:` (e.g. the answer to
//       the "what is your name?" onboarding prompt).
//     - The active user's POSIX login name (`NSUserName()`).
//
//   `/Users/<u>/` → `/Users/[user]/`
//     - Except `Shared` and `Guest`, which are install-time
//       hard-coded paths and not PII.
//
//   IPs → `[redacted-ip]`
//     - IPv4 globally-routable + RFC1918 + CGNAT
//     - IPv6 globally-routable
//     - Leave loopback (127.0.0.0/8 + ::1), link-local
//       (169.254.0.0/16 + fe80::/10) and multicast
//       (224.0.0.0/4 + ff00::/8) intact, plus 0.0.0.0
//       because they all carry diagnostic signal value and
//       are not PII.
//
//   LEAVE INTACT
//     - Paths under /Applications, /System, /Library, /usr,
//       /opt, /private (other than /private/var/folders/...
//       which can leak DARWIN_USER_DIR hash), /tmp.
//     - Function names, stack trace frames, error codes.
//     - Hex digests (sha256, ed25519 sig prefixes).
//     - UUID-shaped strings (licence IDs).
//
// IMPORTANT: this transform is best-effort. The Copy log (raw)
// button is the escape hatch when a customer's bug needs the
// untouched buffer.

import Foundation

struct PIIRedactor {

    /// Names to redact verbatim. Typically supplied from the
    /// `answerHistory` of the installer coordinator, picking out
    /// any answer whose prompt id matches `user_name` / `name`.
    /// Empty + whitespace-only entries are dropped.
    let names: [String]

    /// POSIX login name. Defaults to `NSUserName()` so callers
    /// don't have to look it up themselves. Tests inject a fixed
    /// string so the result is deterministic.
    let loginName: String

    // MARK: - Public entry point

    /// Redact a single string. Safe to call on multi-line input.
    func redact(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var s = input
        // ORDER MATTERS:
        //   1. Emails first (their `@` would otherwise be re-matched
        //      as the start of nothing in particular, but the local
        //      part can contain a `.` that the IP regex might catch
        //      on pathological inputs).
        //   2. URL-form paths next so /Users/<u>/ is anonymised
        //      BEFORE any name regex has a chance to chew it.
        //   3. IPs before phones because some phone regexes accept
        //      digit-dot-digit patterns that could touch v4.
        //   4. Phones before names because a name regex would never
        //      hit digits.
        //   5. Names last.
        s = Self.redactEmails(s)
        s = Self.redactUsersPath(s)
        s = Self.redactIPv6(s)
        s = Self.redactIPv4(s)
        s = Self.redactPhones(s)
        s = Self.redactNames(s, names: namesToRedact)
        return s
    }

    /// Convenience overload that redacts a `[String]` line-by-line.
    /// Lets callers like the LogDrawerView's `formatBuffer` walk
    /// per-line without re-allocating the whole buffer first.
    func redactLines(_ lines: [String]) -> [String] {
        lines.map(redact(_:))
    }

    // MARK: - Init

    init(names: [String] = [], loginName: String = NSUserName()) {
        self.names = names
        self.loginName = loginName
    }

    // MARK: - Patterns

    // Email: deliberately permissive on the local part (RFC 5322 is
    // huge; the support buffer's failure mode is "missed a real
    // email", not "redacted a non-email").
    private static let emailRegex: NSRegularExpression = {
        let pattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,24}"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static func redactEmails(_ s: String) -> String {
        return emailRegex.stringByReplacingMatches(
            in: s,
            options: [],
            range: NSRange(s.startIndex..., in: s),
            withTemplate: "[redacted-email]"
        )
    }

    // /Users/<u>/ -> /Users/[user]/ EXCEPT /Users/Shared/ and
    // /Users/Guest/, which are install-time fixtures, not PII.
    private static let usersPathRegex: NSRegularExpression = {
        // Match `/Users/<segment>/` where segment is alphanumeric
        // plus dot/underscore/hyphen. The trailing slash is part of
        // the match so a bare `/Users/alice` (no trailing slash)
        // also matches; we put a word-boundary on the end via the
        // class so `/Users/alice.config` does not greedily eat the
        // dot-suffix.
        let pattern = #"/Users/([A-Za-z0-9_.\-]+)(/|\b)"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static func redactUsersPath(_ s: String) -> String {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = usersPathRegex.matches(in: s, options: [], range: range)
        guard !matches.isEmpty else { return s }
        var out = ""
        var cursor = 0
        for m in matches {
            let segRange = m.range(at: 1)
            let seg = ns.substring(with: segRange)
            let trailingRange = m.range(at: 2)
            let trailing = trailingRange.location == NSNotFound ? "" : ns.substring(with: trailingRange)
            // Allowlist: Shared + Guest are install-time fixtures, not PII.
            if seg == "Shared" || seg == "Guest" {
                let chunk = ns.substring(with: NSRange(location: cursor, length: m.range.location + m.range.length - cursor))
                out += chunk
                cursor = m.range.location + m.range.length
                continue
            }
            // Append unchanged content before this match, then the
            // anonymised replacement.
            let pre = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += pre
            out += "/Users/[user]" + trailing
            cursor = m.range.location + m.range.length
        }
        // Tail.
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    // IPv4: classic dotted-quad. We let the regex match anything
    // looking like one then post-filter to leave loopback /
    // link-local / multicast / 0.0.0.0 intact.
    private static let ipv4Regex: NSRegularExpression = {
        let pattern = #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static func redactIPv4(_ s: String) -> String {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = ipv4Regex.matches(in: s, options: [], range: range)
        guard !matches.isEmpty else { return s }
        var out = ""
        var cursor = 0
        for m in matches {
            let pre = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += pre
            let v = ns.substring(with: m.range)
            if shouldKeepIPv4(v) {
                out += v
            } else {
                out += "[redacted-ip]"
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    private static func shouldKeepIPv4(_ v: String) -> Bool {
        // Parse the four octets; if anything is malformed, keep the
        // string as-is (it wasn't a real IP).
        let parts = v.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 >= 0 && $0 <= 255 }) else {
            return true
        }
        let a = parts[0]
        let b = parts[1]
        // Loopback 127.0.0.0/8
        if a == 127 { return true }
        // 0.0.0.0/8 (unspecified + diagnostic)
        if a == 0 { return true }
        // Link-local 169.254.0.0/16
        if a == 169 && b == 254 { return true }
        // Multicast 224.0.0.0/4
        if a >= 224 && a <= 239 { return true }
        // Broadcast 255.255.255.255 (treated as diagnostic)
        if a == 255 && b == 255 && parts[2] == 255 && parts[3] == 255 { return true }
        return false
    }

    // IPv6: catch long-form, double-colon-compressed form, and
    // mixed forms. The regex is permissive (run of hex digits, dots
    // and colons containing at least one `::` or two `:`); the
    // post-filter rejects non-IPv6-shaped matches and preserves
    // loopback (::1) and link-local (fe80::/10) intact.
    private static let ipv6Regex: NSRegularExpression = {
        let pattern = #"(?<![0-9A-Za-z:])[0-9A-Fa-f:]+[0-9A-Fa-f]+(?![0-9A-Za-z])"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static func redactIPv6(_ s: String) -> String {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = ipv6Regex.matches(in: s, options: [], range: range)
        guard !matches.isEmpty else { return s }
        var out = ""
        var cursor = 0
        for m in matches {
            let pre = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let v = ns.substring(with: m.range)
            out += pre
            if isIPv6Shaped(v) {
                let lower = v.lowercased()
                if lower == "::1" || lower.hasPrefix("fe80:") || lower.hasPrefix("ff") {
                    out += v  // diagnostic, not PII
                } else {
                    out += "[redacted-ip]"
                }
            } else {
                out += v  // not actually an IPv6, leave alone
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return out
    }

    /// Whether the match string is genuinely IPv6-shaped: contains
    /// `::` OR contains at least two `:` characters and only colon-
    /// separated hex groups. Filters out hex tokens (`abcdef`) and
    /// single-colon-separated tokens (function:line) that the loose
    /// regex would otherwise net.
    private static func isIPv6Shaped(_ v: String) -> Bool {
        if !v.contains(":") { return false }
        // `::1` and shorthand `::` forms are obviously IPv6-shaped.
        if v.contains("::") { return true }
        // Otherwise need at least two `:` separators, all groups
        // 1-4 hex digits, none empty (apart from the `::` form
        // already handled).
        let groups = v.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.count >= 3 else { return false }
        for g in groups {
            if g.isEmpty { return false }
            if g.count > 4 { return false }
            // All chars in g must be hex.
            for ch in g {
                if !ch.isHexDigit { return false }
            }
        }
        return true
    }

    // Phone numbers, run as a single combined alternation so
    // overlapping patterns (E.164 starting with `+` vs UK `07...`)
    // don't double-match. Each branch carries its own anchors.
    //
    //   E.164:   +<countrycode-1-3 digits><7-12 digits>
    //   UK local: 0(7|2)\d{8,9}  or  0\d{10}   (catches 020, 0117, 07xx)
    //   US-ish:  (555) 123-4567 or 555-123-4567 or 555.123.4567
    //   HK 8-digit: \b[5-9]\d{7}\b
    private static let phoneRegex: NSRegularExpression = {
        let alternatives = [
            // E.164 + a leading delimiter to avoid matching
            // file-system paths like /tmp/+aborts:42.
            #"(?<![A-Za-z0-9])\+[1-9][0-9]{1,3}[0-9 \-]{6,14}[0-9]"#,
            // UK local, anchored on word boundary
            #"(?<![A-Za-z0-9])0(?:7\d{9}|2\d{9}|1\d{9,10}|800\d{6,7})"#,
            // US (555) 123-4567 / 555-123-4567 / 555.123.4567
            #"(?<![A-Za-z0-9])\(?\d{3}\)?[\s\-.]\d{3}[\s\-.]\d{4}\b"#,
            // HK 8-digit local mobile (5xxx / 6xxx / 9xxx). 7/8-prefix
            // also covers virtual + landline. Word-boundary both sides
            // so 12345678 (HK) matches but `100000000` (random number)
            // does not on the 9-digit length check.
            #"(?<![A-Za-z0-9])[5-9]\d{3}[\s\-]?\d{4}(?![A-Za-z0-9])"#,
        ]
        let combined = "(?:" + alternatives.joined(separator: "|") + ")"
        return try! NSRegularExpression(pattern: combined, options: [])
    }()

    private static func redactPhones(_ s: String) -> String {
        return phoneRegex.stringByReplacingMatches(
            in: s,
            options: [],
            range: NSRange(s.startIndex..., in: s),
            withTemplate: "[redacted-phone]"
        )
    }

    // Name redaction: any caller-supplied display name plus the
    // POSIX login name. Each is matched case-insensitively, word-
    // bounded, to avoid eating substrings of unrelated tokens.
    private var namesToRedact: [String] {
        var out: [String] = []
        for n in names {
            let trimmed = n.trimmingCharacters(in: .whitespacesAndNewlines)
            // Belt-and-braces: refuse to redact one-character names
            // because doing so would chew the buffer to bits.
            if trimmed.count >= 2 { out.append(trimmed) }
        }
        // POSIX login name is rarely a single character on macOS,
        // but guard anyway.
        let login = loginName.trimmingCharacters(in: .whitespacesAndNewlines)
        if login.count >= 2 { out.append(login) }
        // De-duplicate while preserving order (longest first so a
        // "Andy Massey" replacement runs before "Andy").
        var seen = Set<String>()
        return out
            .sorted { $0.count > $1.count }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    private static func redactNames(_ s: String, names: [String]) -> String {
        guard !names.isEmpty else { return s }
        var out = s
        for n in names {
            // Escape regex metacharacters in the name so a name with
            // a `.` (e.g. "John D.") doesn't break the regex.
            let escaped = NSRegularExpression.escapedPattern(for: n)
            // Word-bounded, case-insensitive.
            let pattern = #"(?<![A-Za-z0-9])"# + escaped + #"(?![A-Za-z0-9])"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                out = regex.stringByReplacingMatches(
                    in: out,
                    options: [],
                    range: NSRange(out.startIndex..., in: out),
                    withTemplate: "[redacted-name]"
                )
            }
        }
        return out
    }
}
