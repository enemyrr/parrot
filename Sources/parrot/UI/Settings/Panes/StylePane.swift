import SwiftUI

/// How parrot writes as you, one kind of writing at a time.
///
/// The pane is a tab bar of categories, and everything under it belongs to the
/// selected one. Three things it has to get right:
///
/// **The category is the unit.** Tone, length and notes all live inside a tab.
/// A single global tone with per-app notes underneath was the old shape, and it
/// asked a paragraph of prose to carry a difference — Mail formal, Slack
/// lowercase — that is two clicks when the tone is per-category.
///
/// **Show the output, not the adjective.** Tone and length are picked by reading
/// the same message written three ways, side by side. The samples are static
/// strings — a model call per card would be slower, cost money, and give a
/// different answer every time the pane opened, which is the opposite of what a
/// reference sample is for.
///
/// **Something always matches.** The last tab is the catch-all and can't be
/// deleted, so "what tone in an app I never set up?" always has an answer, and
/// no call site has to invent one.
struct StylePane: View {
    @ObservedObject var store: SettingsStore

    /// Nil until something is picked, which resolves to the first tab. Stored
    /// as an id rather than an index: deleting a category shifts every index
    /// after it, and a stale one selects the wrong tab or none.
    @State private var selection: UUID?
    /// Whether the category's own setup — its apps, its name and icon, and the
    /// button that deletes it — is open.
    ///
    /// Collapsed by default, and closed again on every tab switch. All three are
    /// things you set once when you make a category; left expanded they pushed
    /// the tone samples, which are what the pane is actually for, off the bottom
    /// of the window.
    @State private var detailsExpanded = false
    @FocusState private var nameFocused: Bool

    private var categories: [StyleCategory] { store.settings.style.categories }

    private var selected: StyleCategory? {
        categories.first { $0.id == selection } ?? categories.first
    }

    var body: some View {
        SettingsPage(
            title: "Style",
            subtitle: "How parrot writes as you — set once per kind of writing."
        ) {
            tabs

            if let category = selected {
                // Every editor in here keeps a local draft until focus leaves
                // it, and clicking a tab doesn't move first responder. Without
                // a new identity per tab, switching tabs reuses those drafts —
                // the name typed for one category commits into the next one.
                Group {
                    appsCard(category)
                    toneCard(category)
                    lengthCard(category)
                    notesCard(category)
                }
                .id(category.id)
            }
        }
    }

    // MARK: - Tabs

    private var tabs: some View {
        GlassTabs(
            selection: Binding(
                get: { selected?.id ?? UUID() },
                set: {
                    selection = $0
                    detailsExpanded = false
                }
            ),
            options: categories.map {
                .init(
                    value: $0.id,
                    title: $0.name.isEmpty ? "Untitled" : $0.name,
                    symbol: $0.symbol
                )
            },
            scrollable: true,
            onAdd: addCategory,
            addHelp: "Add a category"
        )
    }

    private func addCategory() {
        let new = StyleCategory(
            name: "New category",
            symbol: StyleCategory.defaultSymbol,
            bundleIDs: [],
            // Copied from the catch-all rather than reset to the built-in
            // defaults: someone who set every tab to casual means the next one
            // too, and a new tab that silently reverts to the default tone is a
            // change they never asked for and won't notice until it writes.
            tone: store.settings.style.fallback.tone,
            length: store.settings.style.fallback.length
        )
        // Before the catch-all, which has to stay last — it is the tab that
        // answers for everything the others didn't claim.
        let end = max(categories.count - 1, 0)
        store.settings.style.categories.insert(new, at: end)
        selection = new.id
        // Open, unlike every other tab: a new category is called "New category"
        // and claims nothing, so naming it and pointing it at some apps is the
        // whole of what it needs before any of the rest of the pane does
        // anything.
        detailsExpanded = true
        // The name is the first thing to change about a tab called "New
        // category", and it is two clicks away otherwise.
        DispatchQueue.main.async { nameFocused = true }
    }

