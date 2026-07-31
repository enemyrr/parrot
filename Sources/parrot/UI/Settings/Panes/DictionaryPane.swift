import SwiftUI

/// Names the model gets wrong, and the corrections that fix them.
struct DictionaryPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPage(
            title: "Dictionary",
            subtitle: "Teach parrot the words it keeps getting wrong."
        ) {
            vocabularyCard
            replacementsCard
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
                + "win over shorter ones that overlap them."
        ) {
            if store.settings.wordlist.replacements.isEmpty {
                SettingsCustomRow(verticalPadding: 16) {
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
                            TextField("claude code", text: $rule.from)
                                .textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            TextField("Claude Code", text: $rule.to)
                                .textFieldStyle(.roundedBorder)
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
