import PhotosUI
import SwiftUI

// MARK: - "On you | Pieces" toggle

enum TryOnMode: String { case onYou, pieces }

/// The segmented capsule over the outfit card.
struct TryOnModeToggle: View {
    @Binding var mode: TryOnMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            segment(.onYou, "On you", "person.fill")
            segment(.pieces, "Pieces", "square.grid.2x2")
        }
        .padding(3)
        .dsGlassCapsule()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tryon.toggle")
    }

    private func segment(_ m: TryOnMode, _ title: String, _ icon: String) -> some View {
        let on = mode == m
        return Button {
            Haptics.selection()
            withAnimation(DSMotionEnv.resolve(DS.Motion.snappy, reduceMotion: reduceMotion)) { mode = m }
        } label: {
            Label(title, systemImage: icon)
                .font(DS.Font.footnote.weight(.semibold))
                .foregroundStyle(on ? DS.Colors.onAccent : DS.Colors.textPrimary)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background { if on { Capsule().fill(DS.Colors.accent) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(m == .onYou ? "tryon.toggle.onYou" : "tryon.toggle.pieces")
    }
}

// MARK: - The on-body image of a look

/// A look on the user's body: the pieces board with a shimmer while it renders, then the try-on fades
/// in. Falls back to the pieces (with a short note) when the gate rejected it, and offers to set up a
/// body photo when there's none.
struct OutfitOnBodyView: View {
    let items: [WardrobeItem]
    /// Request priority for this look (the deck's current look = user; thumbnails = background).
    var priority: TryOnQueue.Priority = .user
    var showsChangePhoto = true
    var onOpen: (UIImage) -> Void = { _ in }

    @ObservedObject private var queue = TryOnQueue.shared
    @ObservedObject private var bodies = TryOnBodyLibrary.shared
    @EnvironmentObject private var authService: AuthService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var showBodySheet = false

    private var state: TryOnQueue.State { _ = queue.revision; return queue.state(for: items) }

    var body: some View {
        ZStack {
            switch state {
            case .ready:
                if let image {
                    Button { onOpen(image) } label: {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                            .padding(DS.Spacing.sm)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .accessibilityLabel("This outfit on you: " + items.map { ClosetText.displayName($0) }.joined(separator: ", "))
                    .accessibilityHint("Opens it full screen")
                    .accessibilityIdentifier("tryon.image")
                } else {
                    placeholder(caption: nil)
                }
            case .queued, .rendering:
                placeholder(caption: "Dressing you…")
            case .rejected:
                placeholder(caption: "This one shows best as pieces", shimmer: false)
            case .needsBody:
                setupCard
            case .unavailable:
                OutfitBoard(items: items, isThumbnail: true, padding: DS.Spacing.md)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsChangePhoto, state != .needsBody, state != .unavailable {
                Button { showBodySheet = true } label: {
                    Image(systemName: "person.crop.rectangle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Colors.accent)
                        .frame(width: 44, height: 44)
                        .dsGlassCapsule()
                }
                .buttonStyle(DSTapBounce())
                .padding(DS.Spacing.xs)
                .accessibilityLabel("Change the photo outfits are shown on")
                .accessibilityIdentifier("tryon.changePhoto")
            }
        }
        .animation(reduceMotion ? DS.Motion.reduced : .easeInOut(duration: 0.45), value: image != nil)
        .task(id: "\(queue.key(for: items) ?? "-")|\(state)") {
            if case .ready(let url) = state {
                image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path) }.value
            } else {
                image = nil
                if state == .queued { queue.request(items, priority: priority) }
                if state == .needsBody {
                    bodies.chooseAutomaticallyIfNeeded(userId: authService.user?.id ?? "", gender: authService.user?.gender)
                }
            }
        }
        .sheet(isPresented: $showBodySheet) { TryOnBodySheet() }
    }

    private func placeholder(caption: String?, shimmer: Bool = true) -> some View {
        ZStack(alignment: .bottom) {
            OutfitBoard(items: items, isThumbnail: true, padding: DS.Spacing.md)
                .opacity(shimmer ? 0.55 : 1)
                .overlay { if shimmer && !reduceMotion { ShimmerBand() } }
            if let caption {
                Label(caption, systemImage: shimmer ? "sparkles" : "square.grid.2x2")
                    .font(DS.Font.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .dsGlassCapsule()
                    .padding(.bottom, DS.Spacing.xl)
                    .accessibilityIdentifier(shimmer ? "tryon.rendering" : "tryon.rejected")
            }
        }
    }

    private var setupCard: some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "person.crop.rectangle.badge.plus")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(DS.Colors.accent)
                .accessibilityHidden(true)
            Text("See your outfits on you")
                .font(DS.Font.headline)
                .foregroundStyle(DS.Colors.textPrimary)
            Text("StyleMate picks a full-length photo of you from your library. It never leaves this iPhone.")
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await bodies.findBestPhoto(userId: authService.user?.id ?? "", gender: authService.user?.gender) }
            } label: {
                if bodies.status == .searching || bodies.status == .generating {
                    ProgressView()
                } else {
                    Text("Find a photo of me")
                }
            }
            .buttonStyle(DSPrimaryButton())
            .disabled(bodies.status == .searching || bodies.status == .generating)
            .accessibilityIdentifier("tryon.findPhoto")
            Button("More choices") { showBodySheet = true }
                .buttonStyle(DSTertiaryButton())
                .frame(minHeight: 44)
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A soft light band sweeping across (the "rendering" cue). Hidden with Reduce Motion.
struct ShimmerBand: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.45)
                .offset(x: phase * geo.size.width * 1.2)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Full screen, pinch to zoom

struct TryOnFullScreenView: View {
    let image: UIImage
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { v in scale = min(5, max(1, lastScale * v.magnification)) }
                            .onEnded { _ in lastScale = scale; if scale <= 1.01 { reset() } }
                            .simultaneously(with: DragGesture()
                                .onChanged { v in
                                    guard scale > 1 else { return }
                                    offset = CGSize(width: lastOffset.width + v.translation.width,
                                                    height: lastOffset.height + v.translation.height)
                                }
                                .onEnded { _ in lastOffset = offset })
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(DS.Motion.snappy) {
                            if scale > 1 { reset() } else { scale = 2.5; lastScale = 2.5 }
                        }
                    }
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier("tryon.fullscreen")
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func reset() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
    }
}

