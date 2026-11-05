import SwiftUI
import StoreKit

/// StyleMate Premium: unlimited wardrobe. The hook is the user's own closet (their real cutouts)
/// and the pieces the scan already found and is holding for them.
///
/// App Review 3.1.2: each plan shows its StoreKit price and period, the trial terms (only when
/// the user is eligible), the auto-renew disclosure, Restore Purchases, Terms of Use (Apple's
/// standard EULA) and the privacy policy.
///
/// Phone / Duo cover: one scrolling column with the button pinned at the bottom. Duo inner
/// display (and other wide layouts): `FoldAwareSplit`, the closet on one half and the plans on
/// the other, split exactly on the crease when half-open, so nothing sits on the fold.
struct PaywallView: View {
    let reason: PaywallReason

    @EnvironmentObject private var wardrobe: WardrobeViewModel
    @ObservedObject private var store = PremiumStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase
    @Environment(\.duoLayout) private var duo

    @State private var selectedID = PremiumProducts.annual
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var restoreMessage: String?
    /// Set once a purchase (or restore) made Premium active here: how many pieces it unlocked.
    @State private var unlocked: Int?
    /// Pieces waiting when the paywall opened (Premium can also arrive via Transaction.updates:
    /// Ask to Buy approved, bought on another device), so the success screen can count what unlocked.
    @State private var lockedAtOpen: Int?

    private var selected: Product? { store.product(selectedID) ?? store.products.first }
    private var userId: String { wardrobe.currentUserEmail }

