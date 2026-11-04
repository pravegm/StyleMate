import SwiftUI

/// "Is this you?" — photos the scan thought were probably the user but wasn't
/// sure enough to add silently. Confirmed faces teach the face gallery (so the
/// next scan finds more of you on its own) and their outfits are extracted;
/// the rest are dropped.
struct FaceReviewView: View {
    @ObservedObject var scanService: PhotoScanService
    @Binding var isPresented: Bool
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel

    @State private var reviews: [PendingFaceReview] = []
    @State private var thumbs: [String: UIImage] = [:]
    @State private var selected: Set<String> = []
    @State private var isApplying = false
    @State private var addedCount: Int?

    private var userId: String { wardrobeViewModel.currentUserEmail }
    private let pageSize = 48
    private let columns = [GridItem(.flexible(), spacing: DS.Spacing.sm),
                           GridItem(.flexible(), spacing: DS.Spacing.sm),
                           GridItem(.flexible(), spacing: DS.Spacing.sm)]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                DS.Colors.backgroundPrimary.ignoresSafeArea()
                if let added = addedCount {
                    doneState(added)
                } else if reviews.isEmpty {
                    ProgressView().tint(DS.Colors.accent)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Spacing.md) {
                            header
                            LazyVGrid(columns: columns, spacing: DS.Spacing.sm) {
                                ForEach(reviews) { r in faceCell(r) }
                            }
                        }
                        .padding(.horizontal, DS.Spacing.screenH)
                        .padding(.bottom, DS.Spacing.xxxl + DS.ButtonSize.height)
                    }
                    bottomBar
                }
                if isApplying {
                    OutfitLoadingOverlay(progress: 0.5, message: "Adding your outfits…")
                }
            }
            .navigationTitle("Is this you?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .task { await load() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Tap every photo of you")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
            Text("We weren't sure about these. Your picks teach StyleMate your face — and their outfits go straight into your wardrobe. Everything stays on your phone.")
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
            Button(selected.count == reviews.count ? "Deselect all" : "Select all") {
                Haptics.light()
                selected = selected.count == reviews.count ? [] : Set(reviews.map(\.id))
            }
            .font(DS.Font.callout)
            .foregroundColor(DS.Colors.accent)
            .padding(.top, DS.Spacing.xs)
        }
        .padding(.top, DS.Spacing.md)
    }

    private func faceCell(_ r: PendingFaceReview) -> some View {
        let isOn = selected.contains(r.id)
        return Button {
            Haptics.light()
            if isOn { selected.remove(r.id) } else { selected.insert(r.id) }
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = thumbs[r.id] {
                        Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(DS.Colors.backgroundSecondary)
                    }
                }
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
                        .strokeBorder(isOn ? DS.Colors.accent : .clear, lineWidth: 3)
                )
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? DS.Colors.accent : .white)
                    .shadow(radius: 2)
                    .padding(6)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Selected, this is me" : "Not selected")
        .task { await loadThumb(r) }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                Haptics.success()
                Task { await apply() }
            } label: {
                HStack {
                    Spacer()
                    Text(selected.isEmpty ? "None of these are me" : "That's me — add \(selected.count) photo\(selected.count == 1 ? "" : "s")")
                    Spacer()
                }
            }
            .buttonStyle(DSPrimaryButton())
            .disabled(isApplying)
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.vertical, DS.Spacing.md)
        }
        .background(DS.Colors.backgroundPrimary)
    }

    private func doneState(_ added: Int) -> some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: added > 0 ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 44))
                .foregroundColor(added > 0 ? DS.Colors.success : DS.Colors.textTertiary)
            Text(added > 0 ? "Added \(added) item\(added == 1 ? "" : "s") to your wardrobe" : "All set")
                .font(DS.Font.headline)
                .foregroundColor(DS.Colors.textPrimary)
            Text("StyleMate now knows your face better for the next scan.")
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DS.Spacing.xl)
        .task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            isPresented = false
        }
    }

    // MARK: - Data

    private func load() async {
        let all = scanService.pendingReviews(forUser: userId)
        reviews = Array(all.prefix(pageSize))
        if reviews.isEmpty { addedCount = 0 }
    }

    private func loadThumb(_ r: PendingFaceReview) async {
        guard thumbs[r.id] == nil else { return }
        if let img = await scanService.reviewThumbnail(for: r) { thumbs[r.id] = img }
    }

    private func apply() async {
        isApplying = true
        let confirmed = reviews.filter { selected.contains($0.id) }
        let rejected = reviews.filter { !selected.contains($0.id) }
        let added = await scanService.resolveReviews(confirmed: confirmed, rejected: rejected,
                                                     forUser: userId, userGender: nil,
                                                     wardrobeViewModel: wardrobeViewModel)
        isApplying = false
        // More waiting? Show the next page instead of closing.
        let remaining = scanService.pendingReviews(forUser: userId)
        if !remaining.isEmpty {
            reviews = Array(remaining.prefix(pageSize))
            selected = []
            thumbs = [:]
        } else {
            addedCount = added
        }
    }
}
