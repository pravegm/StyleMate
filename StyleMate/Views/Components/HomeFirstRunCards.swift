import SwiftUI
import Photos

/// Home's first-run and daily-habit cards, owned by the product side so Home
/// needs only one call site (`HomeFirstRunCards(homeVM: homeVM)`):
///
/// - **Sample clothes** — the closet holds the bundled samples: label them and
///   remove them in one tap.
/// - **Empty closet** — nothing found yet: "Try with sample photos".
/// - **"We weren't sure about 1 item — tap to add"** — items the scan held back.
/// - **"Wore this on Tue? … Log it"** — auto-log from new photos.
/// - **"Get tomorrow's look at 7:30?"** — the notification ask, shown only
///   after the first saved outfit.
///
/// It also routes a tapped morning notification to Today's Outfit.
struct HomeFirstRunCards: View {
    @ObservedObject var homeVM: HomeViewModel
    @EnvironmentObject private var wardrobe: WardrobeViewModel
    @EnvironmentObject private var outfits: MyOutfitsViewModel
    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var scan = PhotoScanService.shared
    @ObservedObject private var held = UncertainItemsStore.shared
    @ObservedObject private var wearLog = WearLogSuggestions.shared
    @ObservedObject private var morning = MorningLookScheduler.shared
    @ObservedObject private var router = NotificationRouter.shared
    @State private var showHeld = false
    @State private var showSelfie = false
    @State private var showFindYourself = false
    @State private var tookSelfie = false
    /// Re-read when a selfie sheet closes (the file lives on disk, not in observed state).
    @State private var hasSelfie = true

    private var userId: String { auth.user?.id ?? "" }
    private var sampleCount: Int { SampleLibrary.sampleCount(in: wardrobe.items, userId: userId) }
    private var loggedDays: Set<Date> { Set(outfits.outfitsByDate.filter { !$0.value.isEmpty }.keys) }
    private var hasLoggedOutfit: Bool { !loggedDays.isEmpty }
    /// Empty closet and nothing running (also when the scan couldn't start, e.g. no selfie).
    private var showSampleOffer: Bool {
        guard wardrobe.items.isEmpty, !scan.isWorking, SampleLibrary.isAvailable else { return false }
        switch scan.scanState {
        case .idle, .error: return true
        case .scanning, .completed: return false
        }
    }

    var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            if !hasSelfie {
                // Onboarding skipped the selfie: nothing can be found in the photos yet.
                NoSelfieCard(onSelfie: { Haptics.light(); showSelfie = true },
                             onSamples: sampleCount == 0 && wardrobe.items.isEmpty && SampleLibrary.isAvailable && !scan.isWorking
                                ? { Haptics.medium(); SampleLibrary.start(userId: userId, wardrobe: wardrobe) } : nil)
            }

            if sampleCount > 0 {
                SampleWardrobeBanner(count: sampleCount) {
                    Haptics.medium()
                    withAnimation(DS.Motion.smooth) { SampleLibrary.removeSamples(from: wardrobe, userId: userId) }
                }
            } else if showSampleOffer, hasSelfie {
                EmptyClosetSampleCard {
                    Haptics.medium()
                    SampleLibrary.start(userId: userId, wardrobe: wardrobe)
                }
            }

            // Pieces past the free tier's 50, waiting for Premium (Views/Subscription).
            LockedItemsCard()

            if !held.items.isEmpty {
                UncertainItemsCard(items: held.items) { showHeld = true }
            }

            if let suggestion = wearLog.next(loggedDays: loggedDays) {
                WearLogPromptCard(suggestion: suggestion, wardrobe: wardrobe.items,
                                  onLog: {
                                      Haptics.success()
                                      withAnimation(DS.Motion.smooth) {
                                          wearLog.log(suggestion, wardrobe: wardrobe.items, outfits: outfits)
                                      }
                                  },
                                  onDismiss: { withAnimation(DS.Motion.smooth) { wearLog.dismiss(suggestion) } })
            }