    var body: some View {
        ZStack {
            background
            if store.isPremium {
                successView
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if duo.isWideLayout {
                wideLayout
            } else {
                compactLayout
            }
        }
        .overlay(alignment: .topTrailing) { closeButton }
        .animation(DS.Motion.smooth, value: store.isPremium)
        .task { await store.loadProducts() }
        .onAppear { if lockedAtOpen == nil { lockedAtOpen = wardrobe.lockedItems.count } }
        .alert("Purchase didn't go through", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Restore Purchases", isPresented: Binding(
            get: { restoreMessage != nil && !store.isPremium }, set: { if !$0 { restoreMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreMessage ?? "")
        }
    }

    // MARK: Layouts

    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                heroHeader
                plans
                benefits
                legal
            }
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.top, DS.Spacing.xxl)
            .padding(.bottom, DS.Spacing.lg)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: DS.Spacing.xs) {
                purchaseButton
                priceLine
            }
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.top, DS.Spacing.sm)
            .padding(.bottom, DS.Spacing.xs)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private var wideLayout: some View {
        ScrollView {
            FoldAwareSplit(gutter: DS.Spacing.xl, stackedSpacing: DS.Spacing.lg) {
                hero
                    .frame(maxWidth: 440, alignment: .leading)
                    .frame(maxWidth: .infinity)
            } trailing: {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    plans
                    purchaseButton
                    priceLine
                    legal
                }
                .frame(maxWidth: 420, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.top, DS.Spacing.xxxl)   // clear of the close button above the plans
            .padding(.bottom, DS.Spacing.xl)
        }
        .scrollIndicators(.hidden)
    }

    private var background: some View {
        ZStack(alignment: .top) {
            DS.Colors.backgroundPrimary
            LinearGradient(colors: [DS.Colors.accentSoft, DS.Colors.backgroundPrimary.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 360)
        }
        .ignoresSafeArea()
    }

    private var closeButton: some View {
        Button {
            Haptics.light()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(width: 32, height: 32)
                .background(DS.Colors.backgroundCard.opacity(0.9), in: Circle())
                .dsCardShadow(cornerRadius: 16)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(DSTapBounce())
        .padding(.trailing, DS.Spacing.sm)
        .padding(.top, DS.Spacing.xs)
        .accessibilityLabel(store.isPremium ? "Done" : "Close")
        .accessibilityIdentifier("paywall.close")
    }

    // MARK: Hero (the user's own closet)

    /// Wide: the closet, the pitch and the benefits on one half.
    private var hero: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            heroHeader
            benefits
        }
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            // Phone / cover: one row of four, so the plans come into view sooner; wide: 3 x 2.
            PaywallCollage(owned: ownedPreview, locked: lockedPreview, lockedCount: wardrobe.lockedItems.count,
                           columnCount: duo.isWideLayout ? 3 : 4, maxTiles: duo.isWideLayout ? 6 : 4)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("StyleMate Premium")
                    .font(DS.Font.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.accent)
                    .textCase(.uppercase)
                Text(headline)
                    .font(DS.Font.title1)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(subheadline)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                benefit("infinity", "Unlimited wardrobe", "Every piece the scan finds goes straight into your closet.")
                benefit("sparkles", "Outfits from everything you own", "Today's looks draw on your whole closet, not just the first \(WardrobeAllowance.freeItemLimit) pieces.")
                benefit("lock.shield.fill", "Still private, still on your iPhone", "No ads, no tracking, no password. Your photos never leave the phone.")
            }
            .padding(.top, DS.Spacing.xs)
    }

    private var ownedPreview: [WardrobeItem] {
        let samples = wardrobe.sampleIDs
        let own = wardrobe.items.filter { !samples.contains($0.id) }
        return Array((own.isEmpty ? wardrobe.items : own).suffix(6).reversed())
    }

    private var lockedPreview: [WardrobeItem] { Array(wardrobe.lockedItems.prefix(3)) }

    private var headline: String {
        switch reason {
        case .lockedItems where wardrobe.lockedItems.count > 0:
            return "\(wardrobe.lockedItems.count) more piece\(wardrobe.lockedItems.count == 1 ? " is" : "s are") waiting for your closet"
        case .batchOverflow(let n):
            return "\(n) piece\(n == 1 ? " is" : "s are") saved and waiting"
        default:
            return "Keep every piece you own"
        }
    }

    private var subheadline: String {
        let limit = WardrobeAllowance.freeItemLimit
        switch reason {
        case .lockedItems where wardrobe.lockedItems.count > 0:
            return "StyleMate found them in your photos after your first \(limit) free pieces. Premium adds them all now, and everything it finds from here on."
        case .batchOverflow:
            return "Your first \(limit) pieces are free. Premium adds the rest to your closet straight away."
        case .atLimit:
            return "Your free wardrobe holds \(limit) pieces and it's full. Premium makes it unlimited, so you can keep adding."
        default:
            return WardrobeAllowance.freeTierLine
        }
    }

    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Colors.accent)
                .frame(width: 32, height: 32)
                .background(DS.Colors.accentSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(detail)
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Plans

    @ViewBuilder
    private var plans: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if store.isPendingApproval {
                pendingBanner
            }
            switch store.loadState {
            case .loaded where !store.products.isEmpty:
                ForEach(store.products, id: \.id) { product in
                    PaywallPlanCard(product: product,
                                    isSelected: product.id == selected?.id,
                                    saving: saving(for: product),
                                    showsTrial: store.isTrialEligible && product.freeTrialText != nil) {
                        Haptics.selection()
                        withAnimation(DS.Motion.snappy) { selectedID = product.id }
                    }
                }
            case .failed, .loaded:
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Label("Couldn't reach the App Store", systemImage: "wifi.exclamationmark")
                        .font(DS.Font.headline)
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("Check your connection, then try again. Your pieces are safe while you wait.")
                        .font(DS.Font.subheadline)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { Task { await store.loadProducts() } }
                        .buttonStyle(DSSecondaryButton())
                        .accessibilityIdentifier("paywall.retry")
                }
                .padding(DS.Spacing.md)
                .background(DS.Colors.backgroundCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            case .idle, .loading:
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .fill(DS.Colors.backgroundCard)
                        .frame(height: 92)
                        .overlay(ProgressView())
                }
                .accessibilityLabel("Loading plans")
            }
        }
    }

    private var pendingBanner: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "hourglass")
                .foregroundStyle(DS.Colors.accentSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for approval")
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("Premium starts as soon as the purchase is approved, and your pieces unlock by themselves.")
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.backgroundCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywall.pending")
    }

    /// "Save 47%" on the annual plan, computed from the two StoreKit prices.
    private func saving(for product: Product) -> Int? {
        guard product.id == PremiumProducts.annual, let monthly = store.product(PremiumProducts.monthly) else { return nil }
        return PremiumText.savingPercent(yearly: product.price, monthly: monthly.price)
    }

    private var trialApplies: Bool {
        store.isTrialEligible && selected?.freeTrialText != nil
    }

    private var purchaseButton: some View {
        Button {
            Task { await buy() }
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                if isPurchasing { ProgressView().tint(DS.Colors.onAccent) }
                Text(trialApplies ? "Start free trial" : "Subscribe")
            }
        }
        .buttonStyle(DSPrimaryButton(isDisabled: selected == nil || isPurchasing))
        .disabled(selected == nil || isPurchasing || isRestoring)
        .accessibilityIdentifier("paywall.subscribe")
    }

    /// The billed amount, as prominent as the trial: "1-week free trial, then £24.99 per year".
    @ViewBuilder
    private var priceLine: some View {
        if let product = selected {
            Text(trialApplies
                 ? "\(product.freeTrialText ?? ""), then \(product.pricePerPeriodText). Cancel anytime."
                 : "\(product.pricePerPeriodText). Cancel anytime.")
                .font(DS.Font.footnote.weight(.medium))
                .foregroundStyle(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("paywall.priceLine")
        }
    }

    // MARK: Legal (3.1.2)

    private var legal: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.md) {
                Button {
                    Task { await restore() }
                } label: {
                    HStack(spacing: 4) {
                        if isRestoring { ProgressView().controlSize(.small) }
                        Text("Restore Purchases")
                    }
                }
                .disabled(isRestoring || isPurchasing)
                .accessibilityIdentifier("paywall.restore")
                Link("Terms of Use", destination: PremiumProducts.termsOfUse)
                    .accessibilityIdentifier("paywall.terms")
                Link("Privacy Policy", destination: PremiumProducts.privacyPolicy)
                    .accessibilityIdentifier("paywall.privacy")
            }
            .font(DS.Font.footnote.weight(.semibold))
            .foregroundStyle(DS.Colors.accent)
            .frame(maxWidth: .infinity)

            Text(disclosure)
                .font(DS.Font.caption2)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("paywall.disclosure")
        }
    }

    private var disclosure: String {
        let renew = selected.map { "at \($0.pricePerPeriodText)" } ?? "at the same price and period"
        let trial = trialApplies
            ? " With a free trial, you're charged when the trial ends unless you cancel at least 24 hours before it does."
            : ""
        return "Payment is charged to your Apple Account when you confirm the purchase.\(trial) "
            + "The subscription renews automatically \(renew) unless it's cancelled at least 24 hours before the end of the current period; "
            + "renewal is charged within the 24 hours before the period ends. Manage or cancel anytime in Settings › your name › Subscriptions. "
            + "Your first \(WardrobeAllowance.freeItemLimit) pieces stay free either way, and if Premium ends, every piece you already have stays in your closet."
    }

    // MARK: Success

    /// Phone / cover: one centred column. Wide (Duo inner display): the message on one half, the
    /// pieces and Done on the other, split on the crease when half-open, so nothing crosses the fold.
    @ViewBuilder
    private var successView: some View {
        if duo.isWideLayout {
            VStack(spacing: 0) {
                Spacer(minLength: DS.Spacing.xl)
                FoldAwareSplit(gutter: DS.Spacing.xl, stackedSpacing: DS.Spacing.lg) {
                    successMessage
                        .frame(maxWidth: 400)
                        .frame(maxWidth: .infinity)
                } trailing: {
                    VStack(spacing: DS.Spacing.lg) {
                        successTiles
                        doneButton
                    }
                    .frame(maxWidth: 400)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, DS.Spacing.lg)
                Spacer(minLength: DS.Spacing.xl)
            }
        } else {
            VStack(spacing: DS.Spacing.lg) {
                Spacer(minLength: DS.Spacing.xl)
                successMessage
                successTiles
                Spacer(minLength: DS.Spacing.lg)
                doneButton
            }
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.bottom, DS.Spacing.lg)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private var successMessage: some View {
        VStack(spacing: DS.Spacing.lg) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DS.Colors.accent)
                .accessibilityHidden(true)
            VStack(spacing: DS.Spacing.xs) {
                Text("Welcome to Premium")
                    .font(DS.Font.title1)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(successDetail)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("paywall.successDetail")
            }
        }
    }

    @ViewBuilder
    private var successTiles: some View {
        if !ownedPreview.isEmpty {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(ownedPreview.prefix(4)) { item in
                    AsyncItemTile(path: item.gridImagePath, height: 64, cornerRadius: 14, inset: 6)
                        .frame(width: 64)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var doneButton: some View {
        Button("Done") {
            Haptics.light()
            dismiss()
        }
        .buttonStyle(DSPrimaryButton())
        .frame(maxWidth: 420)
        .accessibilityIdentifier("paywall.done")
    }

    private var successDetail: String {
        if let n = unlocked ?? lockedAtOpen.map({ max(0, $0 - wardrobe.lockedItems.count) }), n > 0 {
            return "\(n) piece\(n == 1 ? " was" : "s were") added to your closet. Everything StyleMate finds from now on goes straight in."
        }
        return "Your wardrobe is now unlimited. Everything StyleMate finds goes straight into your closet."
    }

    // MARK: Actions

    private func buy() async {
        guard let product = selected, !isPurchasing else { return }
        Haptics.medium()
        isPurchasing = true
        defer { isPurchasing = false }
        let before = wardrobe.lockedItems.count
        do {
            // The purchase belongs to the signed-in StyleMate account (`appAccountToken`).
            var options: Set<Product.PurchaseOption> = []
            if let token = store.accountToken { options.insert(.appAccountToken(token)) }
            let result = try await purchase(product, options: options)
            switch await store.handle(result) {
            case .purchased:
                Haptics.success()
                PremiumGate.reconcile(wardrobe)
                unlocked = max(0, before - wardrobe.lockedItems.count)
            case .pending, .cancelled:
                break
            case .failed(let message):
                errorMessage = message
            }
        } catch {
            errorMessage = PremiumStore.message(for: error)
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        let before = wardrobe.lockedItems.count
        let message = await store.restore()
        if store.isPremium {
            PremiumGate.reconcile(wardrobe)
            unlocked = max(0, before - wardrobe.lockedItems.count)
        } else if !message.isEmpty {
            restoreMessage = message
        }
    }
}

// MARK: - Plan card

private struct PaywallPlanCard: View {
    let product: Product
    let isSelected: Bool
    let saving: Int?
    let showsTrial: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? DS.Colors.accent : DS.Colors.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(product.displayName)
                            .font(DS.Font.headline)
                            .foregroundStyle(DS.Colors.textPrimary)
                        if let saving {
                            Text("Save \(saving)%")
                                .font(DS.Font.caption1.weight(.bold))
                                .foregroundStyle(DS.Colors.onAccent)
                                .padding(.horizontal, DS.Spacing.xs)
                                .padding(.vertical, 3)
                                .background(DS.Colors.accent, in: Capsule())
                        }
                    }
                    Text(product.pricePerPeriodText)
                        .font(DS.Font.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                    if let perMonth = product.monthlyEquivalentText {
                        Text("Works out at \(perMonth) a month")
                            .font(DS.Font.footnote)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    if showsTrial, let trial = product.freeTrialText {
                        Label(trial.prefix(1).uppercased() + trial.dropFirst(), systemImage: "gift.fill")
                            .font(DS.Font.footnote.weight(.semibold))
                            .foregroundStyle(DS.Colors.accent)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.backgroundCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? DS.Colors.accent : DS.Colors.separator, lineWidth: isSelected ? 2 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(DSTapBounce())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier(product.id == PremiumProducts.annual ? "paywall.plan.annual" : "paywall.plan.monthly")
    }
}

// MARK: - Collage

/// The user's own pieces on studio tiles, with the waiting (locked) ones softened behind a lock.
struct PaywallCollage: View {
    let owned: [WardrobeItem]
    let locked: [WardrobeItem]
    let lockedCount: Int

    var columnCount = 3
    var maxTiles = 6

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount) }

    var body: some View {
        if owned.isEmpty && locked.isEmpty {
            Image(systemName: "hanger")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(DS.Colors.accent)
                .frame(width: 96, height: 96)
                .background(DS.Colors.accentSoft, in: Circle())
                .accessibilityHidden(true)
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(tiles) { tile in
                    // The lock sits in the tile's top corner, clear of the "+23 waiting" pill below.
                    ZStack(alignment: .topTrailing) {
                        AsyncItemTile(path: tile.item.gridImagePath, height: nil, cornerRadius: 16, inset: 8)
                            .blur(radius: tile.isLocked ? 5 : 0)
                            .opacity(tile.isLocked ? 0.75 : 1)
                        if tile.isLocked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(DS.Colors.onAccent)
                                .frame(width: 24, height: 24)
                                .background(DS.Colors.accent, in: Circle())
                                .padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if lockedCount > 0 {
                    Text("+\(lockedCount) waiting")
                        .font(DS.Font.caption1.weight(.bold))
                        .foregroundStyle(DS.Colors.onAccent)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, 6)
                        .background(DS.Colors.accent, in: Capsule())
                        .padding(DS.Spacing.xs)
                        .accessibilityIdentifier("paywall.lockedCount")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lockedCount > 0
                                ? "Pieces from your closet, and \(lockedCount) more waiting for Premium"
                                : "Pieces from your closet")
        }
    }

    private struct Tile: Identifiable {
        let item: WardrobeItem
        let isLocked: Bool
        var id: String { (isLocked ? "l" : "o") + item.id.uuidString }
    }

    /// Up to `maxTiles` tiles: the locked ones (at most half) last, so the grid ends on what's waiting.
    private var tiles: [Tile] {
        let lockedTiles = locked.prefix(maxTiles / 2).map { Tile(item: $0, isLocked: true) }
        let ownedTiles = owned.prefix(maxTiles - lockedTiles.count).map { Tile(item: $0, isLocked: false) }
        return ownedTiles + lockedTiles
    }
}
