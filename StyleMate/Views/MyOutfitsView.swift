import SwiftUI

struct IdentifiableDate: Identifiable, Equatable {
    let id: Date
}

struct MyOutfitsView: View {
    @StateObject private var viewModel = MyOutfitsViewModel()
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showAddSheet = false
    @EnvironmentObject var wardrobeVM: WardrobeViewModel
    
    var body: some View {
        ZStack {
            // Soft gradient background
            LinearGradient(
                colors: [Color.pink.opacity(0.13), Color.blue.opacity(0.13), Color.yellow.opacity(0.13)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text("My Outfits")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .padding(.leading, 20)
                    Spacer()
                }
                .padding(.top, 16)
                .padding(.bottom, 8)
                Text("See, add, and manage your looks")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 24) {
                        // Today's Outfits Card
                        HomeCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Today's Outfits")
                                    .font(.title2.bold())
                                    .foregroundColor(.accentColor)
                                    .padding(.bottom, 2)
                                if let todaysOutfits = viewModel.outfitsByDate[Calendar.current.startOfDay(for: Date())], !todaysOutfits.isEmpty {
                                    VStack(spacing: 16) {
                                        ForEach(todaysOutfits, id: \.objectID) { outfit in
                                            OutfitCardView(outfit: outfit, viewModel: viewModel)
                                                .environmentObject(wardrobeVM)
                                        }
                                    }
                                } else {
                                    Text("No outfit mapped for today. Add one!")
                                        .foregroundColor(.secondary)
                                        .padding(.bottom, 8)
                                }
                            }
                        }
                        // Calendar Card
                        HomeCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Outfit Calendar")
                                    .font(.title2.bold())
                                    .foregroundColor(.accentColor)
                                    .padding(.bottom, 2)
                                CalendarGridView(
                                    selectedDate: $selectedDate,
                                    datesWithOutfits: Set(viewModel.outfitsByDate.keys)
                                )
                            }
                            .padding(.bottom, 2)
                        }
                        // Add Outfit Button Card
                        HomeCard {
                            Button(action: {
                                showAddSheet = true
                            }) {
                                Label("Add Outfit to Selected Date", systemImage: "plus")
                                    .font(.headline)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        LinearGradient(colors: [Color.accentColor, Color.pink.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                        }
                        // Outfits for selected date (if any)
                        if let outfits = viewModel.outfitsByDate[selectedDate], !outfits.isEmpty {
                            HomeCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Outfits for \(dateFormatter.string(from: selectedDate))")
                                        .font(.title3.bold())
                                        .foregroundColor(.accentColor)
                                    ForEach(outfits, id: \.objectID) { outfit in
                                        OutfitCardView(outfit: outfit, viewModel: viewModel)
                                            .environmentObject(wardrobeVM)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 0)
                    .padding(.bottom, 120)
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddOutfitSheet(selectedDate: selectedDate) { items, notes in
                viewModel.addOutfit(date: selectedDate, items: items, source: "manual", notes: notes)
            }
            .environmentObject(wardrobeVM)
        }
    }
}

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
    
    // Helper to group items by category and product
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Select up to 10 items for your outfit on \(selectedDate, formatter: dateFormatter)")
                            .font(.headline)
                            .padding(.top, 8)
                            .padding(.horizontal, 8)
                        // Notes field (moved up)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notes (optional)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            TextField("Add any notes for this outfit...", text: $notes)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                        // Outfit item selection list
                        OutfitItemSelectionList(
                            selectedItems: $selectedItems,
                            expandedCategories: $expandedCategories,
                            expandedProducts: $expandedProducts,
                            previewImage: $previewImage
                        )
                        .environmentObject(wardrobeVM)
                        Spacer(minLength: 60)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 80)
                }
                // Sticky Save/Cancel bar
                HStack {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.red)
                        .font(.headline)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 18)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
                    Spacer()
                    Button(action: {
                        onSave(Array(selectedItems), notes.isEmpty ? nil : notes)
                        showSavedOverlay = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            showSavedOverlay = false
                            dismiss()
                        }
                    }) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Save Outfit")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 24)
                        .background(selectedItems.isEmpty ? Color.gray.opacity(0.5) : Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(selectedItems.isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 0)
                .background(Color(.systemBackground))
                // Overlay
                if showSavedOverlay {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(.title2.bold())
                                .padding(.vertical, 18)
                                .padding(.horizontal, 32)
                                .background(Color.green.opacity(0.95))
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                                .shadow(radius: 10)
                            Spacer()
                        }
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
                    ZoomableImage(image: wrapper.image)
                        .padding()
                    Spacer()
                    Button("Close") { previewImage = nil }
                        .font(.headline)
                        .padding()
                }
            }
            .onAppear {
                if let initialItems = initialItems {
                    // Convert OutfitItem to WardrobeItem by matching id
                    let wardrobeItems = wardrobeVM.items.filter { wi in
                        initialItems.contains(where: { $0.id == wi.id })
                    }
                    selectedItems = Set(wardrobeItems)
                }
                if let initialNotes = initialNotes {
                    notes = initialNotes
                }
            }
        }
    }
}

// Update CalendarGridView to accept onDateWithOutfitsTapped
struct CalendarGridView: View {
    @Binding var selectedDate: Date
    let datesWithOutfits: Set<Date>
    var onDateWithOutfitsTapped: ((Date) -> Void)? = nil
    @State private var currentMonth: Date = Calendar.current.startOfDay(for: Date())
    @State private var showYearPicker = false
    
