import SwiftUI

/// Home, when the closet can't make a whole outfit yet: what's there, what's missing, and
/// one way to fix it. Replaces the Today's look card until `OutfitReadiness` says ready.
struct AlmostReadyCard: View {
    let status: OutfitReadiness.Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                Text("Almost ready")
                    .font(DS.Font.title3)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Text("\(OutfitReadiness.Need.allCases.count - status.missing.count) of \(OutfitReadiness.Need.allCases.count)")
                    .font(DS.Font.footnote.weight(.semibold))
                    .foregroundStyle(DS.Colors.accent)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }

            if let message = OutfitReadiness.message(for: status) {
                Text(message)
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.almostReady.message")
            }

            HStack(spacing: DS.Spacing.xs) {
                ForEach(OutfitReadiness.Need.allCases) { need in
                    needTile(need, done: status.has[need] ?? false)
                }
            }

            if status.dressWouldHelp {
                Text("A dress or jumpsuit counts as a top and a bottom.")
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Haptics.medium()
                NotificationCenter.default.post(name: .showAddClothes, object: nil)
            } label: {
                Label("Add clothes", systemImage: "plus")
            }
            .buttonStyle(DSPrimaryButton())
            .accessibilityHint("Add pieces with the camera, from your photos or with a scan")
            .accessibilityIdentifier("home.almostReady.add")
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero, style: .continuous))
        .dsElevatedShadow(cornerRadius: DS.Radius.hero)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.almostReady")
        .animation(DSMotionEnv.resolve(DS.Motion.smooth, reduceMotion: reduceMotion), value: status.missing)
    }

    private func needTile(_ need: OutfitReadiness.Need, done: Bool) -> some View {
        VStack(spacing: DS.Spacing.micro) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: need.icon)
                    .font(.system(size: 22, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(done ? DS.Colors.accent : DS.Colors.textTertiary)
                    .frame(width: 44, height: 40)
                Image(systemName: done ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(done ? DS.Colors.success : DS.Colors.textTertiary)
                    .background(Circle().fill(DS.Colors.backgroundCard).padding(1))
                    .offset(x: 6, y: -2)
            }
            Text(need.label)
                .font(DS.Font.caption1)
                .foregroundStyle(done ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(done ? DS.Colors.accentSoft : DS.Colors.backgroundSecondary)
            if !done {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Colors.textTertiary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(need.label): \(done ? "in your closet" : "missing")")
    }
}
