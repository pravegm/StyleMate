import SwiftUI

/// "Find yourself": StyleMate looks through recent photos on the phone, groups faces of the same
/// person and asks "Is this you?" about the group that matches the selfie. One tap confirms;
/// tap any face that isn't you first. Used as the last onboarding step and from Profile.
struct FindYourselfView: View {
    enum Mode { case onboarding, standalone }

    let userId: String
    var mode: Mode = .onboarding
    /// Called with the number of faces added to the reference gallery.
    let onFinish: (Int) -> Void

    @StateObject private var vm = FaceReferenceViewModel()
    @State private var appeared = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.xs), count: 4)

    var body: some View {
        ZStack {
            DS.Colors.backgroundPrimary.ignoresSafeArea()
            content
                .transition(.opacity)
        }
        .animation(DS.Motion.smooth, value: vm.phase)
        .animation(DS.Motion.smooth, value: vm.round)
        .task { await vm.start(forUser: userId) }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.phase {
        case .idle, .scanning:
            scanningState
        case .reviewing:
            reviewState
        case .saving:
            savingState
        case .finished:
            finishedState
        case .nothingFound:
            messageState(
                icon: "person.crop.circle.badge.questionmark",
                title: "We couldn't spot you yet",
                message: vm.hasSelfieAnchor
                    ? "That's okay. StyleMate keeps learning as it scans, and asks \"Is this you?\" whenever it isn't sure."
                    : "That's okay. Without a selfie StyleMate can't tell who you are yet. You can take one anytime in Profile.",
                cta: continueTitle,
                action: { onFinish(0) })
        case .emptyLibrary:
            messageState(
                icon: "photo.on.rectangle.angled",
                title: vm.isLimitedAccess ? "No photos shared yet" : "No photos yet",
                message: vm.isLimitedAccess
                    ? "Share some photos of yourself and StyleMate will learn what you look like."
                    : "Once you've taken a few photos, StyleMate will learn to spot you in them.",
                cta: continueTitle,
                action: { onFinish(0) })
        case .noPermission:
            messageState(
                icon: "lock.shield",
                title: "Photo access is off",
                message: "StyleMate needs your photos to find you and your outfits. They're only ever looked at on this phone.",
                cta: "Open Settings",
                action: {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                },
                secondary: continueTitle,
                onSecondary: { onFinish(0) })
        }
    }

    private var continueTitle: String { mode == .onboarding ? "Continue" : "Done" }

    // MARK: - Scanning

    private var scanningState: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer(minLength: DS.Spacing.lg)

            ScanningOrb(previews: vm.likelyYouPreview)
                .frame(width: 200, height: 200)

            VStack(spacing: DS.Spacing.xs) {
                Text("Finding you in your photos")
                    .font(DS.Font.title2)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text(scanSubtitle)
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(DS.Motion.snappy, value: vm.scannedCount)
            }
            .padding(.horizontal, DS.Spacing.xl)

            ProgressView(value: vm.progress)
                .progressViewStyle(.linear)
                .tint(DS.Colors.accent)
                .frame(maxWidth: 240)

            if vm.likelyYouCount > 0 {
                Label("\(vm.likelyYouCount) photos look like you", systemImage: "sparkles")
                    .font(DS.Font.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.accent)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.micro + 2)
                    .background(DS.Colors.accentSoft, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
                    .contentTransition(.numericText())
            }

            Spacer()

            privacyNote

            VStack(spacing: DS.Spacing.sm) {
                if vm.canStopEarly {
                    Button {
                        Haptics.medium()
                        vm.finishScanningNow()
                    } label: {
                        Text("Show me what you found")
                    }
                    .buttonStyle(DSSecondaryButton())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Button {
                    Haptics.light()
                    onFinish(0)
                } label: {
                    Text("Skip for now")
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.lg)
            .animation(DS.Motion.gentle, value: vm.canStopEarly)
        }
        .animation(DS.Motion.gentle, value: vm.likelyYouCount > 0)
    }

    private var scanSubtitle: String {
        guard vm.totalToScan > 0 else { return "Getting your photos ready…" }
        return "Looked at \(vm.scannedCount.formatted()) of \(vm.totalToScan.formatted()) recent photos"
    }

    private var privacyNote: some View {
        Label("Happens on this phone. Nothing is uploaded.", systemImage: "lock.shield.fill")
            .font(DS.Font.footnote)
            .foregroundStyle(DS.Colors.textTertiary)
    }

    // MARK: - Review

    private var reviewState: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    reviewHeader
                    if vm.isLimitedAccess { limitedBanner }
                    LazyVGrid(columns: columns, spacing: DS.Spacing.xs) {
                        ForEach(vm.candidates) { candidate in
                            FaceCell(candidate: candidate) {
                                Haptics.selection()
                                vm.toggle(candidate.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.top, DS.Spacing.md)
                .padding(.bottom, 2 * DS.ButtonSize.height + DS.Spacing.xxl)
            }
            .id(vm.round == .isThisYou ? "you-\(vm.offerNumber)" : "also")
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            reviewBar
        }
    }

    private var reviewHeader: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(vm.round == .isThisYou ? "Is this you?" : "Also you?")
                .font(DS.Font.largeTitle)
                .foregroundStyle(DS.Colors.textPrimary)
            Text(reviewSubtitle)
                .font(DS.Font.subheadline)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Spacing.xs) {
                Text("\(vm.selectedCount) of \(vm.candidates.count) selected")
                    .font(DS.Font.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .monospacedDigit()
                Spacer()
                Button(vm.selectedCount == vm.candidates.count ? "Clear all" : "Select all") {
                    Haptics.light()
                    vm.setAll(selected: vm.selectedCount != vm.candidates.count)
                }
                .font(DS.Font.footnote.weight(.semibold))
                .foregroundStyle(DS.Colors.accent)
            }
            .padding(.top, DS.Spacing.micro)
        }
    }

    private var reviewSubtitle: String {
        switch vm.round {
        case .isThisYou:
            return vm.offerNumber == 1
                ? "We grouped faces from your photos that look alike. Untick any that aren't you, then confirm."
                : "How about this group? Untick any that aren't you."
        case .alsoYou:
            return "These look like you in other light, angles or looks. Adding them helps StyleMate find you in more photos."
        }
    }

    private var limitedBanner: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "photo.badge.plus")
                .foregroundStyle(DS.Colors.accent)
            VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                Text("You're sharing selected photos only")
                    .font(DS.Font.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Button("Share more photos") {
                    Haptics.light()
                    vm.shareMorePhotos()
                }
                .font(DS.Font.footnote.weight(.semibold))
                .foregroundStyle(DS.Colors.accent)
            }
            Spacer(minLength: 0)
        }
        .dsCard(padding: DS.Spacing.sm)
    }

    private var reviewBar: some View {
        VStack(spacing: DS.Spacing.xs) {
            Button {
                Haptics.success()
                vm.confirmSelection()
            } label: {
                Text(primaryTitle)
            }
            .buttonStyle(DSPrimaryButton(isDisabled: vm.selectedCount == 0))
            .disabled(vm.selectedCount == 0)

            Button {
                Haptics.light()
                if vm.round == .isThisYou { vm.rejectGroup() } else { vm.skipAlsoYou() }
            } label: {
                Text(vm.round == .isThisYou ? "That's not me" : "Skip")
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(DSTertiaryButton())
        }
        .padding(.horizontal, DS.Spacing.screenH)
        .padding(.top, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.sm)
        .background(.ultraThinMaterial)
    }

    private var primaryTitle: String {
        let n = vm.selectedCount
        if n == 0 { return "Select the photos of you" }
        switch vm.round {
        case .isThisYou: return "Yes, that's me (\(n))"
        case .alsoYou: return "Add \(n) more"
        }
    }

    // MARK: - Saving / finished

    private var savingState: some View {
        VStack(spacing: DS.Spacing.md) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(DS.Colors.accent)
            Text("Learning your face…")
                .font(DS.Font.title3)
                .foregroundStyle(DS.Colors.textPrimary)
            privacyNote
            Spacer()
        }
    }

    private var finishedState: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()
            ZStack {
                Circle()
                    .fill(DS.Colors.success.opacity(0.14))
                    .frame(width: 112, height: 112)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(DS.Colors.success)
                    .symbolEffect(.bounce, value: appeared)
            }
            VStack(spacing: DS.Spacing.xs) {
                Text("Got it, that's you")
                    .font(DS.Font.title1)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("StyleMate learned your face from \(vm.confirmedCount) photo\(vm.confirmedCount == 1 ? "" : "s"). It'll use that to find your outfits, and only ever take your clothes, never other people's.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Spacing.xl)
            privacyNote
            Spacer()
            Button {
                Haptics.medium()
                onFinish(vm.addedCount)
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Text(mode == .onboarding ? "Build my wardrobe" : "Done")
                    if mode == .onboarding { Image(systemName: "arrow.right") }
                }
            }
            .buttonStyle(DSPrimaryButton())
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.lg)
        }
        .onAppear {
            appeared = true
            Haptics.success()
        }
    }

    // MARK: - Message

    private func messageState(icon: String, title: String, message: String, cta: String,
                              action: @escaping () -> Void,
                              secondary: String? = nil, onSecondary: (() -> Void)? = nil) -> some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()
            DSEmptyState(icon: icon, title: title, message: message)
            if vm.isLimitedAccess, vm.phase != .noPermission {
                Button("Share more photos") {
                    Haptics.light()
                    vm.shareMorePhotos()
                }
                .buttonStyle(DSSecondaryButton())
                .padding(.horizontal, DS.Spacing.xxl)
            }
            Spacer()
            VStack(spacing: DS.Spacing.sm) {
                Button(action: {
                    Haptics.medium()
                    action()
                }) {
                    Text(cta)
                }
                .buttonStyle(DSPrimaryButton())
                if let secondary, let onSecondary {
                    Button(secondary) {
                        Haptics.light()
                        onSecondary()
                    }
                    .buttonStyle(DSTertiaryButton())
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.lg)
        }
    }
}

