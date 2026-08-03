import SwiftUI

struct LanguagesDialog: View {
    @ObservedObject var store: SettingsStore
    let dismiss: () -> Void

    var body: some View {
        SettingsDialog(
            title: "Languages",
            subtitle: "Which alphabets parrot is allowed to type.",
            dismiss: dismiss
        ) {
            SettingsCard(footer: footer) {
                SettingsCustomRow(verticalPadding: 12) {
                    TokenListEditor(
                        tokens: $store.settings.languages,
                        placeholder: "Language code — en, sv, de…",
                        normalize: { $0.trimmingCharacters(in: .whitespaces).lowercased() },
                        validate: { LanguageSelection.supportedCodes.contains($0) }
                    )
                }
            }
        }
    }

    /// The setting reads like "only recognise these languages" and it is not
    /// that, so the dialog says what it actually does rather than leaving the
    /// user to discover the difference mid-sentence.
    private var footer: String {
        let base = "The model always auto-detects across all 25 of its languages. "
            + "Listing yours only restricts the alphabet it may output, which "
            + "keeps stray Cyrillic or Han characters out of a Latin transcript."
        switch LanguageSelection.resolve(store.settings.languages) {
        case .conflicting(let scripts):
            return base + "\n⚠ Those span \(scripts.joined(separator: " + ")) alphabets, "
                + "so nothing can be filtered. List languages that share one."
        default:
            return base
        }
    }
}
