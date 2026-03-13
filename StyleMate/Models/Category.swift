import SwiftUI

// Exhaustive enum for all categories
enum Category: String, CaseIterable, Identifiable, Hashable {
    case tops = "Tops"
    case bottoms = "Bottoms"
    case midLayers = "Mid-Layers"
    case outerwear = "Outerwear"
    case onePieces = "One-Pieces"
    case footwear = "Footwear"
    case accessories = "Accessories"
    case innerwear = "Innerwear"
    case activewear = "Activewear"
    case ethnicWear = "Ethnic Wear"
    
    var id: String { self.rawValue }

    var wearingOrder: Int {
        switch self {
        case .accessories:  return 0
        case .outerwear:    return 1
        case .midLayers:    return 2
        case .tops:         return 3
        case .onePieces:    return 3
        case .activewear:   return 3
        case .ethnicWear:   return 3
        case .innerwear:    return 4
        case .bottoms:      return 5
        case .footwear:     return 6
        }
    }
}

// Shared wardrobe view model
class WardrobeViewModel: ObservableObject {
    @Published var items: [WardrobeItem] = [] {
        didSet {
            if !suspendSaving {
                save(forUser: currentUserEmail)
            }
        }
    }
    private(set) var currentUserEmail: String = ""
    private var suspendSaving = false
    
    private func storageKey(for email: String) -> String {
        "wardrobe_\(email.replacingOccurrences(of: "@", with: "_").replacingOccurrences(of: ".", with: "_"))"
    }
    
    func load(forUser email: String) {
        currentUserEmail = email
        let key = storageKey(for: email)
        guard let data = UserDefaults.standard.data(forKey: key) else {
            items = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([WardrobeItemCodable].self, from: data)
            items = decoded.compactMap { $0.toWardrobeItem() }
        } catch {
            items = []
        }
    }
    
    func save(forUser email: String) {
        guard !email.isEmpty else { return }
        let key = storageKey(for: email)
        let codableItems = items.map { WardrobeItemCodable(from: $0) }
        if let data = try? JSONEncoder().encode(codableItems) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    func clear() {
        suspendSaving = true
        items = []
        suspendSaving = false
        currentUserEmail = ""
    }

    // MARK: - iCloud Sync

    func syncItemToCloud(_ item: WardrobeItem) {
        guard !currentUserEmail.isEmpty else { return }
        Task {
            _ = await CloudKitService.shared.uploadItem(item, userID: currentUserEmail)
        }
    }

    func deleteItemFromCloud(_ item: WardrobeItem) {
        Task {
            await CloudKitService.shared.deleteItem(id: item.id)
        }
    }

    func backupToCloud() {
        guard !currentUserEmail.isEmpty else { return }
        Task {
            await CloudKitService.shared.uploadAll(items: items, userID: currentUserEmail)
        }
    }

    func restoreFromCloud() async {
        guard !currentUserEmail.isEmpty else { return }
        let cloudItems = await CloudKitService.shared.fetchAll(userID: currentUserEmail)
        guard !cloudItems.isEmpty else { return }

        await MainActor.run {
            let localByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            var changed = false
            suspendSaving = true

            for cloudItem in cloudItems {
                if let localItem = localByID[cloudItem.id] {
                    let metadataChanged = localItem.category != cloudItem.category
                        || localItem.product != cloudItem.product
                        || localItem.colors != cloudItem.colors
                        || localItem.brand != cloudItem.brand
                        || localItem.pattern != cloudItem.pattern
                        || localItem.material != cloudItem.material
                        || localItem.fit != cloudItem.fit
                        || localItem.neckline != cloudItem.neckline
                        || localItem.sleeveLength != cloudItem.sleeveLength
                        || localItem.garmentLength != cloudItem.garmentLength
                        || localItem.details != cloudItem.details

                    if metadataChanged, let idx = items.firstIndex(where: { $0.id == cloudItem.id }) {
                        let finalImagePath = WardrobeImageFileHelper.loadImage(at: localItem.imagePath) != nil
                            ? localItem.imagePath : cloudItem.imagePath
                        let finalCroppedPath: String? = {
                            if let localCropped = localItem.croppedImagePath,
                               WardrobeImageFileHelper.loadImage(at: localCropped) != nil {
                                return localCropped
                            }
                            return cloudItem.croppedImagePath
                        }()

                        items[idx] = WardrobeItem(
                            id: cloudItem.id,
                            category: cloudItem.category,
                            product: cloudItem.product,
                            colors: cloudItem.colors,
                            brand: cloudItem.brand,
                            pattern: cloudItem.pattern,
                            imagePath: finalImagePath,
                            croppedImagePath: finalCroppedPath,
                            thumbnailPath: localItem.thumbnailPath ?? cloudItem.thumbnailPath,
                            material: cloudItem.material,
                            fit: cloudItem.fit,
                            neckline: cloudItem.neckline,
                            sleeveLength: cloudItem.sleeveLength,
                            garmentLength: cloudItem.garmentLength,
                            details: cloudItem.details
                        )
                        changed = true
                    }
                } else {
                    items.append(cloudItem)
                    changed = true
                }
            }

            // Remove local items that no longer exist in cloud
            let cloudIDs = Set(cloudItems.map { $0.id })
            let toRemove = items.filter { !cloudIDs.contains($0.id) }
            for item in toRemove {
                WardrobeImageFileHelper.deleteImage(at: item.imagePath)
                WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath)
                WardrobeImageFileHelper.deleteImage(at: item.thumbnailPath)
                changed = true
            }
            items.removeAll { !cloudIDs.contains($0.id) }

            suspendSaving = false
            if changed {
                save(forUser: currentUserEmail)
            }
        }
    }

