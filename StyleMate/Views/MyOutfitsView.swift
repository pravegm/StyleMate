import SwiftUI

struct IdentifiableDate: Identifiable, Equatable {
    let id: Date
}

struct MyOutfitsView: View {
    @EnvironmentObject var viewModel: MyOutfitsViewModel
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showAddSheet = false
    @EnvironmentObject var wardrobeVM: WardrobeViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    // Today indicator
                    if Calendar.current.isDateInToday(selectedDate) {
                        HStack(spacing: DS.Spacing.xs) {
                            Circle()
                                .fill(DS.Colors.accent)
                                .frame(width: 8, height: 8)
                            Text("Today")
                                .font(DS.Font.caption1)
                                .foregroundColor(DS.Colors.accent)
                        }
                        .padding(.bottom, DS.Spacing.xs)
                    }

                    // Calendar card
                    CalendarGridView(
                        selectedDate: $selectedDate,
                        datesWithOutfits: Set(viewModel.outfitsByDate.keys)
                    )
                    .padding(DS.Spacing.md)
                    .background(DS.Colors.backgroundCard)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                    .dsCardShadow()

                    // Selected date outfits
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        HStack {
                            Text(Calendar.current.isDateInToday(selectedDate) ? "Today's Outfits" : dateFormatter.string(from: selectedDate))
                                .font(DS.Font.headline)
                                .foregroundColor(DS.Colors.textPrimary)
                            Spacer()
                            Button(action: { showAddSheet = true }) {
                                HStack(spacing: DS.Spacing.micro) {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Add")
                                        .font(DS.Font.subheadline)
                                }
                                .foregroundColor(DS.Colors.accent)
                                .padding(.vertical, DS.Spacing.xs)
                                .padding(.horizontal, DS.Spacing.sm)
                                .contentShape(Rectangle())
                            }
                        }

                        if let outfits = viewModel.outfitsByDate[selectedDate], !outfits.isEmpty {
                            ForEach(outfits, id: \.objectID) { outfit in
                                OutfitCardView(outfit: outfit, viewModel: viewModel)
                                    .environmentObject(wardrobeVM)
                            }
                        } else {
                            HStack(spacing: DS.Spacing.sm) {
                                Image(systemName: "hanger")
                                    .font(DS.Font.title3)
                                    .foregroundColor(DS.Colors.textTertiary)
                                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                                    Text("No outfits logged")
                                        .font(DS.Font.subheadline)
                                        .foregroundColor(DS.Colors.textSecondary)
                                    Text("Generate one from Home or add manually")
                                        .font(DS.Font.caption1)
                                        .foregroundColor(DS.Colors.textTertiary)
                                }
                            }
                            .padding(DS.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.Colors.backgroundCard)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                            .dsCardShadow()
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.top, DS.Spacing.md)
                .padding(.bottom, 100)
            }
            .background(DS.Colors.backgroundPrimary)
            .navigationTitle("Outfits")
            .sheet(isPresented: $showAddSheet) {
                AddOutfitSheet(selectedDate: selectedDate) { items, notes in
                    viewModel.addOutfit(date: selectedDate, items: items, source: "manual", notes: notes)
                }
                .environmentObject(wardrobeVM)
            }
        }
    }
}

