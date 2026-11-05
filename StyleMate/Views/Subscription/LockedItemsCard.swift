import SwiftUI

/// "23 more pieces found — unlock with Premium": shown on Home and at the top of the closet while
/// the account holds pieces past the free tier's limit (`WardrobeViewModel.lockedItems`, synced).
/// Tapping opens the paywall. Hidden when nothing is locked (and therefore always for Premium).
///
/// After a sync moved pieces this phone was showing into the locked set (another iPhone used the
/// free slots), the card says so first ("3 pieces moved to Premium because your other iPhone added
/// items"), until dismissed or the paywall is opened.
struct LockedItemsCard: View {
    @EnvironmentObject private var wardrobe: WardrobeViewModel

    var body: some View {
        if !wardrobe.lockedItems.isEmpty || wardrobe.allowanceNotice != nil {
            VStack(spacing: DS.Spacing.xs) {
                if let notice = wardrobe.allowanceNotice {
                    noticeBanner(notice)
                }
                if !wardrobe.lockedItems.isEmpty {
                    card
                }
            }
        }
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Colors.accentSecondary)
                .frame(width: 28, height: 28)
                .background(DS.Colors.accentSecondary.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Font.subheadline)
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                withAnimation(DS.Motion.smooth) { wardrobe.allowanceNotice = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.backgroundCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .dsCardShadow()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("premium.allowanceNotice")
    }

    private var card: some View {
        Button {
            Haptics.light()
            wardrobe.allowanceNotice = nil
            PaywallCenter.shared.present(.lockedItems)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                ZStack(alignment: .bottomTrailing) {
                    HStack(spacing: -12) {
                        ForEach(wardrobe.lockedItems.prefix(3)) { item in
                            AsyncItemTile(path: item.gridImagePath, height: 44, cornerRadius: 11, inset: 4)
                                .frame(width: 44)
                                .blur(radius: 2.5)
                                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(DS.Colors.backgroundCard, lineWidth: 2))
                        }
                    }
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.Colors.onAccent)
                        .frame(width: 20, height: 20)
                        .background(DS.Colors.accent, in: Circle())
                        .offset(x: 4, y: 4)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(WardrobeAllowance.lockedHeadline(wardrobe.lockedItems.count))
                        .font(DS.Font.headline)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .monospacedDigit()
                    Text("Unlock with Premium")
                        .font(DS.Font.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Colors.accent)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.backgroundCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Colors.accent.opacity(0.35), lineWidth: 1)
            }
            .dsCardShadow()
        }
        .buttonStyle(DSTapBounce())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(WardrobeAllowance.lockedHeadline(wardrobe.lockedItems.count)). Unlock with Premium")
        .accessibilityIdentifier("premium.lockedCard")
    }
}