    func migrateThumbnails() {
        let thumbnailKey = "thumbnailMigrationComplete_\(currentUserEmail)"
        guard !UserDefaults.standard.bool(forKey: thumbnailKey) else { return }
        guard !items.isEmpty else {
            UserDefaults.standard.set(true, forKey: thumbnailKey)
            return
        }

        Task {
            var updated = false
            for (index, item) in items.enumerated() {
                guard item.thumbnailPath == nil else { continue }

                guard let sourceImage = WardrobeImageFileHelper.loadImage(at: item.croppedImagePath ?? item.imagePath) else { continue }

                let thumbPath = WardrobeImageFileHelper.saveThumbnail(sourceImage)

                let updatedItem = WardrobeItem(
                    id: item.id,
                    category: item.category,
                    product: item.product,
                    colors: item.colors,
                    brand: item.brand,
                    pattern: item.pattern,
                    imagePath: item.imagePath,
                    croppedImagePath: item.croppedImagePath,
                    thumbnailPath: thumbPath,
                    material: item.material,
                    fit: item.fit,
                    neckline: item.neckline,
                    sleeveLength: item.sleeveLength,
                    garmentLength: item.garmentLength,
                    details: item.details
                )

                await MainActor.run {
                    self.items[index] = updatedItem
                }
                updated = true
            }

            await MainActor.run {
                if updated {
                    self.save(forUser: self.currentUserEmail)
                }
                UserDefaults.standard.set(true, forKey: thumbnailKey)
            }
        }
    }

    func migrateBackgroundRemoval() {
        let migrationKey = "bgRemovalMigrationComplete_\(currentUserEmail)"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            migrateZoneCrop()
            return
        }
        guard !items.isEmpty else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            migrateZoneCrop()
            return
        }

        Task {
            var updated = false
            for (index, item) in items.enumerated() {
                if let result = await BackgroundRemovalService.shared.processExistingItem(
                    imagePath: item.imagePath,
                    croppedImagePath: item.croppedImagePath
                ) {
                    WardrobeImageFileHelper.deleteImage(at: item.imagePath)
                    if let oldCropped = item.croppedImagePath {
                        WardrobeImageFileHelper.deleteImage(at: oldCropped)
                    }

                    let updatedItem = WardrobeItem(
                        id: item.id,
                        category: item.category,
                        product: item.product,
                        colors: item.colors,
                        brand: item.brand,
                        pattern: item.pattern,
                        imagePath: result.newImagePath,
                        croppedImagePath: result.newCroppedPath ?? item.croppedImagePath,
                        thumbnailPath: item.thumbnailPath,
                        material: item.material,
                        fit: item.fit,
                        neckline: item.neckline,
                        sleeveLength: item.sleeveLength,
                        garmentLength: item.garmentLength,
                        details: item.details
                    )

                    await MainActor.run {
                        self.items[index] = updatedItem
                    }
                    updated = true
                }
            }

            await MainActor.run {
                if updated {
                    self.save(forUser: self.currentUserEmail)
                    self.backupToCloud()
                }
                UserDefaults.standard.set(true, forKey: migrationKey)
                self.migrateZoneCrop()
            }
        }
    }

    func migrateZoneCrop() {
        let zoneCropKey = "zoneCropMigrationComplete_\(currentUserEmail)"
        guard !UserDefaults.standard.bool(forKey: zoneCropKey) else { return }
        guard !items.isEmpty else {
            UserDefaults.standard.set(true, forKey: zoneCropKey)
            return
        }

        Task {
            var updated = false
            for (index, item) in items.enumerated() {
                guard let fullImage = WardrobeImageFileHelper.loadImage(at: item.imagePath) else { continue }

                let zoneCrop = BodyZone.cropToZone(image: fullImage, category: item.category)
                let newCroppedPath = zoneCrop != nil ? WardrobeImageFileHelper.saveImage(zoneCrop!) : nil

                if let oldCropped = item.croppedImagePath {
                    WardrobeImageFileHelper.deleteImage(at: oldCropped)
                }

                let updatedItem = WardrobeItem(
                    id: item.id,
                    category: item.category,
                    product: item.product,
                    colors: item.colors,
                    brand: item.brand,
                    pattern: item.pattern,
                    imagePath: item.imagePath,
                    croppedImagePath: newCroppedPath,
                    thumbnailPath: item.thumbnailPath,
                    material: item.material,
                    fit: item.fit,
                    neckline: item.neckline,
                    sleeveLength: item.sleeveLength,
                    garmentLength: item.garmentLength,
                    details: item.details
                )

                await MainActor.run {
                    self.items[index] = updatedItem
                }
                updated = true
            }

            await MainActor.run {
                if updated {
                    self.save(forUser: self.currentUserEmail)
                    self.backupToCloud()
                }
                UserDefaults.standard.set(true, forKey: zoneCropKey)
            }
        }
    }
}