// MARK: - Add Outfit Sheet

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
    @State private var expandedCategories: Set<Category> = []
    @State private var expandedProducts: Set<String> = []
    @State private var previewImage: PreviewImage? = nil

    private var groupedItems: [(category: Category, products: [(product: String, items: [WardrobeItem])])] {
        let itemsByCategory = Dictionary(grouping: wardrobeVM.items, by: { $0.category })
        return Category.allCases.compactMap { category in
            guard let items = itemsByCategory[category], !items.isEmpty else { return nil }
            let products = Dictionary(grouping: items, by: { $0.product })
                .map { (product: $0.key, items: $0.value) }
                .sorted { $0.product.localizedCaseInsensitiveCompare($1.product) == .orderedAscending }
            return (category: category, products: products)
        }
    }

    public init(selectedDate: Date, initialItems: [OutfitItem]? = nil, initialNotes: String? = nil, onSave: @escaping ([WardrobeItem], String?) -> Void) {
        self.selectedDate = selectedDate
        self.onSave = onSave
        self.initialItems = initialItems
        self.initialNotes = initialNotes
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                DS.Colors.backgroundPrimary.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        Text("Select up to 10 items for your outfit on \(selectedDate, formatter: dateFormatter)")
                            .font(DS.Font.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.top, DS.Spacing.xs)

                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Text("Notes (optional)")
                                .font(DS.Font.caption1)
                                .foregroundColor(DS.Colors.textTertiary)
                            TextField("Add any notes for this outfit…", text: $notes)
                                .font(DS.Font.body)
                                .textFieldStyle(.roundedBorder)
                        }

                        OutfitItemSelectionList(
                            selectedItems: $selectedItems,
                            expandedCategories: $expandedCategories,
                            expandedProducts: $expandedProducts,
                            previewImage: $previewImage
                        )
                        .environmentObject(wardrobeVM)

                        Spacer(minLength: 80)
                    }
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.top, DS.Spacing.xs)
                    .padding(.bottom, 100)
                }

                // Bottom bar
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(DSSecondaryButton())

                    Button(action: {
                        onSave(Array(selectedItems), notes.isEmpty ? nil : notes)
                        Haptics.success()
                        showSavedOverlay = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            showSavedOverlay = false
                            dismiss()
                        }
                    }) {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Save Outfit")
                        }
                    }
                    .buttonStyle(DSPrimaryButton(isDisabled: selectedItems.isEmpty))
                    .disabled(selectedItems.isEmpty)
                }
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.vertical, DS.Spacing.sm)
                .dsGlassBar()

                if showSavedOverlay {
                    VStack {
                        Spacer()
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(DS.Font.title3)
                            .foregroundColor(.white)
                            .padding(.vertical, DS.Spacing.md)
                            .padding(.horizontal, DS.Spacing.xl)
                            .background(DS.Colors.success)
                            .clipShape(Capsule())
                        Spacer()
                    }
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
            .navigationTitle("Add Outfit")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $previewImage) { wrapper in
                VStack {
                    Spacer()
                    ZoomableImage(image: wrapper.image).padding()
                    Spacer()
                    Button("Close") { previewImage = nil }
                        .buttonStyle(DSSecondaryButton())
                        .padding(.horizontal, DS.Spacing.screenH)
                        .padding(.bottom, DS.Spacing.lg)
                }
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
}

// MARK: - Calendar Grid

struct CalendarGridView: View {
    @Binding var selectedDate: Date
    let datesWithOutfits: Set<Date>
    var onDateWithOutfitsTapped: ((Date) -> Void)? = nil
    @State private var currentMonth: Date = Calendar.current.startOfDay(for: Date())
    @State private var showYearPicker = false

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
            let monthYearFormatter: DateFormatter = {
                let df = DateFormatter()
                df.dateFormat = "LLLL yyyy"
                return df
            }()

