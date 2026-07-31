import FluidAudio
import Foundation

/// Resolves the configured language list into the single hint FluidAudio takes.
///
/// Parakeet v3 always auto-detects across all 25 of its languages — there is no
/// way to restrict it to a subset. What the decoder *does* accept is a language
/// hint, and that hint filters candidate tokens by **writing script**, keeping
/// only those whose characters fall in the target script's Unicode ranges.
///
/// That distinction matters:
///
/// - It will **not** stop English being transcribed as Swedish, or vice versa —
///   both are Latin, so both pass the same filter.
/// - It **will** stop stray Han, Cyrillic, or Greek characters appearing in an
///   otherwise Latin transcript, which is the common failure on slang or
///   otherwise ambiguous audio.
///
/// So the config takes a list of languages, but only the script they share is
/// load-bearing. Listing languages from different scripts leaves nothing the
/// filter could enforce, so it's disabled rather than silently picking one.
enum LanguageSelection {
    enum Resolution {
        /// Filter to this language's script.
        case filter(Language)
        /// No hint configured — the decoder is free to emit any script.
        case unrestricted
        /// Configured languages disagree on script; filtering is off.
        case conflicting(scripts: [String])
        case unknownCodes([String])
    }

    static func resolve(_ codes: [String]) -> Resolution {
        guard !codes.isEmpty else { return .unrestricted }

        var languages: [Language] = []
        var unknown: [String] = []
        for code in codes {
            let normalised = code.lowercased().trimmingCharacters(in: .whitespaces)
            if let language = Language(rawValue: normalised) {
                languages.append(language)
            } else {
                unknown.append(code)
            }
        }
        guard unknown.isEmpty else { return .unknownCodes(unknown) }
        guard let first = languages.first else { return .unrestricted }

        // Any language of the right script produces the same filter, so the
        // first one stands in for the whole set.
        let scripts = Set(languages.map { describe($0.script) })
        guard scripts.count == 1 else {
            return .conflicting(scripts: scripts.sorted())
        }
        return .filter(first)
    }

    /// Every language code the model understands, for error messages.
    static var supportedCodes: [String] {
        Language.allCases.map(\.rawValue).sorted()
    }

    /// Human names for the cleanup prompt — "English, Swedish" steers a
    /// language model far better than "en, sv" does.
    static func displayNames(_ codes: [String]) -> [String] {
        let english = Locale(identifier: "en_US")
        return codes.compactMap { code in
            let normalised = code.lowercased().trimmingCharacters(in: .whitespaces)
            guard !normalised.isEmpty else { return nil }
            return english.localizedString(forLanguageCode: normalised) ?? normalised
        }
    }

    static func describe(_ script: Script) -> String {
        switch script {
        case .latin: return "latin"
        case .cyrillic: return "cyrillic"
        case .greek: return "greek"
        @unknown default: return "unknown"
        }
    }
}