// MARK: - Face cell

private struct FaceCell: View {
    let candidate: FaceCandidate
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Rectangle()
                .fill(DS.Colors.backgroundSecondary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(uiImage: candidate.thumbnail)
                        .resizable()
                        .scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .fill(Color.black.opacity(candidate.isSelected ? 0 : 0.45))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(candidate.isSelected ? DS.Colors.accent : Color.clear, lineWidth: 3)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: candidate.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(candidate.isSelected ? Color.white : Color.white.opacity(0.85),
                                         candidate.isSelected ? DS.Colors.accent : Color.clear)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .padding(5)
                }
                .scaleEffect(candidate.isSelected ? 1 : 0.94)
                .animation(DS.Motion.press, value: candidate.isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.isSelected ? "Photo of you, selected" : "Photo, not selected")
        .accessibilityHint("Double-tap to toggle")
    }
}

// MARK: - Scanning orb

/// A pulsing ring with the faces that look like you drifting in as they're found.
private struct ScanningOrb: View {
    let previews: [UIImage]
    @State private var pulse = false
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .fill(DS.Colors.accentSoft)
                .scaleEffect(pulse ? 1.0 : 0.86)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(DS.Colors.accent.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .padding(6)

            if previews.isEmpty {
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DS.Colors.accent)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            } else {
                ForEach(Array(previews.enumerated()), id: \.offset) { index, image in
                    let angle = Double(index) / Double(max(previews.count, 1)) * 2 * .pi
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                        .offset(x: cos(angle) * 62, y: sin(angle) * 62)
                        .transition(.scale.combined(with: .opacity))
                }
                Image(systemName: "person.fill.viewfinder")
                    .font(.system(size: 34))
                    .foregroundStyle(DS.Colors.accent)
            }
        }
        .animation(DS.Motion.bouncy, value: previews.count)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { spin = true }
        }
        .accessibilityHidden(true)
    }
}