            VStack(spacing: DS.Spacing.xs) {
                HStack {
                    Button(action: {
                        if let prev = calendar.date(byAdding: .month, value: -1, to: currentMonth) { currentMonth = prev }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(DS.Font.headline)
                            .foregroundColor(DS.Colors.accent)
                            .padding(DS.Spacing.xs)
                    }

                    Spacer()

                    Button(action: { showYearPicker = true }) {
                        Text(monthYearFormatter.string(from: currentMonth))
                            .font(DS.Font.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    .sheet(isPresented: $showYearPicker) {
                        YearMonthPicker(selectedDate: $currentMonth, isPresented: $showYearPicker)
                    }

                    Spacer()

                    Button(action: {
                        if let next = calendar.date(byAdding: .month, value: 1, to: currentMonth) { currentMonth = next }
                    }) {
                        Image(systemName: "chevron.right")
                            .font(DS.Font.headline)
                            .foregroundColor(DS.Colors.accent)
                            .padding(DS.Spacing.xs)
                    }
                }

                HStack {
                    ForEach(calendar.shortWeekdaySymbols, id: \.self) { symbol in
                        Text(symbol)
                            .font(DS.Font.caption2)
                            .frame(maxWidth: .infinity)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: DS.Spacing.xs) {
                    let firstWeekday = calendar.component(.weekday, from: monthInterval.start) - calendar.firstWeekday
                    let leadingEmpty = (firstWeekday + 7) % 7

                    ForEach(0..<(leadingEmpty + days.count), id: \.self) { idx in
                        if idx < leadingEmpty {
                            Color.clear.frame(height: 44)
                        } else {
                            let date = days[idx - leadingEmpty]
                            let hasOutfit = datesWithOutfits.contains(calendar.startOfDay(for: date))
                            let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
                            let isToday = calendar.isDateInToday(date)

                            Button(action: {
                                Haptics.selection()
                                selectedDate = calendar.startOfDay(for: date)
                                if hasOutfit { onDateWithOutfitsTapped?(calendar.startOfDay(for: date)) }
                            }) {
                                VStack(spacing: 2) {
                                    Text("\(calendar.component(.day, from: date))")
                                        .font(DS.Font.subheadline)
                                        .foregroundColor(isSelected ? .white : (isToday ? DS.Colors.accent : DS.Colors.textPrimary))
                                        .frame(width: 36, height: 36)
                                        .background(
                                            isSelected
                                                ? AnyShapeStyle(DS.Colors.accent)
                                                : (isToday ? AnyShapeStyle(DS.Colors.accent.opacity(0.15)) : AnyShapeStyle(Color.clear))
                                            , in: Circle()
                                        )

                                    if hasOutfit {
                                        Circle()
                                            .fill(DS.Colors.accent)
                                            .frame(width: 6, height: 6)
                                    } else {
                                        Color.clear.frame(width: 6, height: 6)
                                    }
                                }
                            }
                            .frame(height: 44)
                        }
                    }
                }
            }
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
}

// MARK: - Year Month Picker

struct YearMonthPicker: View {
    @Binding var selectedDate: Date
    @Binding var isPresented: Bool
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var selectedMonth: Int = Calendar.current.component(.month, from: Date())
    let years: [Int] = Array(1970...2100)

    var body: some View {
        NavigationView {
            VStack(spacing: DS.Spacing.md) {
                Picker("Year", selection: $selectedYear) {
                    ForEach(years, id: \.self) { year in
                        Text("\(year)").tag(year)
                    }
                }
                .pickerStyle(WheelPickerStyle())

                Picker("Month", selection: $selectedMonth) {
                    ForEach(1...12, id: \.self) { month in
                        Text(DateFormatter().monthSymbols[month - 1]).tag(month)
                    }
                }
                .pickerStyle(WheelPickerStyle())

                Spacer()

                Button("Select") {
                    if let newDate = Calendar.current.date(from: DateComponents(year: selectedYear, month: selectedMonth, day: 1)) {
                        selectedDate = newDate
                    }
                    isPresented = false
                }
                .buttonStyle(DSPrimaryButton())

                Button("Cancel") { isPresented = false }
                    .buttonStyle(DSTertiaryButton())
            }
            .padding(DS.Spacing.screenH)
            .navigationTitle("Select Year & Month")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                selectedYear = Calendar.current.component(.year, from: selectedDate)
                selectedMonth = Calendar.current.component(.month, from: selectedDate)
            }
        }
    }
}

// MARK: - Outfit Card

struct OutfitCardView: View {
    let outfit: DatedOutfit
    @ObservedObject var viewModel: MyOutfitsViewModel
    @State private var previewImage: PreviewImage? = nil
    @State private var showEditSheet = false
    @State private var showDeleteAlert = false
    @EnvironmentObject var wardrobeVM: WardrobeViewModel

    private var allItems: [OutfitItem] {
        (outfit.items as? Set<OutfitItem>)?.sorted { ($0.product ?? "") < ($1.product ?? "") } ?? []
    }

    private var sortedItems: [OutfitItem] {
        allItems.sorted { item1, item2 in
            let cat1 = Category(rawValue: item1.category ?? "") ?? .tops
            let cat2 = Category(rawValue: item2.category ?? "") ?? .tops
            return cat1.wearingOrder < cat2.wearingOrder
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.sm) {
                    ForEach(sortedItems, id: \.objectID) { item in
                        Button(action: {
                            if let img = item.croppedImage ?? item.image {
                                previewImage = PreviewImage(image: img)
                            }
                        }) {
                            VStack(spacing: DS.Spacing.micro) {
                                if let img = item.croppedImage ?? item.image {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                                } else {
                                    RoundedRectangle(cornerRadius: DS.Radius.button)
                                        .fill(DS.Colors.backgroundSecondary)
                                        .frame(width: 72, height: 72)
                                        .overlay(
                                            Image(systemName: "photo")
                                                .foregroundColor(DS.Colors.textTertiary)
                                        )
                                }
                                Text(item.product ?? "")
                                    .font(DS.Font.caption2)
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, DS.Spacing.xs)
            }

            HStack {
                if let source = outfit.source {
                    HStack(spacing: DS.Spacing.micro) {
                        Image(systemName: source == "gemini" ? "wand.and.stars" : "hand.draw")
                            .font(DS.Font.caption2)
                        Text(source == "gemini" ? "AI Suggested" : "Manual")
                            .font(DS.Font.caption2)
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }

                if let notes = outfit.notes, !notes.isEmpty {
                    Text(notes)
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: { showEditSheet = true }) {
                    Image(systemName: "pencil.circle")
                        .font(DS.Font.title3)
                        .foregroundColor(DS.Colors.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }

                Button(action: { showDeleteAlert = true }) {
                    Image(systemName: "trash.circle")
                        .font(DS.Font.title3)
                        .foregroundColor(DS.Colors.error)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .dsCardShadow()
        .sheet(item: $previewImage) { wrapper in
            VStack {
                Spacer()
                ZoomableImage(image: wrapper.image).padding()
                Spacer()
                Button("Close") { previewImage = nil }
                    .buttonStyle(DSSecondaryButton())
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.bottom, DS.Spacing.lg)
            }
        }
        .sheet(isPresented: $showEditSheet) {
            AddOutfitSheet(selectedDate: outfit.date ?? Date(),
                          initialItems: allItems,
                          initialNotes: outfit.notes ?? "") { items, notes in
                viewModel.updateOutfit(outfit, items: items, notes: notes)
                showEditSheet = false
            }
            .environmentObject(wardrobeVM)
        }
        .alert(isPresented: $showDeleteAlert) {
            Alert(
                title: Text("Delete Outfit?"),
                message: Text("Are you sure you want to delete this outfit?"),
                primaryButton: .destructive(Text("Delete")) { viewModel.deleteOutfit(outfit) },
                secondaryButton: .cancel()
            )
        }
    }
}

// MARK: - Date Formatter

private let dateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .medium
    return df
}()

// MARK: - Core Data OutfitItem Extensions

extension OutfitItem {
    var image: UIImage? {
        if let path = self.imagePath { return WardrobeImageFileHelper.loadImage(at: path) }
        return nil
    }
    var croppedImage: UIImage? {
        if let path = self.croppedImagePath { return WardrobeImageFileHelper.loadImage(at: path) }
        return nil
    }
}

