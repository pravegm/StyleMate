import SwiftUI
import CoreData

struct IdentifiableDate: Identifiable, Equatable {
    let id: Date
}

/// A logged outfit as a sheet item.
struct OutfitRef: Identifiable {
    let outfit: DatedOutfit
    var id: NSManagedObjectID { outfit.objectID }
}

/// The outfit log. iPhone / cover display: a week strip (or the month, from the
/// toolbar) above the selected day's outfits, each a 2 × 2 cutout collage with
/// Edit / Delete on swipe and long-press. Wide (Duo inner display): the month
/// grid beside a two-column grid of the day's outfits.
struct MyOutfitsView: View {
    @EnvironmentObject var viewModel: MyOutfitsViewModel
    @EnvironmentObject var wardrobeVM: WardrobeViewModel
    @Environment(\.duoLayout) private var duo
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showAddSheet = false
    @State private var showDateJump = false
    @State private var editingOutfit: OutfitRef? = nil
    @State private var deletingOutfit: DatedOutfit? = nil
    @AppStorage("outfits.showMonth") private var showMonth = false

    private var isWide: Bool { duo.isWideLayout }

    private var dayOutfits: [DatedOutfit] {
        viewModel.outfitsByDate[selectedDate] ?? []
    }

    private var datesWithOutfits: Set<Date> { Set(viewModel.outfitsByDate.keys) }