    private func delete(_ category: StyleCategory) {
        guard !category.isFallback else { return }
        let index = categories.firstIndex { $0.id == category.id }
        store.settings.style.categories.removeAll { $0.id == category.id }
        // Land on the neighbour to the left, the way closing a tab does
        // everywhere else. Selecting the first would jump the pane to the top
        // of a list the user was working at the bottom of.
        let landing = max((index ?? 1) - 1, 0)
        selection = categories.indices.contains(landing) ? categories[landing].id : categories.first?.id
    }

    /// A binding to one category, found by id on every access.
    ///
    /// Indexing into the array would be shorter and wrong: a delete during the
    /// same update leaves a captured index pointing past the end, and SwiftUI
    /// reads bindings after the mutation.
    private func binding(_ category: StyleCategory) -> Binding<StyleCategory> {
        Binding(
            get: { store.settings.style.categories.first { $0.id == category.id } ?? category },
            set: { new in
                guard let index = store.settings.style.categories
                    .firstIndex(where: { $0.id == category.id })
                else { return }
                store.settings.style.categories[index] = new
            }
        )
    }

    // MARK: - Apps

    private func appsCard(_ category: StyleCategory) -> some View {
        let bound = binding(category)

        return SettingsCard(
            header: "Applies to",
            // Nothing for the catch-all: the banner inside it already says it
            // claims whatever the others didn't, and a footer restating that is
            // the same sentence twice.
            footer: category.isFallback
                ? nil
                : "First match wins, top tab down — an app in two categories is written for by "
                    + "the leftmost of them."
        ) {
            SettingsCustomRow(verticalPadding: 12) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { detailsExpanded.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        banner(category)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(detailsExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(detailsExpanded ? "Hide the setup" : "Set up this category")
            }

            if detailsExpanded {
                if !category.isFallback {
                    SettingsCustomRow(verticalPadding: 12) {
                        AppChipList(
                            bundleIDs: bound.bundleIDs,
                            addLabel: "Add apps…",
                            pickerMessage: "Choose the apps this style should apply to."
                        )
                    }
                }

                SettingsRow(
                    label: "Name and icon",
                    description: "What the tab above says.",
                    wideControl: true
                ) {
                    HStack(spacing: 8) {
                        symbolPicker(bound)
                        CommittedText(text: bound.name) { draft in
                            TextField("Name", text: draft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                        }
                        .focused($nameFocused)
                    }
                }

                if !category.isFallback {
                    SettingsCustomRow(verticalPadding: 8) {
                        Button(role: .destructive) {
                            delete(category)
                        } label: {
                            Label("Delete this category", systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    /// The line that answers "where does this apply?" without opening anything.
    ///
    /// Only apps that are on this Mac, and no count of the ones that aren't.
    /// The starters name three or four apps per category so they work out of the
    /// box on any Mac; saying "+3 not installed here" reports on that fact as
    /// though it were a problem, when what the reader wants is the one line
    /// telling them where this applies. The full list is a chevron away.
    private func banner(_ category: StyleCategory) -> some View {
        let shown = category.bundleIDs
            .map(AppCatalog.identity(for:))
            .filter(\.isInstalled)
            .prefix(6)

        return HStack(spacing: 12) {
            if category.isFallback || shown.isEmpty {
                Image(systemName: category.isFallback ? category.symbol : "questionmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            } else {
                HStack(spacing: -4) {
                    ForEach(shown) { identity in
                        AppIcon(identity: identity, size: 24)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(headline(category))
                    .font(.system(size: 12, weight: .medium))
                Text(
                    category.isFallback
                        ? "Every app no other category claims — including ones you've never opened."
                        : "Everything below is how parrot writes when you dictate or squawk here."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func headline(_ category: StyleCategory) -> String {
        let name = category.name.isEmpty ? "this category" : category.name
        if category.isFallback { return "This style is the fallback" }
        if category.bundleIDs.isEmpty {
            return "\(name) has no apps yet — it never matches"
        }
        return "This style applies in \(name)"
    }

    /// Sixteen symbols in a grid, not a symbol browser. This is a tab icon —
    /// the job is telling six tabs apart, and any of these does it.
    private func symbolPicker(_ category: Binding<StyleCategory>) -> some View {
        Menu {
            ForEach(StyleCategory.symbolChoices, id: \.self) { symbol in
                Button {
                    category.wrappedValue.symbol = symbol
                } label: {
                    Label(symbol, systemImage: symbol)
                }
            }
        } label: {
            Image(systemName: category.wrappedValue.symbol)
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26)
        .help("Pick the tab's icon")
    }

    // MARK: - Tone

    private func toneCard(_ category: StyleCategory) -> some View {
        let bound = binding(category)

        return SettingsSection(
            header: "Tone",
            footer: "Dictation only gets the punctuation half of this — it repairs what "
                + "you said, so it can add an exclamation mark but never a word."
        ) {
            // One row, one column per tone. The choice is made by reading the
            // three samples against each other, and anything that wraps puts
            // one of them below the fold of that comparison.
            HStack(alignment: .top, spacing: 10) {
                ForEach(Tone.allCases) { tone in
                    SampleCard(
                        title: tone.displayName,
                        blurb: tone.blurb,
                        sample: tone.sample,
                        selected: category.tone == tone
                    ) {
                        bound.wrappedValue.tone = tone
                    }
                }
            }
        }
    }

    // MARK: - Length

    private func lengthCard(_ category: StyleCategory) -> some View {
        let bound = binding(category)

        return SettingsSection(
            header: "Writing length",
            footer: "Squawk only, and only when you haven't said. \"Reply yes\" is one word "
                + "long whatever this says."
        ) {
            // Side by side, like the tones above: same kind of choice, and
            // stacked rows read as a list you work down rather than three
            // options you compare.
            HStack(alignment: .top, spacing: 10) {
                ForEach(Length.allCases) { length in
                    SampleCard(
                        title: length.displayName,
                        blurb: length.blurb,
                        sample: length.sample,
                        selected: category.length == length
                    ) {
                        bound.wrappedValue.length = length
                    }
                }
            }
        }
    }

    // MARK: - Notes

    private func notesCard(_ category: StyleCategory) -> some View {
        SettingsSection(
            header: "Your habits here",
            footer: "The specifics a tone can't carry: how you sign off, words you avoid, "
                + "names to keep as you say them."
        ) {
            CommittedText(text: binding(category).instructions) { draft in
                PromptEditor(
                    text: draft,
                    placeholder: category.isFallback
                        ? "e.g. no greeting, and sign off with just \"Andreas\""
                        : "e.g. keep the thread's greeting, and sign off with \"Thanks, Andreas\"",
                    minHeight: 72
                )
            }
        }
    }

}

/// A pickable option that shows its own output.
///
/// One shape for tone and for length, because they are the same choice made
/// about different things — and three of them in a row is how each is picked:
/// by reading the samples against each other rather than the adjectives.
///
/// Selection is *one* signal — the accent ring. It used to be three at once
/// (ring, tinted fill, checkmark badge), which is two more than a picked card
/// needs and left the row looking busier than the choice is. The ring keeps its
/// width across states too: growing it on selection nudged the sample text a
/// pixel, so picking a card made its own contents twitch.
private struct SampleCard: View {
    let title: String
    let blurb: String
    let sample: String
    let selected: Bool
    let select: () -> Void

    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous)
    }

    var body: some View {
        Button(action: select) {
            content
                // Stretched so three cards sharing a row are the same height —
                // the samples are different lengths, and boxes of ragged
                // heights make the shorter ones look unfinished.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // The same spring the tab bar's puck rides on. Without it the ring
        // snapped on while the tabs above glided, which is the tell that two
        // controls on one page don't belong to the same thing.
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(title). \(blurb).")
    }

    /// Hover warms the surface rather than brightening the whole card. The old
    /// `.brightness` lifted the text with the box, which reads as a rendering
    /// artefact rather than as a control answering the pointer.
    private var fill: Color {
        if selected { return Color.accentColor.opacity(0.10) }
        return hovering ? Color.primary.opacity(0.06) : SettingsPalette.keycapFill
    }

    /// Half-strength when it isn't being pointed at, so an unselected card in a
    /// row of three doesn't compete with the one that is. The provider chips use
    /// the same fill and the same ring, because they are the same choice.

    private var border: Color {
        selected ? Color.accentColor : SettingsPalette.keycapBorder.opacity(hovering ? 1 : 0.5)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            heading
            Text(sample)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text(blurb)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}
