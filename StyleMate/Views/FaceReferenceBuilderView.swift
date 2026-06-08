import SwiftUI

/// "Tap the photos that are you" — builds the on-device face reference gallery
/// from the user's Selfies + Portrait photos so the app can recognize them in
/// uploaded/scanned photos that also contain other people.
struct FaceReferenceBuilderView: View {
    let userId: String
    @Binding var isPresented: Bool
    var onComplete: ((Int) -> Void)? = nil

    @StateObject private var vm = FaceReferenceViewModel()

    private let columns = [
        GridItem(.flexible(), spacing: DS.Spacing.xs),
        GridItem(.flexible(), spacing: DS.Spacing.xs),
        GridItem(.flexible(), spacing: DS.Spacing.xs)
    ]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                DS.Colors.backgroundPrimary.ignoresSafeArea()

                switch vm.phase {
                case .idle, .scanning:
                    scanningState
                case .noPermission:
                    messageState(icon: "photo.on.rectangle.angled",
                                 title: "Photo access needed",
                                 message: "StyleMate looks at your Selfies and Portrait photos — on your device — to learn your face. Grant photo access to continue.",
                                 cta: "Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                case .empty:
                    messageState(icon: "person.crop.circle.badge.questionmark",
                                 title: "No photos of you found",
                                 message: "We couldn't find clear face photos in your Selfies or Portraits. You can still add items — StyleMate just won't auto-pick you in group photos yet.",
                                 cta: "Done") { dismiss() }
                case .ready:
                    grid
                    bottomBar
                }
            }
            .navigationTitle("Recognize You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
            }
        }
        .task { await vm.scan(forUser: userId) }
    }

    // MARK: - Scanning

    private var scanningState: some View {
        VStack(spacing: DS.Spacing.md) {
            Spacer()
            ZStack {
                Circle().fill(DS.Colors.accentSoft).frame(width: 96, height: 96)
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DS.Colors.accent)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }

            Text("Finding photos of you")
                .font(DS.Font.title3)
                .foregroundStyle(DS.Colors.textPrimary)

            Text("StyleMate is scanning your Selfies & Portraits to learn what you look like. This lets it recognize you in photos with other people — and only ever pull out your clothes, never theirs.")
                .font(DS.Font.subheadline)
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Spacing.lg)

            ProgressView(value: vm.progress)
                .progressViewStyle(.linear)
                .tint(DS.Colors.accent)
                .frame(width: 220)
                .padding(.top, DS.Spacing.xs)

            Label("Runs entirely on your device", systemImage: "lock.shield.fill")
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textTertiary)
            Spacer()
        }
        .padding()
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    Text("Tap the photos that are you")
                        .font(DS.Font.title3)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(vm.hasAnchorRanking
                         ? "We pre-selected the ones that look like you. Add or remove any."
                         : "Select the faces that are you. The more you pick, the better recognition gets.")
                        .font(DS.Font.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .padding(.top, DS.Spacing.sm)

                LazyVGrid(columns: columns, spacing: DS.Spacing.xs) {
                    ForEach(vm.candidates) { candidate in
                        candidateCell(candidate)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.bottom, DS.Spacing.xxxl + DS.ButtonSize.height)
        }
    }

    private func candidateCell(_ candidate: FaceCandidate) -> some View {
        // A uniform square cell: the clear square sizes to the column width, the
        // thumbnail fills + clips inside it. Avoids the variable-height / overflow
        // that made rows overlap.
        Rectangle()
            .fill(Color.clear)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Image(uiImage: candidate.thumbnail)
                    .resizable()
                    .scaledToFill()
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay {
                if !candidate.isSelected {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .fill(Color.black.opacity(0.25))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .stroke(candidate.isSelected ? DS.Colors.accent : Color.clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                if candidate.isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, DS.Colors.accent)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.light()
                vm.toggle(candidate.id)
            }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Button {
                Haptics.success()
                let added = vm.confirm(forUser: userId)
                onComplete?(added)
                dismiss()
            } label: {
                Text(vm.selectedCount == 0 ? "Select at least one photo" : "Add \(vm.selectedCount) photo\(vm.selectedCount == 1 ? "" : "s")")
            }
            .buttonStyle(DSPrimaryButton(isDisabled: vm.selectedCount == 0))
            .disabled(vm.selectedCount == 0)
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.vertical, DS.Spacing.md)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Message State

    private func messageState(icon: String, title: String, message: String,
                              cta: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(DS.Colors.textTertiary)
            Text(title)
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(DS.Font.body)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xl)
            Spacer()
            Button(cta, action: action)
                .buttonStyle(DSPrimaryButton())
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.bottom, DS.Spacing.xl)
        }
    }

    private func dismiss() {
        isPresented = false
    }
}
