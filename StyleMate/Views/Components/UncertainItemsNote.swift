import SwiftUI

/// "We weren't sure about 1 item — tap to add": shown in a review screen when
/// some detected items start deselected because `ItemTrust` doubted them
/// (fragments, poor views, tiny jewelry). `deselected` are the cutouts of the
/// items currently not selected; only the ones ItemTrust flagged are counted.
struct UncertainItemsNote: View {
    let deselected: [UIImage]

    private var count: Int {
        deselected.filter { image in
            if case .some(.some) = ItemTrust.cachedDoubt(for: image) { return true }
            return false
        }.count
    }

    var body: some View {
        if count > 0 {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(DS.Colors.warning)
                Text(UncertainItemsStore.headline(count: count))
                    .font(DS.Font.caption1)
                    .foregroundStyle(DS.Colors.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(DS.Colors.accentSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("review.uncertainNote")
        }
    }
}