            if hasLoggedOutfit, morning.shouldOffer {
                MorningLookOfferCard(time: morning.timeText,
                                     onEnable: { Task { await morning.requestAndEnable() } },
                                     onDismiss: { withAnimation(DS.Motion.smooth) { morning.markOffered() } })
            }
        }
        .padding(.top, hasAnyCard ? DS.Spacing.md : 0)
        .sheet(isPresented: $showHeld) {
            UncertainItemsSheet(isPresented: $showHeld)
                .environmentObject(wardrobe)
        }
        // Selfie, then Find yourself, then the first scan (what onboarding would have done).
        .sheet(isPresented: $showSelfie, onDismiss: {
            hasSelfie = selfieOnFile()
            if tookSelfie {
                tookSelfie = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showFindYourself = true }
            }
        }) {
            RetakeSelfieSheet(onRetaken: { tookSelfie = true })
                .environmentObject(auth)
        }
        .sheet(isPresented: $showFindYourself, onDismiss: startFirstScan) {
            FaceReferenceBuilderView(userId: userId, isPresented: $showFindYourself)
        }
        .task(id: userId) {
            hasSelfie = selfieOnFile()
            held.load(forUser: userId)
            wearLog.load(forUser: userId)
            await morning.refreshAuthorization()
        }
        .onChange(of: router.pendingMorningLook) { day in
            guard let day else { return }
            router.pendingMorningLook = nil
            // The tab shell switches to Home on the same change; present once it's in front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                homeVM.openMorningLook(dayKey: day, wardrobe: wardrobe.items, user: auth.user)
            }
        }
        .onAppear {
            if let day = router.pendingMorningLook {
                router.pendingMorningLook = nil
                // Let Home finish appearing before presenting the sheet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    homeVM.openMorningLook(dayKey: day, wardrobe: wardrobe.items, user: auth.user)
                }
            }
        }
    }

    private func selfieOnFile() -> Bool {
        #if DEBUG
        // The UI tests' demo user stands in for someone who took the selfie in onboarding.
        if DebugLaunchSupport.isUITestSession { return true }
        #endif
        return LocalStore.hasSelfie(userId: userId)
    }

    /// After a late selfie: the first library scan, exactly as onboarding starts it.
    private func startFirstScan() {
        guard hasSelfie, !userId.isEmpty, !scan.isWorking,
              PHPhotoLibrary.authorizationStatus(for: .readWrite).allowsScan else { return }
        let gender = auth.user?.gender
        Task {
            await PhotoScanService.shared.startScan(forUser: userId, dateRange: OnboardingScanningView.firstScanRange,
                                                    userGender: gender, wardrobeViewModel: wardrobe,
                                                    trigger: .initial, firstLook: true)
        }
    }

    private var hasAnyCard: Bool {
        !hasSelfie || sampleCount > 0 || !held.items.isEmpty || !wardrobe.lockedItems.isEmpty || wardrobe.allowanceNotice != nil || wearLog.next(loggedDays: loggedDays) != nil
            || (hasLoggedOutfit && morning.shouldOffer)
            || showSampleOffer
    }
}

// MARK: - Cards

/// "Take a selfie to find your outfit photos": shown while the profile has no selfie (it was
/// skipped in onboarding). The scan needs one to recognise the person; sample photos are the other
/// way to see the app work.
struct NoSelfieCard: View {
    let onSelfie: () -> Void
    var onSamples: (() -> Void)?

    var body: some View {
        CardShell {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    Image(systemName: "person.crop.square.badge.camera")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DS.Colors.accent)
                        .frame(width: 36, height: 36)
                        .background(DS.Colors.accentSoft, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Take a selfie to find your outfit photos")
                            .font(DS.Font.headline)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("StyleMate recognises you from one quick selfie, then builds your closet from your photos, all on this iPhone.")
                            .font(DS.Font.subheadline)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button(action: onSelfie) {
                    Label("Take a selfie", systemImage: "camera.fill")
                }
                .buttonStyle(DSPrimaryButton())
                .accessibilityIdentifier("home.noSelfie.takeSelfie")
                if let onSamples {
                    Button(action: onSamples) {
                        Label("Try with sample photos", systemImage: "sparkles")
                    }
                    .buttonStyle(DSSecondaryButton())
                    .accessibilityIdentifier("home.noSelfie.trySamples")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.noSelfie")
    }
}

private struct CardShell<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.backgroundCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .dsCardShadow()
    }
}

struct SampleWardrobeBanner: View {
    let count: Int
    let onRemove: () -> Void

    var body: some View {
        CardShell {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DS.Colors.accent)
                    .frame(width: 36, height: 36)
                    .background(DS.Colors.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sample clothes")
                        .font(DS.Font.headline)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("\(count) item\(count == 1 ? " is" : "s are") from sample photos, not your own.")
                        .font(DS.Font.caption1)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                Spacer(minLength: DS.Spacing.xs)
                Button("Remove", action: onRemove)
                    .font(DS.Font.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.accent)
                    .accessibilityIdentifier("home.removeSamples")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct EmptyClosetSampleCard: View {
    let onTry: () -> Void

    var body: some View {
        CardShell {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Your closet is empty")
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("Add clothes with the camera or from a photo, or see how StyleMate works on a few sample photos first.")
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onTry) {
                    Label("Try with sample photos", systemImage: "sparkles")
                }
                .buttonStyle(DSSecondaryButton())
                .accessibilityIdentifier("home.trySamples")
            }
        }
    }
}

struct UncertainItemsCard: View {
    let items: [UncertainItemsStore.HeldItem]
    let onOpen: () -> Void