struct WardrobeItemCodable: Codable {
    let id: String
    let category: String
    let product: String
    let colors: [String]
    let brand: String
    let pattern: String
    let imagePath: String
    let croppedImagePath: String?
    let thumbnailPath: String?

    let material: String?
    let fit: String?
    let neckline: String?
    let sleeveLength: String?
    let garmentLength: String?
    let details: String?

    enum CodingKeys: String, CodingKey {
        case id, category, product, colors, brand, pattern, imagePath, croppedImagePath, thumbnailPath
        case material, fit, neckline, sleeveLength, garmentLength, details
    }

    init(from item: WardrobeItem) {
        self.id = item.id.uuidString
        self.category = item.category.rawValue
        self.product = item.product
        self.colors = item.colors
        self.brand = item.brand
        self.pattern = item.pattern.rawValue
        self.imagePath = item.imagePath
        self.croppedImagePath = item.croppedImagePath
        self.thumbnailPath = item.thumbnailPath
        self.material = item.material
        self.fit = item.fit?.rawValue
        self.neckline = item.neckline?.rawValue
        self.sleeveLength = item.sleeveLength?.rawValue
        self.garmentLength = item.garmentLength?.rawValue
        self.details = item.details
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        category = try container.decode(String.self, forKey: .category)
        product = try container.decode(String.self, forKey: .product)
        colors = try container.decode([String].self, forKey: .colors)
        brand = try container.decode(String.self, forKey: .brand)
        pattern = try container.decode(String.self, forKey: .pattern)
        imagePath = try container.decode(String.self, forKey: .imagePath)
        croppedImagePath = try container.decodeIfPresent(String.self, forKey: .croppedImagePath)
        thumbnailPath = try container.decodeIfPresent(String.self, forKey: .thumbnailPath)
        material = try container.decodeIfPresent(String.self, forKey: .material)
        fit = try container.decodeIfPresent(String.self, forKey: .fit)
        neckline = try container.decodeIfPresent(String.self, forKey: .neckline)
        sleeveLength = try container.decodeIfPresent(String.self, forKey: .sleeveLength)
        garmentLength = try container.decodeIfPresent(String.self, forKey: .garmentLength)
        details = try container.decodeIfPresent(String.self, forKey: .details)
    }
    
    func toWardrobeItem() -> WardrobeItem? {
        guard let cat = Category(rawValue: category),
              let pat = Pattern(rawValue: pattern) else { return nil }
        return WardrobeItem(
            id: UUID(uuidString: id) ?? UUID(),
            category: cat,
            product: product,
            colors: colors,
            brand: brand,
            pattern: pat,
            imagePath: imagePath,
            croppedImagePath: croppedImagePath,
            thumbnailPath: thumbnailPath,
            material: material,
            fit: fit != nil ? Fit(rawValue: fit!) : nil,
            neckline: neckline != nil ? Neckline(rawValue: neckline!) : nil,
            sleeveLength: sleeveLength != nil ? SleeveLength(rawValue: sleeveLength!) : nil,
            garmentLength: garmentLength != nil ? GarmentLength(rawValue: garmentLength!) : nil,
            details: details
        )
    }
} 