// MARK: - Choosing the body photo

/// "Choose a different photo", take one, use a model body, or turn "On you" off.
struct TryOnBodySheet: View {
    @ObservedObject private var bodies = TryOnBodyLibrary.shared
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var picked: PhotosPickerItem?
    @State private var cameraImage: UIImage?
    @State private var showCamera = false
    @State private var message: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: DS.Spacing.md) {
                        currentThumb
                        VStack(alignment: .leading, spacing: 4) {
                            Text(statusTitle).font(DS.Font.headline)
                            Text("Your photo stays on this iPhone. It's never uploaded or synced.")
                                .font(DS.Font.footnote)
                                .foregroundStyle(DS.Colors.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                    if let message {
                        Text(message).font(DS.Font.footnote).foregroundStyle(DS.Colors.warning)
                    }
                }
                Section("For the best result") {
                    Label("Full length, head to feet", systemImage: "figure.stand")
                    Label("Facing the camera, arms by your sides", systemImage: "person.fill")
                    Label("Fitted clothes, good light", systemImage: "sun.max")
                }
                .font(DS.Font.subheadline)
                Section {
                    Button {
                        run { await bodies.findBestPhoto(userId: authService.user?.id ?? "", gender: authService.user?.gender) }
                    } label: { Label("Find the best photo of me", systemImage: "sparkle.magnifyingglass") }
                    PhotosPicker(selection: $picked, matching: .images) {
                        Label("Choose a different photo", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("tryon.choosePhoto")
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: { Label("Take a photo", systemImage: "camera") }
                    }
                    Button {
                        run { await bodies.useModelBody(gender: authService.user?.gender) }
                    } label: { Label("Use a model instead", systemImage: "figure.stand.dress.line.vertical.figure") }
                }
                .disabled(working)
                Section {
                    if bodies.status == .off {
                        Button("Turn On you back on") { bodies.turnOn() }
                    } else {
                        Button("Don't show outfits on me", role: .destructive) { bodies.turnOff(); dismiss() }
                    }
                }
            }
            .navigationTitle("Your try-on photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .overlay { if working { ProgressView().controlSize(.large) } }
        }
        .onChange(of: picked) { item in
            guard let item else { return }
            run {
                guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
                let ok = await bodies.use(img, source: .picked)
                if !ok {
                    message = "That photo doesn't show one person head to feet, facing the camera. Try another."
                }
            }
        }
        .onChange(of: cameraImage) { img in
            guard let img else { return }
            run {
                let ok = await bodies.use(img, source: .camera)
                if !ok {
                    message = "Stand back so your whole body is in the frame, facing the camera."
                }
            }
        }
        .sheet(isPresented: $showCamera) { ImagePicker(image: $cameraImage).ignoresSafeArea() }
    }

    private var statusTitle: String {
        switch bodies.status {
        case .ready(let b): return b.source == .model ? "Using a model" : "Using your photo"
        case .searching: return "Looking through your photos…"
        case .generating: return "Making a model…"
        case .off: return "On you is off"
        case .missing: return "No photo yet"
        }
    }

    @ViewBuilder
    private var currentThumb: some View {
        if let b = bodies.current,
           let img = UIImage(contentsOfFile: LocalStore.directory("TryOn/Body").appendingPathComponent(b.file).path) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 56, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .fill(DS.Colors.fill)
                .frame(width: 56, height: 84)
                .overlay(Image(systemName: "person").foregroundStyle(DS.Colors.textTertiary))
                .accessibilityHidden(true)
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        message = nil
        working = true
        Task { await work(); working = false }
    }
}