    var body: some View {
        Button(action: { Haptics.light(); onOpen() }) {
            CardShell {
                HStack(spacing: DS.Spacing.sm) {
                    HStack(spacing: -10) {
                        ForEach(items.prefix(3)) { held in
                            AsyncItemTile(path: held.item.thumbnailPath ?? held.item.imagePath,
                                           height: 40, cornerRadius: 10, inset: 4)
                                .frame(width: 40)
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.Colors.backgroundCard, lineWidth: 2))
                        }
                    }
                    Text(UncertainItemsStore.headline(count: items.count))
                        .font(DS.Font.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
            }
        }
        .buttonStyle(DSTapBounce())
        .accessibilityIdentifier("home.uncertainItems")
    }
}

struct WearLogPromptCard: View {
    let suggestion: WearLogSuggestions.Suggestion
    let wardrobe: [WardrobeItem]
    let onLog: () -> Void
    let onDismiss: () -> Void

    private var items: [WardrobeItem] {
        let ids = Set(suggestion.itemIDs)
        return wardrobe.filter { ids.contains($0.id) }
    }

    var body: some View {
        CardShell {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WearLogSuggestions.question(for: suggestion.date, now: Date()))
                            .font(DS.Font.headline)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text(WearLogSuggestions.summary(of: items))
                            .font(DS.Font.subheadline)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    Spacer(minLength: DS.Spacing.xs)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("Not this time")
                }
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(items.prefix(4)) { item in
                        AsyncItemTile(path: item.thumbnailPath ?? item.imagePath,
                                       height: 56, cornerRadius: 12, inset: 6)
                            .frame(width: 56)
                    }
                    Spacer(minLength: 0)
                    Button("Log it", action: onLog)
                        .font(DS.Font.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Colors.onAccent)
                        .padding(.horizontal, DS.Spacing.md)
                        .frame(height: 36)
                        .background(DS.Colors.accent, in: Capsule())
                        .accessibilityIdentifier("home.wearLog.log")
                }
            }
        }
    }
}

struct MorningLookOfferCard: View {
    let time: String
    let onEnable: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        CardShell {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: "sun.horizon.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DS.Colors.accent)
                    .frame(width: 36, height: 36)
                    .background(DS.Colors.accentSoft, in: Circle())
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("Get tomorrow's look at \(time)?")
                        .font(DS.Font.headline)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("A morning note with the weather and an outfit from your closet. Styled on your iPhone.")
                        .font(DS.Font.caption1)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Spacing.md) {
                        Button("Turn on", action: onEnable)
                            .font(DS.Font.subheadline.weight(.semibold))
                            .foregroundStyle(DS.Colors.accent)
                            .accessibilityIdentifier("home.morningLook.enable")
                        Button("Not now", action: onDismiss)
                            .font(DS.Font.subheadline)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Held items sheet

struct UncertainItemsSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var wardrobe: WardrobeViewModel
    @ObservedObject private var held = UncertainItemsStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    Text("StyleMate only adds what it's sure about. These might be real items, or bits of hair, bags or background. Add the ones that are yours.")
                        .font(DS.Font.subheadline)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(held.items) { entry in
                        row(entry)
                    }
                }
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.vertical, DS.Spacing.md)
            }
            .background(DS.Colors.backgroundPrimary)
            .navigationTitle("Not sure about these")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { isPresented = false } }
                if held.items.count > 1 {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Dismiss all") { held.dismissAll(); isPresented = false }
                    }
                }
            }
            .onChange(of: held.items.isEmpty) { empty in if empty { isPresented = false } }
        }
    }

    private func row(_ entry: UncertainItemsStore.HeldItem) -> some View {
        let item = entry.item
        return HStack(spacing: DS.Spacing.sm) {
            AsyncItemTile(path: item.imagePath, height: 72, cornerRadius: 14, inset: 6)
                .frame(width: 72)
            VStack(alignment: .leading, spacing: 2) {
                Text(ClosetText.displayName(item))
                    .font(DS.Font.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(2)
                Text(UncertainItemsStore.reason(entry.doubt))
                    .font(DS.Font.caption1)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer(minLength: DS.Spacing.xs)
            VStack(spacing: DS.Spacing.xs) {
                Button("Add") {
                    // Free wardrobe full: offer Premium (the item stays here until there's room).
                    if PremiumGate.isAtLimit(wardrobe) {
                        isPresented = false
                        PaywallCenter.shared.present(.atLimit, after: 0.6)
                        return
                    }
                    Haptics.success(); withAnimation { held.add(entry, to: wardrobe) }
                }
                    .font(DS.Font.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.onAccent)
                    .padding(.horizontal, DS.Spacing.md)
                    .frame(height: 32)
                    .background(DS.Colors.accent, in: Capsule())
                Button("Not mine") { withAnimation { held.dismiss(entry) } }
                    .font(DS.Font.caption1)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .padding(DS.Spacing.sm)
        .background(DS.Colors.backgroundCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}
