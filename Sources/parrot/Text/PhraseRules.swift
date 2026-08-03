import Foundation

/// Literal phrase → text rewrites, applied in one pass.
///
/// Shared by the wordlist and by shortcuts, because both are the same job with
/// different intent behind it: find phrases in a transcript, swap them for
/// something else. Matching is case-insensitive and anchored to word
/// boundaries, so a rule for `"vercell"` doesn't fire inside `"vercelling"`.
/// Rules are literal rather than regex: this is user-facing config, and a stray
/// `.*` there would be a footgun rather than a feature.
///
/// All rules are compiled into one alternation and applied in a **single
/// left-to-right pass**, so text a rule emits is never re-examined by another
/// rule. Applying rules sequentially instead would let a rule for `"claude"`
/// chew through the output of a rule for `"claude code"`.
struct PhraseRules {
    /// One capture group per rule; group *n* corresponds to `values[n - 1]`.
    private let combined: NSRegularExpression?
    private let values: [String]

    /// - Parameter looseSpacing: let a run of spacing or mid-phrase punctuation
    ///   stand between the words of a key. A spoken trigger needs it — the
    ///   transcriber decides on its own where the commas go, and "send my email
    ///   shortcut" can come back as "send my email, shortcut". A misspelling
    ///   rule does not: it is correcting text the transcriber already chose.
    ///   What it deliberately excludes is anything that *ends* an utterance —
    ///   `.` `!` `?` and line breaks — because a key that spans those is
    ///   matching two sentences, not one loosely punctuated phrase.
    init(_ rules: [(key: String, value: String)], looseSpacing: Bool = false) {
        // Longest key first: within the alternation the earliest matching
        // branch wins at a given position, so "claude code" must precede
        // "claude". Ties broken alphabetically to keep the order stable.
        let sorted = rules
            .filter { !$0.key.isEmpty }
            .sorted {
                $0.key.count == $1.key.count ? $0.key < $1.key : $0.key.count > $1.key.count
            }

        var patterns: [String] = []
        var values: [String] = []
        for (key, value) in sorted {
            patterns.append("(" + Self.pattern(for: key, looseSpacing: looseSpacing) + ")")
            values.append(value)
        }

        self.values = values
        self.combined = patterns.isEmpty
            ? nil
            : try? NSRegularExpression(
                pattern: patterns.joined(separator: "|"),
                options: [.caseInsensitive]
            )
    }

    var isEmpty: Bool { combined == nil }

    /// Where every rule fires, without rewriting anything. Lets one set of rules
    /// be fenced off from another's — see `apply(to:excluding:)`.
    func ranges(in text: String) -> [NSRange] {
        guard let combined, !text.isEmpty else { return [] }
        return combined.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length)
        ).map(\.range)
    }

    /// Apply every rule in one pass.
    ///
    /// - Parameter excluding: spans to leave alone. A match overlapping one of
    ///   them is dropped rather than trimmed: these are whole phrases, and half
    ///   a rewrite is worse than none.
    func apply(to text: String, excluding: [NSRange] = []) -> String {
        guard let combined, !text.isEmpty else { return text }
        let ns = text as NSString
        let matches = combined.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = 0
        for match in matches {
            guard let value = replacement(for: match) else { continue }
            guard !excluding.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
            else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += value
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func pattern(for key: String, looseSpacing: Bool) -> String {
        let words = key.split(whereSeparator: \.isWhitespace).map(String.init)
        let body: String
        if looseSpacing, words.count > 1 {
            body = words
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: #"(?:[^\S\r\n]|[,–—-])+"#)
        } else {
            body = NSRegularExpression.escapedPattern(for: key)
        }

        // \b only fires between a word and a non-word character, so only anchor
        // the sides that actually begin/end with a word character — otherwise a
        // key like "c++" could never match.
        let leading = key.first.map(isWordCharacter) == true ? #"\b"# : ""
        let trailing = key.last.map(isWordCharacter) == true ? #"\b"# : ""
        return leading + body + trailing
    }

    /// Which branch of the alternation fired — exactly one group is non-nil.
    private func replacement(for match: NSTextCheckingResult) -> String? {
        for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
            return values[group - 1]
        }
        return nil
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}
