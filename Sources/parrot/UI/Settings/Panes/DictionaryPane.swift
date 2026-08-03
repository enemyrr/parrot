import SwiftUI

/// Everything that rewrites words on their way out: the corrections parrot
/// applies to what it misheard, and the expansions you trigger on purpose.
///
/// Two tabs rather than two sidebar entries — they are the same errand ("make
/// parrot type this, not that") reached from the same place, and neither half
/// is deep enough to earn a page of its own.
struct DictionaryPane: View {
    @ObservedObject var store: SettingsStore

    private enum Tab: String, CaseIterable, Identifiable {
        case words = "Words"
        case shortcuts = "Shortcuts"

        var id: String { rawValue }

        var subtitle: String {
            switch self {
            case .words: return "Teach parrot the words it keeps getting wrong."
            case .shortcuts: return "Say a short phrase, type something longer."
            }
        }
    }

    @State private var tab: Tab = .words

    var body: some View {
        SettingsPage(title: "Dictionary", subtitle: tab.subtitle) {
            GlassTabs(
                selection: $tab,
                options: Tab.allCases.map { .init(value: $0, title: $0.rawValue) }
            )

            Group {
                switch tab {
                case .words:
                    VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                        vocabularyCard
                        replacementsCard
                    }
                case .shortcuts:
                    ShortcutsSection(store: store)
                }
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.16), value: tab)
        }
    }

    private var vocabularyCard: some View {
        SettingsCard(
            header: "Vocabulary",
            footer: "Terms the cleanup model is told to leave exactly as written. "
                + "This has no effect unless cleanup is on — it steers the cleaner, "
                + "not the transcriber."
        ) {
            SettingsCustomRow(verticalPadding: 12) {
                TokenListEditor(
                    tokens: $store.settings.wordlist.vocabulary,
                    placeholder: "Vercel, FluidAudio, Kubernetes…"
                )
            }
        }
    }

    private var replacementsCard: some View {
        SettingsCard(
            header: "Replacements",
            footer: "Applied to every transcript, with or without cleanup. Matching is "
                + "case-insensitive and stops at word boundaries, so “vercell” won't "
                + "fire inside “vercelling”. Multi-word terms work, and longer rules "
                + "win over shorter ones that overlap them.\n\n"
                + "This is for words parrot heard wrong. For a phrase you say on purpose "
                + "to stand in for something longer, see the Shortcuts tab."
        ) {
            if store.settings.wordlist.replacements.isEmpty {
                SettingsCustomRow(verticalPadding: 18) {
                    Text("No replacements yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                SettingsCustomRow(verticalPadding: 8) {
                    HStack(spacing: 8) {
                        Text("HEARD")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right")
                            .opacity(0)
                        Text("TYPED")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer().frame(width: 22)
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                }

                ForEach($store.settings.wordlist.replacements) { $rule in
                    SettingsCustomRow(verticalPadding: 6) {
                        HStack(spacing: 8) {
                            CommittedText(text: $rule.from) { draft in
                                TextField("claude code", text: draft)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            CommittedText(text: $rule.to) { draft in
                                TextField("Claude Code", text: draft)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button {
                                remove(rule)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 22)
                            .help("Remove this replacement")
                        }
                    }
                }
            }

            SettingsCustomRow(verticalPadding: 8) {
                Button {
                    store.settings.wordlist.replacements.append(Replacement(from: "", to: ""))
                } label: {
                    Label("Add replacement", systemImage: "plus")
                }
                .controlSize(.small)
            }
        }
    }

    private func remove(_ rule: Replacement) {
        store.settings.wordlist.replacements.removeAll { $0.id == rule.id }
    }
}