// MARK: - Thumbnails (Home "Today's look", calendar)

/// The pieces board, with the look on the user beside it once that try-on is ready (rendered in the
/// background; nothing changes until it is).
struct TryOnLookThumbnail: View {
    let items: [WardrobeItem]
    var padding: CGFloat = DS.Spacing.sm
    /// Ask for the render (Home's look) or only show a cached one (calendar).
    var requests = true

    @ObservedObject private var queue = TryOnQueue.shared
    @State private var image: UIImage?

    private var state: TryOnQueue.State { _ = queue.revision; return queue.state(for: items) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        .padding(padding)
                        .frame(width: geo.size.width * 0.42, height: geo.size.height)
                        .transition(.opacity)
                        .accessibilityIdentifier("tryon.thumbnail")
                }
                OutfitBoard(items: items, isThumbnail: true, padding: padding)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: image != nil)
        .task(id: "\(queue.key(for: items) ?? "-")|\(state)") {
            if case .ready(let url) = state {
                image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path) }.value
            } else {
                image = nil
                if requests, state == .queued { queue.request(items, priority: .background) }
            }
        }
    }
}

/// A cached try-on of `items` if there is one (never renders), else `fallback`. For the calendar.
struct TryOnCachedImage<Fallback: View>: View {
    let items: [WardrobeItem]
    var cornerRadius: CGFloat = DS.Radius.control
    @ViewBuilder let fallback: () -> Fallback

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .accessibilityIdentifier("tryon.calendar")
            } else {
                fallback()
            }
        }
        .task(id: items.map(\.id)) {
            guard TryOnAvailability.isAvailable, let key = TryOnQueue.shared.key(for: items),
                  let url = TryOnStore.shared.imageURL(key) else { image = nil; return }
            image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path) }.value
        }
    }
}

// MARK: - Status chip (On you selected, image not ready yet)

/// Under the interactive pieces board while a look's try-on isn't ready: "Dressing you…", "Shows best as
/// pieces", or "See it on you" (no body photo yet). Asks for the render (and, the first time, picks the
/// body photo) so the board can switch to the image as soon as it lands.
struct TryOnStatusChip: View {
    let items: [WardrobeItem]

    @ObservedObject private var queue = TryOnQueue.shared
    @ObservedObject private var bodies = TryOnBodyLibrary.shared
    @EnvironmentObject private var authService: AuthService
    @State private var showBodySheet = false

    private var state: TryOnQueue.State { _ = queue.revision; return queue.state(for: items) }

    var body: some View {
        Group {
            switch state {
            case .queued, .rendering:
                Label { Text("Dressing you…") } icon: { ProgressView().controlSize(.small) }
                    .chipStyle()
                    .accessibilityIdentifier("tryon.rendering")
            case .rejected:
                Label("This one shows best as pieces", systemImage: "square.grid.2x2")
                    .chipStyle()
                    .accessibilityIdentifier("tryon.rejected")
            case .needsBody:
                Button { showBodySheet = true } label: {
                    Label(bodies.status == .searching || bodies.status == .generating ? "Finding a photo of you…" : "See it on you",
                          systemImage: "person.crop.rectangle")
                        .chipStyle()
                }
                .buttonStyle(DSTapBounce())
                .accessibilityIdentifier("tryon.findPhoto")
            case .ready, .unavailable:
                EmptyView()
            }
        }
        .task(id: "\(queue.key(for: items) ?? "-")|\(state)") {
            if state == .queued { queue.request(items, priority: .user) }
            if state == .needsBody {
                bodies.chooseAutomaticallyIfNeeded(userId: authService.user?.id ?? "", gender: authService.user?.gender)
            }
        }
        .sheet(isPresented: $showBodySheet) { TryOnBodySheet() }
    }
}

private extension View {
    func chipStyle() -> some View {
        self.font(DS.Font.footnote.weight(.semibold))
            .foregroundStyle(DS.Colors.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .dsGlassCapsule()
    }
}
