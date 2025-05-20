import SwiftUI

struct IdentifiableDate: Identifiable, Equatable {
    let id: Date
}

struct MyOutfitsView: View {
    @StateObject private var viewModel = MyOutfitsViewModel()
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showAddSheet = false
    @State private var showOutfitsForDate: IdentifiableDate? = nil
    @EnvironmentObject var wardrobeVM: WardrobeViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // Top section: Today's Outfits
            Group {
                Text("Today's Outfits")
                    .font(.title2.bold())
                    .padding(.top, 16)
                if let todaysOutfits = viewModel.outfitsByDate[Calendar.current.startOfDay(for: Date())], !todaysOutfits.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(todaysOutfits, id: \ .objectID) { outfit in
                                OutfitCardView(outfit: outfit)
                            }
                        }
                        .padding(.horizontal)
                    }
                } else {
                    Text("No outfit mapped for today. Add one!")
                        .foregroundColor(.secondary)
                        .padding(.bottom, 8)
                }
            }
            Divider().padding(.vertical, 8)
            
            // Calendar section
            CalendarGridView(
                selectedDate: $selectedDate,
                datesWithOutfits: Set(viewModel.outfitsByDate.keys),
                onDateWithOutfitsTapped: { date in
                    showOutfitsForDate = IdentifiableDate(id: date)
                }
            )
            .padding(.horizontal)
            .padding(.bottom, 8)
            
            // Add Outfit Button - Always visible
            Button(action: {
                showAddSheet = true
            }) {
                Label("Add Outfit to Selected Date", systemImage: "plus")
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Spacer()
        }
        .sheet(isPresented: $showAddSheet) {
            AddOutfitSheet(selectedDate: selectedDate) { items, notes in
                viewModel.addOutfit(date: selectedDate, items: items, source: "manual", notes: notes)
                showAddSheet = false
            }
            .environmentObject(wardrobeVM)
        }
        .sheet(item: $showOutfitsForDate) { identifiableDate in
            OutfitsForDateSheet(date: identifiableDate.id, viewModel: viewModel)
        }
    }
}

