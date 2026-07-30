import Foundation

/// Literal find → replace over a transcript, plus the vocabulary terms handed
/// to the cleanup model.
///
/// Matching is case-insensitive and anchored to word boundaries, so a rule for
/// `"vercell"` doesn't fire inside `"vercelling"`. Replacements are literal
/// rather than regex: this is user-facing config, and a stray `.*` there would
/// be a footgun rather than a feature.
///
/// All rules are compiled into one alternation and applied in a **single
/// left-to-right pass**, so text a rule emits is never re-examined by another
/// rule. Applying rules sequentially instead would let a rule for `"claude"`
/// chew through the output of a rule for `"claude code"`.
struct Wordlist {
    /// One capture group per rule; group *n* corresponds to `values[n - 1]`.
    private let combined: NSRegularExpression?
    private let values: [String]
    let vocabulary: [String]

    init(config: WordlistConfig) {
        self.vocabulary = config.vocabulary

        // Longest key first: within the alternation the earliest matching
        // branch wins at a given position, so "claude code" must precede
        // "claude". Ties broken alphabetically to keep the order stable.
        let rules = config.replacements
            .filter { !$0.key.isEmpty }
            .sorted {
                $0.key.count == $1.key.count ? $0.key < $1.key : $0.key.count > $1.key.count
            }

        var patterns: [String] = []
        var values: [String] = []
        for (key, value) in rules {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            // \b only fires between a word and a non-word character, so only
            // anchor the sides that actually begin/end with a word character
            // — otherwise a key like "c++" could never match.
            let leading = key.first.map(Self.isWordCharacter) == true ? #"\b"# : ""
            let trailing = key.last.map(Self.isWordCharacter) == true ? #"\b"# : ""
            patterns.append("(" + leading + escaped + trailing + ")")
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

    /// Apply every rule in one pass.
    ///
    /// Idempotent for well-formed wordlists — one where no replacement value
    /// re-introduces another rule's key. Correcting a misspelling to its proper
    /// form (`"vercell"` → `"Vercel"`) or fixing casing (`"claude code"` →
    /// `"Claude Code"`) both satisfy that, which is what lets the pipeline run
    /// this on both sides of the cleanup pass.
    func apply(to text: String) -> String {
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
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += value
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
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
