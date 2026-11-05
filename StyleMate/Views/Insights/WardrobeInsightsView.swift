import SwiftUI
import CoreData

/// Profile → Wardrobe insights: what you wear, what you don't, what's new, the colour and
/// shelf balance, and near-duplicates. Everything is computed on the phone from the closet
/// and the outfit calendar (`WardrobeInsights`).
///
/// Phone / cover display: one column. Duo inner display: two `FoldAwareSplit` columns
/// (what you wear | what you own), split on the crease when half-open.
struct WardrobeInsightsView: View {
    @EnvironmentObject private var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject private var outfitsVM: MyOutfitsViewModel
    @Environment(\.duoLayout) private var duo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var preview: WardrobeItem? = nil
    @State private var showAllUnworn = false
    @State private var appeared = false

    private var insights: WardrobeInsights {
        WardrobeInsights.compute(items: wardrobeViewModel.items, logs: Self.logs(from: outfitsVM.outfitsByDate))
    }

    var body: some View {
        let data = insights
        ScrollView {
            if data.total == 0 {
                emptyState
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.top, DS.Spacing.xxl)
            } else if duo.isWideLayout {
                FoldAwareSplit(gutter: DS.Spacing.xl, stackedSpacing: DS.Spacing.lg) {
                    column { wearColumn(data) }
                } trailing: {
                    column { ownColumn(data) }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.top, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.xxxl)
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    wearColumn(data)
                    ownColumn(data)
                }
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.top, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.xxxl)
            }
        }
        .background(DS.Colors.backgroundPrimary.ignoresSafeArea())
        .navigationTitle("Wardrobe insights")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("insights.root")
        .sheet(item: $preview) { item in
            FullItemImageViewer(path: item.fullImagePath, fallbackPath: item.gridImagePath,
                                title: ClosetText.displayName(item))
        }
        .onAppear {
            let animation: Animation? = reduceMotion ? nil : Animation.easeOut(duration: 0.6).delay(0.1)
            withAnimation(animation) { appeared = true }
        }
    }

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) { content() }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func wearColumn(_ data: WardrobeInsights) -> some View {
        summaryCard(data)
        if !data.mostWorn.isEmpty { mostWornCard(data) }
        if !data.notWorn.isEmpty { notWornCard(data) }
    }

    @ViewBuilder
    private func ownColumn(_ data: WardrobeInsights) -> some View {
        coloursCard(data)
        shelvesCard(data)
        duplicatesCard(data)
        if !data.recent.isEmpty { recentCard(data) }
    }

    // MARK: - Summary

    private func summaryCard(_ data: WardrobeInsights) -> some View {
        HStack(spacing: DS.Spacing.lg) {
            ZStack {
                Circle()
                    .stroke(DS.Colors.accentSoft, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: appeared ? max(0.02, data.wornShare) : 0)
                    .stroke(DS.Colors.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int((data.wornShare * 100).rounded()))%")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .monospacedDigit()
                    Text("worn")
                        .font(DS.Font.caption2)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                Text("\(data.total) piece\(data.total == 1 ? "" : "s")")
                    .font(DS.Font.title2)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(summaryLine(data))
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .insightCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights.summary")
    }

    private func summaryLine(_ data: WardrobeInsights) -> String {
        guard let start = data.logStart else {
            return "Log what you wear (Wear today) and this shows what you really reach for."
        }
        let worn = "\(data.wornInWindow) of \(data.total) worn"
        if data.logCoversWindow { return "\(worn) in the last \(WardrobeInsights.windowDays) days." }
        return "\(worn) since you started logging on \(start.formatted(.dateTime.day().month(.abbreviated)))."
    }

    // MARK: - Most worn

    private func mostWornCard(_ data: WardrobeInsights) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            cardHeader("Most worn", icon: "flame", detail: nil)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    ForEach(data.mostWorn) { worn in
                        itemTile(worn.item, caption: worn.count == 1 ? "Once" : "\(worn.count) times",
                                 badge: "\(worn.count)×")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
        .insightCard()
        .accessibilityIdentifier("insights.mostWorn")
    }

    // MARK: - Not worn

    private func notWornCard(_ data: WardrobeInsights) -> some View {
        // Only claim "60 days" when the outfit log really goes back that far.
        let title = data.logCoversWindow ? "Not worn in \(WardrobeInsights.windowDays) days" : "Not worn yet"
        let shown = showAllUnworn ? data.notWorn : Array(data.notWorn.prefix(8))
        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            cardHeader(title, icon: "moon.zzz", detail: "\(data.notWorn.count)")
            Text(data.hasWearLog
                 ? "Give one of these a turn: Keep it in a look and shuffle the rest."
                 : "Nothing logged yet: tap Wear today on a look and it counts here.")
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.xs), count: 4),
                      spacing: DS.Spacing.xs) {
                ForEach(shown) { item in
                    Button { preview = item } label: {
                        AsyncItemTile(path: item.gridImagePath, cornerRadius: DS.Radius.control, inset: 6)
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(DSTapBounce())
                    .accessibilityLabel(ClosetText.displayName(item))
                }
            }
            if data.notWorn.count > shown.count || showAllUnworn {
                Button {
                    withAnimation(DS.Motion.smooth) { showAllUnworn.toggle() }
                } label: {
                    Text(showAllUnworn ? "Show fewer" : "Show all \(data.notWorn.count)")
                        .font(DS.Font.footnote.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(DSTertiaryButton())
                .accessibilityIdentifier("insights.notWorn.all")
            }
        }
        .insightCard()
        .accessibilityIdentifier("insights.notWorn")
    }

    // MARK: - Colours

    private func coloursCard(_ data: WardrobeInsights) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            cardHeader("Colour balance", icon: "paintpalette",
                       detail: "\(Int((data.neutralShare * 100).rounded()))% neutrals")
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(data.colours) { share in
                        Rectangle()
                            .fill(swatch(share.name))
                            .frame(width: max(4, (geo.size.width - CGFloat(data.colours.count - 1) * 2)
                                                * (appeared ? share.fraction : 1 / Double(max(1, data.colours.count)))))
                    }
                }
                .clipShape(Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(DS.Colors.separator, lineWidth: 0.5))
            }
            .frame(height: 18)
            .accessibilityHidden(true)

            FlowLayout(spacing: DS.Spacing.xs) {
                ForEach(data.colours) { share in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(swatch(share.name))
                            .overlay(Circle().strokeBorder(DS.Colors.separator, lineWidth: 0.5))
                            .frame(width: 12, height: 12)
                        Text(share.name)
                            .font(DS.Font.footnote)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text("\(share.count)")
                            .font(DS.Font.footnote.weight(.semibold))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.vertical, 5)
                    .background(DS.Colors.backgroundSecondary, in: Capsule(style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .insightCard()
        .accessibilityIdentifier("insights.colours")
    }

    private func swatch(_ name: String) -> Color {
        name == "Other" ? DS.Colors.textTertiary.opacity(0.4) : ColorMapping.color(for: name)
    }

    // MARK: - Shelves

    private func shelvesCard(_ data: WardrobeInsights) -> some View {
        let top = data.shelves.map(\.count).max() ?? 1
        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            cardHeader("By shelf", icon: "square.stack.3d.up", detail: nil)
            VStack(spacing: DS.Spacing.xs) {
                ForEach(data.shelves) { shelf in
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: shelf.section.iconName)
                            .font(DS.Font.footnote)
                            .foregroundStyle(DS.Colors.accent)
                            .frame(width: 22)
                        Text(shelf.section.title)
                            .font(DS.Font.subheadline)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: 150, alignment: .leading)
                        GeometryReader { geo in
                            Capsule(style: .continuous)
                                .fill(DS.Colors.accent.opacity(0.85))
                                .frame(width: max(6, geo.size.width * (appeared ? CGFloat(shelf.count) / CGFloat(top) : 0)))
                                .frame(maxHeight: .infinity)
                        }
                        .frame(height: 8)
                        Text("\(shelf.count)")
                            .font(DS.Font.footnote.weight(.semibold))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .monospacedDigit()
                            .frame(minWidth: 24, alignment: .trailing)
                    }
                    .frame(minHeight: 28)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(shelf.section.title): \(shelf.count)")
                }
            }
            if let note = data.balanceNote {
                Label(note, systemImage: "lightbulb")
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .insightCard()
        .accessibilityIdentifier("insights.shelves")
    }

    // MARK: - Duplicates

    private func duplicatesCard(_ data: WardrobeInsights) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            cardHeader("Lookalikes", icon: "square.on.square", detail: nil)
            if data.duplicates.isEmpty {
                Text("No near-duplicates: every piece earns its place.")
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Colors.textSecondary)
            } else {
                ForEach(data.duplicates.prefix(4)) { dup in
                    HStack(spacing: DS.Spacing.sm) {
                        ZStack(alignment: .leading) {
                            ForEach(Array(dup.items.prefix(3).enumerated()), id: \.element.id) { index, item in
                                AsyncItemTile(path: item.gridImagePath, height: 44, cornerRadius: DS.Radius.chip, inset: 3)
                                    .frame(width: 44)
                                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                                        .strokeBorder(DS.Colors.backgroundCard, lineWidth: 2))
                                    .offset(x: CGFloat(index) * 18)
                                    .zIndex(Double(3 - index))
                            }
                        }
                        .frame(width: 44 + 36, alignment: .leading)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(dup.title)
                                .font(DS.Font.subheadline.weight(.semibold))
                                .foregroundStyle(DS.Colors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Worth a look before buying another")
                                .font(DS.Font.footnote)
                                .foregroundStyle(DS.Colors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .insightCard()
        .accessibilityIdentifier("insights.duplicates")
    }

    // MARK: - Recent

    private func recentCard(_ data: WardrobeInsights) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            cardHeader("Newest pieces", icon: "sparkles", detail: nil)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    ForEach(data.recent) { item in
                        itemTile(item, caption: nil, badge: nil)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
        .insightCard()
        .accessibilityIdentifier("insights.recent")
    }

    // MARK: - Pieces

    private func cardHeader(_ title: String, icon: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Label(title, systemImage: icon)
                .font(DS.Font.headline)
                .foregroundStyle(DS.Colors.textPrimary)
                .labelStyle(InsightHeaderLabelStyle())
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(DS.Font.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.accent)
                    .monospacedDigit()
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func itemTile(_ item: WardrobeItem, caption: String?, badge: String?) -> some View {
        Button { preview = item } label: {
            VStack(alignment: .leading, spacing: 4) {
                AsyncItemTile(path: item.gridImagePath, height: 104, cornerRadius: DS.Radius.control, inset: 8)
                    .frame(width: 92)
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Text(badge)
                                .font(DS.Font.caption2.weight(.bold))
                                .foregroundStyle(DS.Colors.onAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DS.Colors.accent, in: Capsule(style: .continuous))
                                .padding(5)
                        }
                    }
                Text(StyleVocabulary.capitalizedFirst(StyleVocabulary.describe(item)))
                    .font(DS.Font.caption1)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(2)
                    .frame(width: 92, alignment: .leading)
                if let caption {
                    Text(caption)
                        .font(DS.Font.caption2)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
        }
        .buttonStyle(DSTapBounce())
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.md) {
            ZStack {
                Circle().fill(DS.Colors.accentSoft).frame(width: 84, height: 84)
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(DS.Colors.accent)
            }
            Text("No pieces yet")
                .font(DS.Font.title3)
                .foregroundStyle(DS.Colors.textPrimary)
            Text("Add clothes to your wardrobe and this shows what you wear, what you don't and where the gaps are.")
                .font(DS.Font.subheadline)
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .insightCard()
    }

    /// The outfit log as (date, item ids) pairs.
    static func logs(from outfitsByDate: [Date: [DatedOutfit]]) -> [ClosetWear.Log] {
        outfitsByDate.values.flatMap { $0 }.map { outfit in
            let ids: [UUID] = (outfit.items as? Set<OutfitItem>)?.compactMap { $0.id } ?? []
            return (date: outfit.date ?? .distantPast, itemIDs: ids)
        }
    }
}

/// Icon in the accent colour, title in the text colour.
private struct InsightHeaderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            configuration.icon
                .foregroundStyle(DS.Colors.accent)
                .font(DS.Font.subheadline.weight(.semibold))
            configuration.title
        }
    }
}

private extension View {
    /// The insights screen's card: the app's card surface with its rim / shadow.
    func insightCard() -> some View {
        self
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .dsCardShadow(cornerRadius: DS.Radius.card)
    }
}
