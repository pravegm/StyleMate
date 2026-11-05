import SwiftUI

/// "23 more pieces found — unlock with Premium": shown on Home and at the top of the closet while
/// the scan holds pieces past the free tier's limit (`LockedItemsStore`). Tapping opens the
/// paywall. Hidden when nothing is locked (and therefore always for Premium users).
struct LockedItemsCard: View {
    @ObservedObject private var locked = LockedItemsStore.shared

    var body: some View {
        if locked.count > 0 {
            Button {
                Haptics.light()
                PaywallCenter.shared.present(.lockedItems)
            } label: {
                HStack(spacing: DS.Spacing.sm) {
                    ZStack(alignment: .bottomTrailing) {
                        HStack(spacing: -12) {
                            ForEach(locked.wardrobeItems.prefix(3)) { item in
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
                        Text(WardrobeAllowance.lockedHeadline(locked.count))
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
            .accessibilityLabel("\(WardrobeAllowance.lockedHeadline(locked.count)). Unlock with Premium")
            .accessibilityIdentifier("premium.lockedCard")
        }
    }
}
