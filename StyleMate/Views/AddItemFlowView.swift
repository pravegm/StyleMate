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
            ProgressView().tint(DS.Colors.accent)
            Text("Finding you in your photos…")
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    @ViewBuilder
    private var disambiguationView: some View {
        if let current = ambiguousQueue.first {
            let columns = [GridItem(.flexible(), spacing: DS.Spacing.sm),
                           GridItem(.flexible(), spacing: DS.Spacing.sm)]
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
                                Image(uiImage: person.crop)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(height: 200)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                            }
                            .buttonStyle(.plain)
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
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.bottom, DS.Spacing.xl)
            }
        }
    }
}
