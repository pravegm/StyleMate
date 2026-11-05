import SwiftUI

/// Profile → About → Acknowledgements: app version, privacy policy, and every bundled licence /
/// attribution text (`Acknowledgement.all()`, from `StyleMate/Resources/Acknowledgements/`).
///
/// Phone: a list that pushes each text. Wide layout (iPhone Duo inner display): the list and the selected
/// text side by side, split at the crease when half-open (`FoldAwareSplit`), so no text runs across the fold.
struct AcknowledgementsView: View {
    @Environment(\.duoLayout) private var duo
    @State private var entries: [Acknowledgement] = Acknowledgement.all()
    @State private var selectedID: String?

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    var body: some View {
        Group {
            if duo.isWideLayout {
                wide
            } else {
                compact
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("acknowledgements.root")
    }

    // MARK: Phone

    private var compact: some View {
        List {
            aboutSection
            Section {
                ForEach(entries) { entry in
                    NavigationLink {
                        AcknowledgementDetail(entry: entry)
                    } label: {
                        EntryLabel(entry: entry)
                    }
                    .accessibilityIdentifier("acknowledgements.entry.\(entry.id)")
                }
            } header: {
                Text("Included models, code and data")
            } footer: {
                footer
            }
        }
        .tint(DS.Colors.accent)
    }

    // MARK: Wide (Duo inner display)

    private var wide: some View {
        let selected = entries.first { $0.id == selectedID } ?? entries.first
        return FoldAwareSplit(gutter: DS.Spacing.lg, leadingFraction: 0.4, minimumWidth: 0) {
            List {
                aboutSection
                Section {
                    ForEach(entries) { entry in
                        Button {
                            selectedID = entry.id
                        } label: {
                            HStack {
                                EntryLabel(entry: entry)
                                Spacer(minLength: DS.Spacing.xs)
                                if entry.id == selected?.id {
                                    Image(systemName: "checkmark").foregroundStyle(DS.Colors.accent)
                                }
                            }
                        }
                        .accessibilityIdentifier("acknowledgements.entry.\(entry.id)")
                    }
                } header: {
                    Text("Included models, code and data")
                } footer: {
                    footer
                }
            }
            .tint(DS.Colors.accent)
        } trailing: {
            if let selected {
                AcknowledgementDetail(entry: selected, isPushed: false)
            }
        }
        .background(DS.Colors.backgroundPrimary.ignoresSafeArea())
    }

    // MARK: Shared

    private var aboutSection: some View {
        Section("StyleMate") {
            LabeledContent("Version", value: appVersion)
            Link(destination: LegalLinks.privacyPolicy) {
                HStack(spacing: DS.Spacing.xs) {
                    Text("Privacy Policy")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .foregroundColor(DS.Colors.accent)
            }
            .accessibilityIdentifier("acknowledgements.privacyPolicy")
        }
    }

    private var footer: some View {
        Text("StyleMate's AI runs on your iPhone with these components. Thank you to their authors.")
            .font(DS.Font.caption2)
    }
}

private struct EntryLabel: View {
    let entry: Acknowledgement

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .font(DS.Font.body)
                .foregroundStyle(DS.Colors.textPrimary)
            Text([entry.kind, entry.licence].compactMap { $0 }.joined(separator: " · "))
                .font(DS.Font.caption1)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .padding(.vertical, 2)
    }
}

/// One licence / attribution text, rendered from its Markdown blocks.
struct AcknowledgementDetail: View {
    let entry: Acknowledgement
    /// Pushed on its own (phone): it titles the navigation bar. In the wide split it doesn't.
    var isPushed = true
    @State private var blocks: [MarkdownBlocks.Block] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text(entry.title)
                    .font(DS.Font.title2)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let licence = entry.licence {
                    Text(licence)
                        .font(DS.Font.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Colors.accent)
                }
                if let source = entry.source {
                    Link(source.absoluteString, destination: source)
                        .font(DS.Font.footnote)
                        .lineLimit(2)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.vertical, DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Colors.backgroundPrimary.ignoresSafeArea())
        .modifier(TitleIfPushed(title: entry.title, isPushed: isPushed))
        .accessibilityIdentifier("acknowledgements.detail")
        .task(id: entry.id) { blocks = MarkdownBlocks.parse(entry.body) }
    }
}

private struct TitleIfPushed: ViewModifier {
    let title: String
    let isPushed: Bool

    func body(content: Content) -> some View {
        if isPushed {
            content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}

private struct BlockView: View {
    let block: MarkdownBlocks.Block

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 1 ? DS.Font.title3 : DS.Font.headline)
                .foregroundStyle(DS.Colors.textPrimary)
                .padding(.top, DS.Spacing.xs)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                Text("•").font(DS.Font.footnote).foregroundStyle(DS.Colors.textSecondary)
                Text(Self.inline(text))
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider().padding(.vertical, DS.Spacing.xs)
        }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