    var body: some View {
        NavigationStack {
            Group {
                if isWide { wideLayout } else { phoneLayout }
            }
            .background(DS.Colors.backgroundPrimary.ignoresSafeArea())
            .navigationTitle("Outfits")
            .toolbar {
                if !isWide {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Haptics.selection()
                            withAnimation(DS.Motion.smooth) { showMonth.toggle() }
                        } label: {
                            Label(showMonth ? "Week" : "Month",
                                  systemImage: showMonth ? "calendar.day.timeline.left" : "calendar")
                        }
                        .accessibilityLabel(showMonth ? "Show week" : "Show month")
                        .accessibilityIdentifier("outfits.monthToggle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.light()
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel("Add outfit")
                    .accessibilityIdentifier("outfits.add")
                }
            }
            .onAppear {
                // Land on the day just logged from Home ("View in Calendar").
                if let logged = viewModel.lastLoggedDate { selectedDate = logged }
            }
            .onChange(of: viewModel.lastLoggedDate) { logged in
                if let logged { selectedDate = logged }
            }
            // The tab view lives for the whole session; keep "Today" honest past midnight.
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
                selectedDate = Calendar.current.startOfDay(for: Date())
            }
            .sheet(isPresented: $showAddSheet) {
                AddOutfitSheet(selectedDate: selectedDate) { items, notes in
                    viewModel.addOutfit(date: selectedDate, items: items, source: MyOutfitsViewModel.Source.manual, notes: notes)
                }
                .environmentObject(wardrobeVM)
            }
            .sheet(item: $editingOutfit) { ref in
                let outfit = ref.outfit
                AddOutfitSheet(selectedDate: outfit.date ?? Date(),
                               initialItems: Self.items(of: outfit),
                               initialNotes: outfit.notes ?? "") { items, notes in
                    viewModel.updateOutfit(outfit, items: items, notes: notes)
                }
                .environmentObject(wardrobeVM)
            }
            .sheet(isPresented: $showDateJump) {
                DateJumpSheet(selectedDate: $selectedDate, datesWithOutfits: datesWithOutfits)
            }
            .confirmationDialog("Delete this outfit?", isPresented: Binding(
                get: { deletingOutfit != nil }, set: { if !$0 { deletingOutfit = nil } }
            ), titleVisibility: .visible, presenting: deletingOutfit) { outfit in
                Button("Delete Outfit", role: .destructive) {
                    Haptics.warning()
                    viewModel.deleteOutfit(outfit)
                    deletingOutfit = nil
                }
                Button("Cancel", role: .cancel) { deletingOutfit = nil }
            } message: { _ in
                Text("It's removed from your log. The clothes stay in your wardrobe.")
            }
        }
    }

    // MARK: - Phone

    private var phoneLayout: some View {
        List {
            Section {
                calendarCard
                    .listRowInsets(EdgeInsets(top: DS.Spacing.xs, leading: DS.Spacing.screenH,
                                              bottom: DS.Spacing.xs, trailing: DS.Spacing.screenH))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                dayHeader
                    .listRowInsets(EdgeInsets(top: DS.Spacing.sm, leading: DS.Spacing.screenH,
                                              bottom: 0, trailing: DS.Spacing.screenH))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if dayOutfits.isEmpty {
                    emptyDay
                        .listRowInsets(EdgeInsets(top: DS.Spacing.xs, leading: DS.Spacing.screenH,
                                                  bottom: DS.Spacing.xs, trailing: DS.Spacing.screenH))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(dayOutfits, id: \.objectID) { outfit in
                        card(outfit)
                            .listRowInsets(EdgeInsets(top: DS.Spacing.xs, leading: DS.Spacing.screenH,
                                                      bottom: DS.Spacing.xs, trailing: DS.Spacing.screenH))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { deletingOutfit = outfit } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { editingOutfit = OutfitRef(outfit: outfit) } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(DS.Colors.accent)
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(DS.Motion.smooth, value: showMonth)
    }

    @ViewBuilder
    private var calendarCard: some View {
        Group {
            if showMonth {
                CalendarGridView(selectedDate: $selectedDate, datesWithOutfits: datesWithOutfits,
                                 onTitleTap: { showDateJump = true })
            } else {
                WeekStrip(selectedDate: $selectedDate, datesWithOutfits: datesWithOutfits,
                          onTitleTap: { showDateJump = true })
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.backgroundCard,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCardShadow()
        .coachAnchor(CoachAnchor.outfitsCalendar)
    }

    // MARK: - Wide


    /// Month | the day's outfits, split on the crease when half-open.
    private var wideLayout: some View {
        FoldAwareSplit(gutter: DS.Spacing.lg, stackedSpacing: 0, leadingFraction: 0.45) {
            ScrollView {
                CalendarGridView(selectedDate: $selectedDate, datesWithOutfits: datesWithOutfits,
                                 onTitleTap: { showDateJump = true })
                    .padding(DS.Spacing.md)
                    .background(DS.Colors.backgroundCard,
                                in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .dsCardShadow()
                    .coachAnchor(CoachAnchor.outfitsCalendar)
                    .frame(maxWidth: 480)
                    .padding(.vertical, DS.Spacing.md)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } trailing: {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    dayHeader
                    if dayOutfits.isEmpty {
                        emptyDay
                    } else {
                        // Fits the pane: one card per row in a half pane, two when roomy.
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: DS.Spacing.md, alignment: .top)],
                                  spacing: DS.Spacing.md) {
                            ForEach(dayOutfits, id: \.objectID) { outfit in card(outfit) }
                        }
                    }
                }
                .padding(.vertical, DS.Spacing.md)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, DS.Spacing.lg)
    }

    // MARK: - Pieces

    private var dayHeader: some View {
        Text(Calendar.current.isDateInToday(selectedDate)
             ? "Today's Outfits"
             : selectedDate.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            .font(DS.Font.title3)
            .foregroundStyle(DS.Colors.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private var emptyDay: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "hanger")
                .font(DS.Font.title3)
                .foregroundStyle(DS.Colors.accent)
                .frame(width: 44, height: 44)
                .background(DS.Colors.accentSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("No outfits logged")
                    .font(DS.Font.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("Wear one from Home, or tap + to log one")
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.backgroundCard,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }

    private func card(_ outfit: DatedOutfit) -> some View {
        OutfitCardView(outfit: outfit,
                       onEdit: { editingOutfit = OutfitRef(outfit: outfit) },
                       onDelete: { deletingOutfit = outfit })
    }

    /// The outfit's pieces in wearing order (outer layer → shoes → accessories).
    static func items(of outfit: DatedOutfit) -> [OutfitItem] {
        let all = (outfit.items as? Set<OutfitItem>) ?? []
        return all.sorted { a, b in
            let ca = Category(rawValue: a.category ?? "") ?? .tops
            let cb = Category(rawValue: b.category ?? "") ?? .tops
            if ca.wearingOrder != cb.wearingOrder { return ca.wearingOrder < cb.wearingOrder }
            return (a.product ?? "") < (b.product ?? "")
        }
    }
}

// MARK: - Outfit card

/// A logged outfit: a 2 × 2 cutout collage, what's in it, where it came from.
/// Edit / Delete are in the ⋯ menu, the long-press menu and (phone) swipe actions.
struct OutfitCardView: View {
    let outfit: DatedOutfit
    var onEdit: () -> Void
    var onDelete: () -> Void
    @ScaledMetric(relativeTo: .body) private var collageHeight: CGFloat = 160

    private var items: [OutfitItem] { MyOutfitsView.items(of: outfit) }

    /// Where a logged outfit came from: the stylist, the person's photos (auto-log),
    /// or the manual composer.
    static func badge(for source: String) -> (title: String, icon: String, tinted: Bool) {
        if source == WearLogSuggestions.source { return ("From your photos", "photo", true) }
        if MyOutfitsViewModel.Source.isStyled(source) { return ("Styled for you", "wand.and.stars", true) }
        return ("Manual", "hand.draw", false)
    }

    private var summary: String {
        items.compactMap { $0.product }.map { ClosetText.displayProduct($0) }.joined(separator: " · ")
    }

    var body: some View {
        let pieces = items
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            CutoutCollage(paths: pieces.map { OutfitItem.displayImagePath(for: $0) },
                          cornerRadius: DS.Radius.control)
                .frame(width: collageHeight, height: collageHeight)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                if let source = outfit.source {
                    let badge = Self.badge(for: source)
                    Label(badge.title, systemImage: badge.icon)
                        .font(DS.Font.caption1)
                        .foregroundStyle(badge.tinted ? DS.Colors.accent : DS.Colors.textSecondary)
                        .padding(.horizontal, DS.Spacing.xs)
                        .padding(.vertical, 3)
                        .background(badge.tinted ? DS.Colors.accentSoft : DS.Colors.fill, in: Capsule())
                }

                Text(summary)
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                if let notes = outfit.notes, !notes.isEmpty {
                    Text(notes)
                        .font(DS.Font.footnote)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Menu {
                        Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(DS.Font.headline)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Outfit actions")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Spacing.sm)
        .background(DS.Colors.backgroundCard,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCardShadow()
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .contextMenu {
            Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outfits.card")
    }
}

// MARK: - Week strip

/// Seven days with the selected one filled and a dot under days with a logged outfit.
struct WeekStrip: View {
    @Binding var selectedDate: Date
    let datesWithOutfits: Set<Date>
    var onTitleTap: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar { Calendar.current }

    private var weekDays: [Date] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: selectedDate) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
    }

    var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            HStack {
                Button(action: onTitleTap) {
                    HStack(spacing: 4) {
                        Text(selectedDate.formatted(.dateTime.month(.wide).year()))
                            .font(DS.Font.headline)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Image(systemName: "chevron.down")
                            .font(DS.Font.caption1.weight(.bold))
                            .foregroundStyle(DS.Colors.accent)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Pick a date")
                Spacer()
                if !calendar.isDateInToday(selectedDate) {
                    Button("Today") { move(to: calendar.startOfDay(for: Date())) }
                        .font(DS.Font.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Colors.accent)
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                }
                stepButton("chevron.left", label: "Previous week", by: -7)
                stepButton("chevron.right", label: "Next week", by: 7)
            }

            HStack(spacing: 4) {
                ForEach(weekDays, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
    }

    private func stepButton(_ symbol: String, label: String, by days: Int) -> some View {
        Button {
            if let d = calendar.date(byAdding: .day, value: days, to: selectedDate) { move(to: d) }
        } label: {
            Image(systemName: symbol)
                .font(DS.Font.headline)
                .foregroundStyle(DS.Colors.accent)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func move(to date: Date) {
        Haptics.selection()
        withAnimation(DSMotionEnv.resolve(DS.Motion.snappy, reduceMotion: reduceMotion)) {
            selectedDate = calendar.startOfDay(for: date)
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: selectedDate)
        let today = calendar.isDateInToday(day)
        let logged = datesWithOutfits.contains(calendar.startOfDay(for: day))
        return Button {
            move(to: day)
        } label: {
            VStack(spacing: 4) {
                Text(day.formatted(.dateTime.weekday(.narrow)))
                    .font(DS.Font.caption2)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : DS.Colors.textSecondary)
                Text("\(calendar.component(.day, from: day))")
                    .font(DS.Font.headline)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white : (today ? DS.Colors.accent : DS.Colors.textPrimary))
                Circle()
                    .fill(logged ? (selected ? Color.white : DS.Colors.accent) : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.xs)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.accent)
                } else if today {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.accentSoft)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + (logged ? ", outfit logged" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("outfits.day.\(Self.dayKey(day))")
    }

    static func dayKey(_ day: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }
}

// MARK: - Date jump (graphical picker)

private struct DateJumpSheet: View {
    @Binding var selectedDate: Date
    let datesWithOutfits: Set<Date>
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Date()

    var body: some View {
        NavigationStack {
            DatePicker("Date", selection: $draft, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .tint(DS.Colors.accent)
                .padding(.horizontal, DS.Spacing.md)
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("Go to date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Go") {
                            selectedDate = Calendar.current.startOfDay(for: draft)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
        }
        .presentationDetents([.large])
        .onAppear { draft = selectedDate }
    }
}

// MARK: - Add Outfit Sheet (composer)

struct AddOutfitSheet: View {
    let selectedDate: Date
    var onSave: ([WardrobeItem], String?) -> Void
    var initialItems: [OutfitItem]? = nil
    var initialNotes: String? = nil
    @EnvironmentObject var wardrobeVM: WardrobeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSavedOverlay = false
    @State private var selectedItems: Set<WardrobeItem> = []
    @State private var notes: String = ""
    @State private var shelf: ClosetSection? = nil
    @State private var previewItem: WardrobeItem? = nil
    @Environment(\.duoLayout) private var duo

    private static let maxPieces = 10

    /// Shelves that have something on them, in closet order.
    private var groups: [ClosetGroup] {
        ClosetEngine.grouped(Array(wardrobeVM.items.reversed()))
    }

    private var currentShelf: ClosetSection? { shelf ?? groups.first?.section }

    private var shelfItems: [WardrobeItem] {
        groups.first(where: { $0.section == currentShelf })?.items ?? []
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: duo.isWideLayout ? 6 : 3)
    }

    private func toggle(_ item: WardrobeItem) {
        if selectedItems.contains(item) {
            Haptics.light()
            withAnimation(DS.Motion.snappy) { _ = selectedItems.remove(item) }
        } else if selectedItems.count < Self.maxPieces {
            Haptics.selection()
            withAnimation(DS.Motion.snappy) { _ = selectedItems.insert(item) }
        } else {
            Haptics.warning()
        }
    }

    public init(selectedDate: Date, initialItems: [OutfitItem]? = nil, initialNotes: String? = nil, onSave: @escaping ([WardrobeItem], String?) -> Void) {
        self.selectedDate = selectedDate
        self.onSave = onSave
        self.initialItems = initialItems
        self.initialNotes = initialNotes
    }

    /// Selected pieces in wearing order, for the tray.
    private var selectedInOrder: [WardrobeItem] {
        selectedItems.sorted { a, b in
            if a.category.wearingOrder != b.category.wearingOrder { return a.category.wearingOrder < b.category.wearingOrder }
            return a.id.uuidString < b.id.uuidString
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    Text("Pick up to \(Self.maxPieces) pieces for \(selectedDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(DS.Font.subheadline)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .padding(.top, DS.Spacing.xs)

                    LazyVGrid(columns: gridColumns, spacing: 10) {
                        ForEach(shelfItems) { item in
                            pieceCell(item)
                        }
                    }
                    .animation(DS.Motion.snappy, value: currentShelf)

                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("Notes (optional)")
                            .font(DS.Font.footnote)
                            .foregroundStyle(DS.Colors.textSecondary)
                        TextField("Add any notes for this outfit…", text: $notes)
                            .font(DS.Font.body)
                            .padding(DS.Spacing.sm)
                            .background(DS.Colors.backgroundSecondary,
                                        in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .foregroundStyle(DS.Colors.textPrimary)
                    }
                    .padding(.top, DS.Spacing.sm)
                }
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.bottom, DS.Spacing.xl)
            }
            .background(DS.Colors.backgroundPrimary.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) { shelfBar }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .overlay {
                if showSavedOverlay {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(DS.Font.title3)
                        .foregroundStyle(.white)
                        .padding(.vertical, DS.Spacing.md)
                        .padding(.horizontal, DS.Spacing.xl)
                        .background(DS.Colors.success, in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .navigationTitle("Add Outfit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $previewItem) { item in
                FullItemImageViewer(path: item.fullImagePath, fallbackPath: item.gridImagePath,
                                    title: ClosetText.displayName(item))
            }
            .onAppear {
                if let initialItems = initialItems {
                    let wardrobeItems = wardrobeVM.items.filter { wi in
                        initialItems.contains(where: { $0.id == wi.id })
                    }
                    selectedItems = Set(wardrobeItems)
                }
                if let initialNotes = initialNotes { notes = initialNotes }
            }
        }
    }

    /// Shelf tabs, pinned under the title.
    private var shelfBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(groups) { group in
                    let picked = group.items.filter { selectedItems.contains($0) }.count
                    // A check replaces the shelf glyph once something on it is picked.
                    ClosetChip(title: group.section.chipTitle,
                               systemImage: picked > 0 ? "checkmark.circle.fill" : group.section.iconName,
                               count: group.items.count,
                               isSelected: currentShelf == group.section) {
                        withAnimation(DS.Motion.snappy) { shelf = group.section }
                    }
                    .accessibilityLabel("\(group.section.chipTitle), \(group.items.count) items" +
                                        (picked > 0 ? ", \(picked) picked" : ""))
                    .accessibilityIdentifier("composer.shelf.\(group.section.rawValue)")
                }
            }
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.vertical, DS.Spacing.xs)
        }
        .background(.bar)
    }

    /// One piece: the closet tile with a check, tap to pick, long-press to view.
    private func pieceCell(_ item: WardrobeItem) -> some View {
        let picked = selectedItems.contains(item)
        return Button {
            toggle(item)
        } label: {
            ClosetItemCell(item: item, isSelecting: true, isSelected: picked, showsCaption: true)
        }
        .buttonStyle(DSTapBounce())
        .accessibilityIdentifier("composer.item.\(item.id.uuidString)")
        .contextMenu {
            Button { toggle(item) } label: {
                Label(picked ? "Remove from outfit" : "Add to outfit", systemImage: picked ? "minus.circle" : "plus.circle")
            }
            Button { previewItem = item } label: {
                Label("View larger", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
    }

    /// The "Selected (n)" tray pinned above Save, so the pick is always visible.
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if !selectedItems.isEmpty {
                Text("Selected (\(selectedItems.count))")
                    .font(DS.Font.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(selectedInOrder) { item in
                            Button {
                                Haptics.light()
                                withAnimation(DS.Motion.snappy) { _ = selectedItems.remove(item) }
                            } label: {
                                AsyncItemTile(path: item.gridImagePath, height: 52, cornerRadius: DS.Radius.chip, inset: 4)
                                    .frame(width: 52)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 15))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(Color.white, Color.black.opacity(0.45))
                                            .offset(x: 4, y: -4)
                                    }
                            }
                            .buttonStyle(DSTapBounce())
                            .accessibilityLabel("\(ClosetText.displayName(item)), selected")
                            .accessibilityHint("Double-tap to remove it from the outfit")
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.top, 4)
                    .padding(.horizontal, 2)
                }
                .accessibilityIdentifier("outfits.composer.tray")
            }

            Button {
                onSave(Array(selectedItems), notes.isEmpty ? nil : notes)
                Haptics.success()
                withAnimation(DS.Motion.snappy) { showSavedOverlay = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    showSavedOverlay = false
                    dismiss()
                }
            } label: {
                Label("Save Outfit", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(DSPrimaryButton(isDisabled: selectedItems.isEmpty))
            .disabled(selectedItems.isEmpty)
            .accessibilityIdentifier("outfits.composer.save")
        }
        .padding(.horizontal, DS.Spacing.screenH)
        .padding(.vertical, DS.Spacing.sm)
        .background(.bar)
        .animation(DS.Motion.snappy, value: selectedItems.count)
    }
}

// MARK: - Calendar Grid

struct CalendarGridView: View {
    @Binding var selectedDate: Date
    let datesWithOutfits: Set<Date>
    var onDateWithOutfitsTapped: ((Date) -> Void)? = nil
    var onTitleTap: () -> Void = {}
    @State private var currentMonth: Date = Calendar.current.startOfDay(for: Date())
    @State private var slideDirection: Edge = .trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var dayCircle: CGFloat = 36

    var body: some View {
        calendarContent
    }

    @ViewBuilder
    private var calendarContent: some View {
        let calendar = Calendar.current
        if let monthInterval = calendar.dateInterval(of: .month, for: currentMonth) ?? calendar.dateInterval(of: .month, for: Date()),
           let dayRange = calendar.range(of: .day, in: .month, for: currentMonth) {
            let days = (0..<dayRange.count).compactMap {
                calendar.date(byAdding: .day, value: $0, to: monthInterval.start)
            }

            VStack(spacing: DS.Spacing.xs) {
                HStack {
                    Button(action: onTitleTap) {
                        HStack(spacing: 4) {
                            Text(currentMonth.formatted(.dateTime.month(.wide).year()))
                                .font(DS.Font.headline)
                                .foregroundStyle(DS.Colors.textPrimary)
                            Image(systemName: "chevron.down")
                                .font(DS.Font.caption1.weight(.bold))
                                .foregroundStyle(DS.Colors.accent)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Pick a date")

                    Spacer()

                    monthButton("chevron.left", label: "Previous month", by: -1, edge: .leading)
                    monthButton("chevron.right", label: "Next month", by: 1, edge: .trailing)
                }

                HStack {
                    ForEach(Array(calendar.veryShortStandaloneWeekdaySymbols.rotated(by: calendar.firstWeekday - 1).enumerated()),
                            id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(DS.Font.caption2)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
                .accessibilityHidden(true)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: DS.Spacing.xs) {
                    let firstWeekday = calendar.component(.weekday, from: monthInterval.start) - calendar.firstWeekday
                    let leadingEmpty = (firstWeekday + 7) % 7

                    ForEach(0..<(leadingEmpty + days.count), id: \.self) { idx in
                        if idx < leadingEmpty {
                            Color.clear.frame(height: dayCircle + 8)
                        } else {
                            dayButton(days[idx - leadingEmpty], calendar: calendar)
                        }
                    }
                }
                .id(currentMonth)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.asymmetric(
                    insertion: .move(edge: slideDirection),
                    removal: .move(edge: slideDirection == .trailing ? .leading : .trailing)
                ))
            }
            .clipped()
            .onAppear {
                currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate)) ?? Calendar.current.startOfDay(for: Date())
            }
            .onChange(of: selectedDate) { newDate in
                let newMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: newDate)) ?? currentMonth
                if !calendar.isDate(newMonth, inSameDayAs: currentMonth) { currentMonth = newMonth }
            }
        } else {
            EmptyView()
        }
    }

    private func monthButton(_ symbol: String, label: String, by months: Int, edge: Edge) -> some View {
        Button {
            slideDirection = edge
            withAnimation(DSMotionEnv.resolve(.easeInOut(duration: 0.25), reduceMotion: reduceMotion)) {
                if let d = Calendar.current.date(byAdding: .month, value: months, to: currentMonth) { currentMonth = d }
            }
        } label: {
            Image(systemName: symbol)
                .font(DS.Font.headline)
                .foregroundStyle(DS.Colors.accent)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func dayButton(_ date: Date, calendar: Calendar) -> some View {
        let hasOutfit = datesWithOutfits.contains(calendar.startOfDay(for: date))
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        return Button {
            Haptics.selection()
            withAnimation(DSMotionEnv.resolve(.spring(response: 0.3, dampingFraction: 0.7), reduceMotion: reduceMotion)) {
                selectedDate = calendar.startOfDay(for: date)
            }
            if hasOutfit { onDateWithOutfitsTapped?(calendar.startOfDay(for: date)) }
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: date))")
                    .font(DS.Font.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white : (isToday ? DS.Colors.accent : DS.Colors.textPrimary))
                    .frame(width: dayCircle, height: dayCircle)
                    .background(
                        isSelected
                            ? AnyShapeStyle(DS.Colors.accent)
                            : (isToday ? AnyShapeStyle(DS.Colors.accentSoft) : AnyShapeStyle(Color.clear)),
                        in: Circle()
                    )
                Circle()
                    .fill(hasOutfit ? DS.Colors.accent : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted) + (hasOutfit ? ", outfit logged" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("outfits.day.\(WeekStrip.dayKey(date))")
    }
}

private extension Array {
    /// The array rotated left by `n` (weekday symbols starting at the locale's first day).
    func rotated(by n: Int) -> [Element] {
        guard !isEmpty else { return self }
        let k = ((n % count) + count) % count
        return Array(self[k...] + self[..<k])
    }
}

// MARK: - Core Data OutfitItem images

extension OutfitItem {
    /// The file the outfit log shows for this piece (cutout, else the photo).
    /// Loaded asynchronously by the views through `ClosetImageLoader`; if the
    /// view model gains its own thumbnail copies, swap them in here.
    static func displayImagePath(for item: OutfitItem) -> String? {
        item.croppedImagePath ?? item.imagePath
    }

    var image: UIImage? {
        if let path = self.imagePath { return WardrobeImageFileHelper.loadImage(at: path) }
        return nil
    }
    var croppedImage: UIImage? {
        if let path = self.croppedImagePath { return WardrobeImageFileHelper.loadImage(at: path) }
        return nil
    }
}
