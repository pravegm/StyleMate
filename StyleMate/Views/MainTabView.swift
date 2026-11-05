import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @Binding var showAddSheet: Bool
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var tutorialManager: TutorialManager

    var body: some View {
        // Tab API + sidebarAdaptable: a glass tab bar on iPhone and the Duo's
        // cover display, a sidebar on the wide inner display.
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: 0) {
                HomeView()
            }
            Tab("Wardrobe", systemImage: "tshirt", value: 1) {
                MyWardrobeView(showAddSheet: $showAddSheet)
            }
            Tab("Outfits", systemImage: "calendar", value: 2) {
                MyOutfitsView()
            }
            Tab("Profile", systemImage: "person.circle", value: 3) {
                ProfileTab()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(DS.Colors.accent)
        .sensoryFeedback(.selection, trigger: selectedTab)
        // The outfit sheet's "View in Calendar" jumps to the Outfits tab.
        .onReceive(NotificationCenter.default.publisher(for: .showOutfitsCalendar)) { _ in
            selectedTab = 2
        }
        // A tapped morning notification opens Today's Outfit from Home: bring Home
        // to the front first (HomeFirstRunCards presents it a beat later).
        .onReceive(NotificationRouter.shared.$pendingMorningLook) { day in
            if day != nil, selectedTab != 0 { selectedTab = 0 }
        }
        // The outfit sheet's "add shoes" tip opens the add-clothes sheet.
        .onReceive(NotificationCenter.default.publisher(for: .showAddClothes)) { _ in
            selectedTab = 1
            showAddSheet = true
        }
        // Host the coach-mark tour over the whole tab UI. It reads the Home
        // elements' frames (anchors) from the selected tab's content.
        .overlayPreferenceValue(CoachAnchorKey.self) { anchors in
            GeometryReader { geo in
                if tutorialManager.activeTour == .home {
                    CoachMarkOverlay(tutorial: tutorialManager, tour: .home, anchors: anchors, proxy: geo)
                }
            }
            .ignoresSafeArea()   // full-screen geo: anchors + scrim share one coordinate space
        }
        // The Home tour navigates between tabs; follow the current step's tab, and
        // return to Home when it ends.
        .onChange(of: tutorialManager.activeTour) { tour in
            if tour == .home { selectedTab = tutorialManager.current?.tab ?? 0 }
            else if tour == nil { selectedTab = 0 }
        }
        .onChange(of: tutorialManager.stepIndex) { _ in
            if tutorialManager.activeTour == .home {
                selectedTab = tutorialManager.current?.tab ?? 0
            }
        }
        .onAppear {
            Haptics.prepare()
            if let uid = authService.user?.id {
                tutorialManager.configure(forUser: uid)
                // Brief beat so the tour doesn't start mid-entrance-animation; the
                // spotlight targets are already measured on first render.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    tutorialManager.startIfFirstTime(.home)
                }
            }
        }
    }
}

// MARK: - Profile tab

/// Profile on a phone; on the Duo's inner display the settings list takes one
/// half (never spanning the crease) and a wardrobe summary the other.
///
/// ProfileView is always the first child of the same layout, so its identity (and its
/// NavigationStack: a pushed Diagnostics or Acknowledgements screen) survives folding and
/// unfolding. An if/else between two containers rebuilt it, which popped Diagnostics in the
/// middle of the Duo hinge check (Duo run 42002975851, 08-diagnostics).
private struct ProfileTab: View {
    @Environment(\.duoLayout) private var duo
    @State private var frame: CGRect = .zero

    var body: some View {
        let wide = duo.isWideLayout
        // Flat or half-open: split at the fold (a top-to-bottom one), not at the middle.
        let fold: (CGFloat, CGFloat)? = duo.foldBand(in: frame).flatMap { c in
            c.height > c.width ? (c.minX, c.maxX) : nil
        }
        ProfilePanesLayout(fold: fold, gutter: DS.Spacing.lg) {
            ProfileView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if wide {
                ProfileSummaryPanel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

/// One subview: it fills the bounds. Two: side by side, split at the fold band (gutter / 2 each
/// side of it) when there is one, else in halves with a `gutter` gap.
private struct ProfilePanesLayout: Layout {
    var fold: (CGFloat, CGFloat)?
    var gutter: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            for s in subviews { s.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size)) }
            return
        }
        let w = bounds.width
        var firstEnd = fold.map { $0.0 - gutter / 2 } ?? (w / 2 - gutter / 2)
        let secondStart = fold.map { $0.1 + gutter / 2 } ?? (w / 2 + gutter / 2)
        let gap = max(0, secondStart - firstEnd)
        firstEnd = min(max(firstEnd, w / 4), w * 3 / 4 - gap)
        let start = firstEnd + gap
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: firstEnd, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + start, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: w - start, height: bounds.height))
    }
}

/// The wide Profile's second half: what's in the wardrobe and the log, and the
/// on-device promise.
private struct ProfileSummaryPanel: View {
    @EnvironmentObject private var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject private var outfitsViewModel: MyOutfitsViewModel

    private var loggedCount: Int {
        outfitsViewModel.outfitsByDate.values.reduce(0) { $0 + $1.count }
    }

    private var lastLogged: Date? { outfitsViewModel.outfitsByDate.keys.max() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                Text("Your wardrobe")
                    .font(DS.Font.title2)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, DS.Spacing.xxl)

                Grid(horizontalSpacing: DS.Spacing.sm, verticalSpacing: DS.Spacing.sm) {
                    GridRow {
                        stat("\(wardrobeViewModel.items.count)", "pieces", "hanger")
                        stat("\(ClosetEngine.counts(wardrobeViewModel.items).count)", "shelves", "square.grid.2x2")
                    }
                    GridRow {
                        stat("\(loggedCount)", loggedCount == 1 ? "outfit logged" : "outfits logged", "calendar")
                        stat(lastLogged.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "—",
                             "last logged", "clock")
                    }
                }

                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    Image(systemName: "lock.shield.fill")
                        .font(DS.Font.title3)
                        .foregroundStyle(DS.Colors.accent)
                    VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                        Text("Everything stays on your iPhone")
                            .font(DS.Font.headline)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text("Finding you in photos, cutting out your clothes and styling outfits all run on this device. Your wardrobe is backed up only to your own iCloud.")
                            .font(DS.Font.subheadline)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DS.Spacing.md)
                .background(DS.Colors.backgroundCard,
                            in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(.trailing, DS.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Same canvas as the settings list beside it.
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Image(systemName: icon)
                .font(DS.Font.subheadline.weight(.semibold))
                .foregroundStyle(DS.Colors.accent)
            Text(value)
                .font(DS.Font.title2)
                .foregroundStyle(DS.Colors.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.md)
        .background(DS.Colors.backgroundCard,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    MainTabView(showAddSheet: .constant(false))
        .environmentObject(WardrobeViewModel())
        .environmentObject(AuthService())
        .environmentObject(MyOutfitsViewModel())
        .environmentObject(OnboardingManager())
        .environmentObject(TutorialManager())
}