    var body: some View {
        let calendar = Calendar.current
        let monthInterval = calendar.dateInterval(of: .month, for: currentMonth) ?? calendar.dateInterval(of: .month, for: Date())!
        let days = (0..<(calendar.range(of: .day, in: .month, for: currentMonth)!.count)).compactMap {
            calendar.date(byAdding: .day, value: $0, to: monthInterval.start)
        }
        let monthYearFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateFormat = "LLLL yyyy"
            return df
        }()
        VStack(spacing: 8) {
            HStack {
                Button(action: {
                    if let prevMonth = calendar.date(byAdding: .month, value: -1, to: currentMonth) {
                        currentMonth = prevMonth
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                        .padding(6)
                }
                Spacer()
                Button(action: { showYearPicker = true }) {
                    Text(monthYearFormatter.string(from: currentMonth))
                        .font(.headline)
                        .padding(.horizontal, 8)
                }
                .sheet(isPresented: $showYearPicker) {
                    YearMonthPicker(selectedDate: $currentMonth, isPresented: $showYearPicker)
                }
                Spacer()
                Button(action: {
                    if let nextMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth) {
                        currentMonth = nextMonth
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .font(.title3)
                        .padding(6)
                }
            }
            .padding(.horizontal, 8)
            // Weekday headers
            HStack {
                ForEach(calendar.shortWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2)
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.secondary)
                }
            }
            // Calendar grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                let firstWeekday = calendar.component(.weekday, from: monthInterval.start) - calendar.firstWeekday
                let leadingEmpty = (firstWeekday + 7) % 7
                ForEach(0..<(leadingEmpty + days.count), id: \.self) { idx in
                    if idx < leadingEmpty {
                        Color.clear.frame(height: 36)
                    } else {
                        let date = days[idx - leadingEmpty]
                        let hasOutfit = datesWithOutfits.contains(calendar.startOfDay(for: date))
                        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
                        Button(action: {
                            selectedDate = calendar.startOfDay(for: date)
                            if hasOutfit {
                                onDateWithOutfitsTapped?(calendar.startOfDay(for: date))
                            }
                        }) {
                            Text("\(calendar.component(.day, from: date))")
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(isSelected ? Color.accentColor.opacity(0.2) : (hasOutfit ? Color.calendarHighlightGreen : Color.clear))
                                .clipShape(Circle())
                                .foregroundColor(isSelected ? .accentColor : .primary)
                        }
                    }
                }
            }
        }
        .onAppear {
            currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate)) ?? Calendar.current.startOfDay(for: Date())
        }
        .onChange(of: selectedDate) { newDate in
            let newMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: newDate)) ?? currentMonth
            if !calendar.isDate(newMonth, inSameDayAs: currentMonth) {
                currentMonth = newMonth
            }
        }
    }
}

struct YearMonthPicker: View {
    @Binding var selectedDate: Date
    @Binding var isPresented: Bool
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var selectedMonth: Int = Calendar.current.component(.month, from: Date())
    let years: [Int] = Array(1970...2100)
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Picker("Year", selection: $selectedYear) {
                    ForEach(years, id: \.self) { year in
                        Text("\(year)").tag(year)
                    }
                }
                .pickerStyle(WheelPickerStyle())
                Picker("Month", selection: $selectedMonth) {
                    ForEach(1...12, id: \.self) { month in
                        Text(DateFormatter().monthSymbols[month-1]).tag(month)
                    }
                }
                .pickerStyle(WheelPickerStyle())
                Spacer()
                Button("Select") {
                    let calendar = Calendar.current
                    if let newDate = calendar.date(from: DateComponents(year: selectedYear, month: selectedMonth, day: 1)) {
                        selectedDate = newDate
                    }
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") { isPresented = false }
                    .foregroundColor(.red)
            }
            .padding()
            .navigationTitle("Select Year & Month")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                let calendar = Calendar.current
                selectedYear = calendar.component(.year, from: selectedDate)
                selectedMonth = calendar.component(.month, from: selectedDate)
            }
        }
    }
}

struct OutfitItemGroup {
    let category: String
    let items: [OutfitItem]
}

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
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            OutfitCardActionsColumn(
                notes: outfit.notes,
                showEditSheet: $showEditSheet,
                showDeleteAlert: $showDeleteAlert,
                onEdit: { showEditSheet = true },
                onDelete: { showDeleteAlert = true }
            )
            // Right: Horizontal scroll of all items
            OutfitCardItemsScroll(
                allItems: allItems,
                previewImage: $previewImage
            )
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.accentColor.opacity(0.07))
        )
        .shadow(color: Color.black.opacity(0.09), radius: 6, x: 0, y: 2)
        .padding(.horizontal, 8)
        .frame(maxWidth: 420, minHeight: 120, alignment: .leading)
        .sheet(item: $previewImage) { wrapper in
            VStack {
                Spacer()
                ZoomableImage(image: wrapper.image)
                    .padding()
                Spacer()
                Button("Close") { previewImage = nil }
                    .font(.headline)
                    .padding()
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
                primaryButton: .destructive(Text("Delete")) {
                    viewModel.deleteOutfit(outfit)
                },
                secondaryButton: .cancel()
            )
        }
    }
}

private let dateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .medium
    return df
}()

// Helper extension for Core Data OutfitItem to get images
extension OutfitItem {
    var image: UIImage? {
        if let path = self.imagePath {
            return WardrobeImageFileHelper.loadImage(at: path)
        }
        return nil
    }
    var croppedImage: UIImage? {
        if let path = self.croppedImagePath {
            return WardrobeImageFileHelper.loadImage(at: path)
        }
        return nil
    }
}

extension Color {
    static var calendarHighlightGreen: Color {
        Color(UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                // Brighter green for dark mode
                return UIColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 0.32)
            } else {
                // Softer green for light mode
                return UIColor(red: 0.20, green: 0.70, blue: 0.30, alpha: 0.15)
            }
        })
    }
} 