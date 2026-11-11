import Foundation

/// Pure, event-driven eligibility for automatic assessment. Call when observed
/// content changes; an unchanged finished window stays cached like any other result.
/// This does not authorize transmission or replace an explicit user opt-in.
public enum AutomaticAttention {
    public static func nextWindow(windows: [SessionWindow], cachedVersions: Set<String>,
                                  attemptedVersions: Set<String>) -> SessionWindow? {
        windows.filter { window in
            window.key.provider == .codex && window.host == "local" &&
            window.hasTaskEvidence && !window.incomplete && !window.unansweredUser &&
            !cachedVersions.contains(window.contentVersion) &&
            !attemptedVersions.contains(window.contentVersion) && !containsLikelySecret(window)
        }.sorted {
            if $0.sourceUpdatedAt != $1.sourceUpdatedAt { return $0.sourceUpdatedAt > $1.sourceUpdatedAt }
            return $0.contentVersion < $1.contentVersion
        }.first
    }

    /// A conservative last-line guard, not a guarantee of anonymization. Matching
    /// windows remain local and can be reviewed rather than silently redacted.
    /// Recognizable credentials are checked even inside example/code blocks.
    public static func containsLikelySecret(_ window: SessionWindow) -> Bool {
        window.messages.contains { containsLikelySecret(in: $0.text) }
    }
    public static func containsLikelySecret(in text: String) -> Bool {
        patterns.contains { pattern in
            pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        } || containsPlausiblePaymentCard(text)
    }

    /// Deliberately broad: a full SSN-shaped number stays local even when it is
    /// called an example. Card candidates must have 13–19 digits and pass Luhn.
    private static func containsPlausiblePaymentCard(_ text: String) -> Bool {
        cardCandidate.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { match in
            guard let range = Range(match.range, in: text) else { return false }
            let digits = text[range].compactMap { character -> Int? in
                guard character >= "0" && character <= "9" else { return nil }
                return character.wholeNumberValue
            }
            guard (13...19).contains(digits.count) else { return false }
            let sum = digits.reversed().enumerated().reduce(0) { sum, pair in
                let value = pair.offset.isMultiple(of: 2) ? pair.element : pair.element * 2
                return sum + (value > 9 ? value - 9 : value)
            }
            return sum.isMultiple(of: 10)
        }
    }
    private static let cardCandidate = try! NSRegularExpression(
        pattern: #"(?<![0-9])(?:[0-9][ -]?){12,18}[0-9](?![ -]?[0-9])"#)

    private static let patterns: [NSRegularExpression] = [
        #"(?<![0-9])[0-9]{3}[- ]?[0-9]{2}[- ]?[0-9]{4}(?![0-9])"#,
        #"(?i)\bsk-(?:proj-|svcacct-)?[a-z0-9_-]{12,}"#,
        // RSA, OpenSSH, encrypted and PGP ("... PRIVATE KEY BLOCK") private keys.
        #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"#,
        #"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})\b"#,
        #"\b(?:xox[baprs]-[A-Za-z0-9-]{12,}|AIza[A-Za-z0-9_-]{20,})\b"#,
        // Credential labels, also as .env names with a prefix: `_` is a word character, so
        // `\b` never matched inside DB_PASSWORD= or AWS_SECRET_ACCESS_KEY=.
        #"(?i)(?<![a-z0-9])(?:[a-z0-9]+_)*(?:password|passwd|pwd|api[_ -]?key|apikey|client[_ -]?secret|access[_ -]?token|refresh[_ -]?token|auth[_ -]?token|secret[_ -]?(?:access[_ -]?)?key|secret[_ -]?token|private[_ -]?key|OPENAI_API_KEY)\b[\"']?\s*(?:=|:)\s*[\"']?[^\s\"'`,;]{4,}"#,
        // .env names ending in _TOKEN, _SECRET or _PASS, such as GITHUB_TOKEN= or SLACK_BOT_TOKEN=.
        #"(?i)(?<![a-z0-9])[a-z0-9]+(?:_[a-z0-9]+)*_(?:token|secret|pass)\b[\"']?\s*(?:=|:)\s*[\"']?[^\s\"'`,;]{4,}"#,
        #"(?i)\b(?:authorization\s*:\s*)?bearer\s+[a-z0-9._~+/-]{12,}={0,2}"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
        // Stripe secret and restricted keys, npm tokens, and a password inside a URL.
        #"\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}"#,
        #"\bnpm_[A-Za-z0-9]{36}\b"#,
        #"(?i)\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@"#
    ].map { try! NSRegularExpression(pattern: $0) }
}