struct AddOutfitSheet: View {
    let selectedDate: Date
    var onSave: ([WardrobeItem], String?) -> Void
    @EnvironmentObject var wardrobeVM: WardrobeViewModel
    @Environment(\.dismiss) private var dismiss
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
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Select up to 10 items for your outfit on \(selectedDate, formatter: dateFormatter)")
                    .font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groupedItems, id: \ .category) { group in
                            Section(header:
                                HStack {
                                    Text(group.category.rawValue)
                                        .font(.title3.bold())
                                    Spacer()
                                    Button(action: {
                                        if expandedCategories.contains(group.category) {
                                            expandedCategories.remove(group.category)
                                        } else {
                                            expandedCategories.insert(group.category)
                                        }
                                    }) {
                                        Image(systemName: expandedCategories.contains(group.category) ? "chevron.down" : "chevron.right")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if expandedCategories.contains(group.category) {
                                        expandedCategories.remove(group.category)
                                    } else {
                                        expandedCategories.insert(group.category)
                                    }
                                }
                            ) {
                                if expandedCategories.contains(group.category) {
                                    ForEach(group.products, id: \ .product) { productGroup in
                                        Section(header:
                                            HStack {
                                                Text(productGroup.product)
                                                    .font(.headline)
                                                Spacer()
                                                Button(action: {
                                                    let key = "\(group.category.rawValue)-\(productGroup.product)"
                                                    if expandedProducts.contains(key) {
                                                        expandedProducts.remove(key)
                                                    } else {
                                                        expandedProducts.insert(key)
                                                    }
                                                }) {
                                                    let key = "\(group.category.rawValue)-\(productGroup.product)"
                                                    Image(systemName: expandedProducts.contains(key) ? "chevron.down" : "chevron.right")
                                                        .foregroundColor(.accentColor)
                                                }
                                            }
                                            .padding(.vertical, 4)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                let key = "\(group.category.rawValue)-\(productGroup.product)"
                                                if expandedProducts.contains(key) {
                                                    expandedProducts.remove(key)
                                                } else {
                                                    expandedProducts.insert(key)
                                                }
                                            }
                                        ) {
                                            let key = "\(group.category.rawValue)-\(productGroup.product)"
                                            if expandedProducts.contains(key) {
                                                ForEach(productGroup.items, id: \ .id) { item in
                                                    HStack {
                                                        Button(action: {
                                                            if selectedItems.contains(item) {
                                                                selectedItems.remove(item)
                                                            } else if selectedItems.count < 10 {
                                                                selectedItems.insert(item)
                                                            }
                                                        }) {
                                                            Image(systemName: selectedItems.contains(item) ? "checkmark.square.fill" : "square")
                                                                .foregroundColor(selectedItems.contains(item) ? .accentColor : .secondary)
                                                        }
                                                        Button(action: {
                                                            if let img = item.croppedImage ?? item.image {
                                                                previewImage = PreviewImage(image: img)
                                                            }
                                                        }) {
                                                            if let img = item.croppedImage ?? item.image {
                                                                Image(uiImage: img)
                                                                    .resizable()
                                                                    .frame(width: 40, height: 40)
                                                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                                            } else {
                                                                Rectangle()
                                                                    .fill(Color.gray)
                                                                    .frame(width: 40, height: 40)
                                                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                                            }
                                                        }
                                                        .buttonStyle(PlainButtonStyle())
                                                        Button(action: {
                                                            if selectedItems.contains(item) {
                                                                selectedItems.remove(item)
                                                            } else if selectedItems.count < 10 {
                                                                selectedItems.insert(item)
                                                            }
                                                        }) {
                                                            Text(item.name)
                                                                .font(.body)
                                                                .foregroundColor(.primary)
                                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                        }
                                                        .buttonStyle(PlainButtonStyle())
                                                        Spacer()
                                                    }
                                                    .padding(.vertical, 4)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                TextField("Notes (optional)", text: $notes)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Spacer()
                HStack {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.red)
                    Spacer()
                    Button("Save Outfit") {
                        onSave(Array(selectedItems), notes.isEmpty ? nil : notes)
                    }
                    .disabled(selectedItems.isEmpty)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
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
        }
    }
}

// New sheet view for showing all outfits for a date
struct OutfitsForDateSheet: View {
    let date: Date
    @ObservedObject var viewModel: MyOutfitsViewModel
    @State private var showAddSheet = false
    @EnvironmentObject var wardrobeVM: WardrobeViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(viewModel.outfitsByDate[date] ?? [], id: \.objectID) { outfit in
                            OutfitCardView(outfit: outfit)
                        }
                    }
                    .padding()
                }
                Spacer(minLength: 0)
                Button(action: {
                    showAddSheet = true
                }) {
                    Label("Add another outfit to this date", systemImage: "plus")
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .padding([.horizontal, .bottom])
                }
            }
            .navigationTitle(dateFormatter.string(from: date))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAddSheet) {
                AddOutfitSheet(selectedDate: date) { items, notes in
                    viewModel.addOutfit(date: date, items: items, source: "manual", notes: notes)
                    showAddSheet = false
                }
                .environmentObject(wardrobeVM)
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
                                .background(isSelected ? Color.accentColor.opacity(0.2) : (hasOutfit ? Color.green.opacity(0.15) : Color.clear))
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
    @State private var previewImage: PreviewImage? = nil
    
    private var allItems: [OutfitItem] {
        (outfit.items as? Set<OutfitItem>)?.sorted { ($0.product ?? "") < ($1.product ?? "") } ?? []
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            // Left: Only notes if present
            if let notes = outfit.notes, !notes.isEmpty {
                Text(notes)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
                    .padding(.leading, 4)
                    .frame(width: 110, alignment: .topLeading)
            }
            // Right: Horizontal scroll of all items
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(allItems, id: \ .objectID) { item in
                        Button(action: {
                            if let img = item.croppedImage ?? item.image {
                                previewImage = PreviewImage(image: img)
                            }
                        }) {
                            VStack(spacing: 6) {
                                if let img = item.croppedImage ?? item.image {
                                    Image(uiImage: img)
                                        .resizable()
                                        .aspectRatio(1, contentMode: .fill)
                                        .frame(width: 68, height: 68)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                } else {
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.18))
                                        .frame(width: 68, height: 68)
                                        .overlay(Text("No Image").font(.caption2))
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                }
                                Text(item.product ?? "")
                                    .font(.caption.bold())
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: 68)
                                if let colors = item.colors as? [String], !colors.isEmpty {
                                    Text(colors.joined(separator: ", "))
                                        .font(.caption2)
                                        .foregroundColor(.accentColor)
                                        .lineLimit(1)
                                        .frame(maxWidth: 68)
                                }
                                if let pattern = item.pattern, !pattern.isEmpty {
                                    Text(pattern)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 68)
                                }
                                if let brand = item.brand, !brand.isEmpty {
                                    Text(brand)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 68)
                                }
                            }
                            .padding(8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.systemBackground)))
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