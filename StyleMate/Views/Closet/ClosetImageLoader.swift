import SwiftUI
import UIKit

/// Loads wardrobe images for the closet off the main thread and keeps them
/// decoded. `WardrobeImageFileHelper.loadImage` caches `UIImage(data:)`, which
/// decodes lazily — on the main thread, at first draw. For a big scrolling grid
/// that is a stutter per tile, so this prepares each image for display on a
/// background task and caches the decoded result.
final class ClosetImageLoader {
    static let shared = ClosetImageLoader()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 500
        return c
    }()

    func cached(_ path: String?) -> UIImage? {
        guard let path, !path.isEmpty else { return nil }
        return cache.object(forKey: path as NSString)
    }

    func load(_ path: String?) async -> UIImage? {
        guard let path, !path.isEmpty else { return nil }
        if let hit = cached(path) { return hit }
        let cache = self.cache
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let image = WardrobeImageFileHelper.loadImage(at: path) else { return nil }
            let ready = image.preparingForDisplay() ?? image
            cache.setObject(ready, forKey: path as NSString)
            return ready
        }.value
    }

    func evict(_ paths: [String?]) {
        for p in paths.compactMap({ $0 }) { cache.removeObject(forKey: p as NSString) }
    }
}

extension WardrobeItem {
    /// Small image for grids: the thumbnail, else the cutout.
    var gridImagePath: String? { thumbnailPath ?? croppedImagePath ?? imagePath }
    /// Full-resolution cutout for the detail page.
    var fullImagePath: String { croppedImagePath ?? imagePath }
}

/// An item's cutout tile that loads its image asynchronously (never decoding on
/// the main thread) and shows a shimmer until it arrives.
struct AsyncItemTile: View {
    let path: String?
    var height: CGFloat? = nil
    var cornerRadius: CGFloat = DS.Radius.control
    var inset: CGFloat = 10
    /// Optional higher-resolution image to swap in once loaded (detail page).
    var upgradePath: String? = nil

    @State private var image: UIImage?
    @State private var loaded = false

    init(path: String?, height: CGFloat? = nil, cornerRadius: CGFloat = DS.Radius.control,
         inset: CGFloat = 10, upgradePath: String? = nil) {
        self.path = path
        self.height = height
        self.cornerRadius = cornerRadius
        self.inset = inset
        self.upgradePath = upgradePath
        let hit = ClosetImageLoader.shared.cached(upgradePath) ?? ClosetImageLoader.shared.cached(path)
        _image = State(initialValue: hit)
        _loaded = State(initialValue: hit != nil)
    }

    var body: some View {
        ItemCutoutTile(image: image, height: height, cornerRadius: cornerRadius, inset: inset,
                       isLoading: !loaded)
            .task(id: (path ?? "") + "|" + (upgradePath ?? "")) {
                // Cached images come back immediately, so re-running on a path
                // change (photo replaced) swaps the picture without a flash.
                let small = await ClosetImageLoader.shared.load(path)
                if ClosetImageLoader.shared.cached(upgradePath) == nil { image = small }
                loaded = true
                if let upgradePath, upgradePath != path,
                   let big = await ClosetImageLoader.shared.load(upgradePath) {
                    image = big
                }
            }
    }
}
