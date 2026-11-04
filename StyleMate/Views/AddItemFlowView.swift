import SwiftUI

/// Wraps the manual add flow with identity resolution: before garments are
/// analyzed, each uploaded photo is resolved to the image we should actually
/// analyze — the whole image (solo/product), just the user (multi-person,
/// confident match), or, when unsure, after asking "which one is you?". Then it
/// hands the resolved images to AddItemReviewView. All identity work is on-device.
struct AddItemFlowView: View {
    let images: [UIImage]
    @Binding var isPresented: Bool
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var authService: AuthService

    private struct Ambiguous: Identifiable {
        let id = UUID()
        let image: UIImage
        let people: [DetectedPerson]
    }

    private enum Phase { case resolving, disambiguating, review }

    @State private var phase: Phase = .resolving
    @State private var resolvedImages: [UIImage] = []
    @State private var ambiguousQueue: [Ambiguous] = []
    @State private var didStartResolving = false

    var body: some View {
        Group {
            switch phase {
            case .resolving:
                chrome(title: "Preparing") { resolvingView }
            case .disambiguating:
                chrome(title: "Which one is you?") { disambiguationView }
            case .review:
                AddItemReviewView(images: resolvedImages, isPresented: $isPresented)
                    .environmentObject(wardrobeViewModel)
                    .environmentObject(authService)
            }
        }
        .task {
            guard !didStartResolving else { return }
            didStartResolving = true
            await resolveAll()
        }
    }

    // MARK: - Resolution

    private func resolveAll() async {
        guard let userId = authService.user?.id else {
            print("[Identity] No signed-in user — skipping identity gating, analyzing whole photos")
            resolvedImages = images
            phase = .review
            return
        }

        print("[Identity] Resolving \(images.count) uploaded photo(s)…")
        var resolved: [UIImage] = []
        var ambiguous: [Ambiguous] = []
        var isolatedCount = 0

        for image in images {
            let resolution = await Task.detached(priority: .userInitiated) {
                FaceMatchingService.shared.resolveIdentity(in: image, userId: userId)
            }.value

            switch resolution {
            case .useWhole:
                resolved.append(image)
            case .isolated(let isolated):
                resolved.append(isolated)
                isolatedCount += 1
            case .ambiguous(let people):
                ambiguous.append(Ambiguous(image: image, people: people))
            }
        }

        resolvedImages = resolved
        ambiguousQueue = ambiguous
        print("[Identity] Resolved \(images.count): \(resolved.count - isolatedCount) whole, \(isolatedCount) auto-isolated, \(ambiguous.count) need 'which is you?'")
        advance()
    }

    private func advance() {
        if ambiguousQueue.isEmpty {
            if resolvedImages.isEmpty { resolvedImages = images }   // safety net
            phase = .review
        } else {
            phase = .disambiguating
        }
    }

    private func pick(_ person: DetectedPerson?, in ambiguous: Ambiguous) {
        let userId = authService.user?.id ?? ""
        if let person {
            let isolated = FaceMatchingService.shared.isolateChosenPerson(
                person, in: ambiguous.image, totalFaces: ambiguous.people.count, userId: userId)
            resolvedImages.append(isolated ?? ambiguous.image)
        } else {
            resolvedImages.append(ambiguous.image)   // "use whole photo"
        }
        ambiguousQueue.removeFirst()
        advance()
    }

    // MARK: - Views

    private func chrome<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            ZStack { DS.Colors.backgroundPrimary.ignoresSafeArea(); content() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { isPresented = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                    }
                }
        }
    }

    private var resolvingView: some View {
        VStack(spacing: DS.Spacing.md) {
            ZStack {
                Circle().fill(DS.Colors.accentSoft).frame(width: 88, height: 88)
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DS.Colors.accent)
                    .symbolEffect(.pulse, options: .repeating)
            }
            Text("Finding you in your photos…")
                .font(DS.Font.headline)
                .foregroundColor(DS.Colors.textPrimary)
            Text("\(images.count) photo\(images.count == 1 ? "" : "s") · on your phone")
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var disambiguationView: some View {
        if let current = ambiguousQueue.first {
            // Adaptive: two people on a phone, more across a wide display.
            let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: DS.Spacing.sm)]
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    Text("This photo has more than one person. Tap the one that's you so we only catalog your outfit.")
                        .font(DS.Font.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.top, DS.Spacing.sm)

                    LazyVGrid(columns: columns, spacing: DS.Spacing.sm) {
                        ForEach(current.people) { person in
                            Button {
                                Haptics.medium()
                                pick(person, in: current)
                            } label: {
                                Color.clear
                                    .aspectRatio(0.75, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .overlay {
                                        Image(uiImage: person.crop)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    }
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                                    .dsCardShadow()
                            }
                            .buttonStyle(DSTapBounce())
                            .accessibilityLabel("Person \((current.people.firstIndex(where: { $0.id == person.id }) ?? 0) + 1)")
                            .accessibilityHint("Double-tap if this is you")
                        }
                    }

                    Button {
                        Haptics.light()
                        pick(nil, in: current)
                    } label: {
                        Text("None of these / use the whole photo")
                            .font(DS.Font.callout)
                            .foregroundColor(DS.Colors.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DS.Spacing.sm)
                    }

                    if ambiguousQueue.count > 1 {
                        Text("\(ambiguousQueue.count) photos need your input")
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.bottom, DS.Spacing.xl)
            }
        }
    }
}
