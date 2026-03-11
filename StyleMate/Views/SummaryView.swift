import SwiftUI

struct SummaryView: View {
    let savedItems: [WardrobeItem]
    var onDone: () -> Void

    var body: some View {
        ZStack {
            DS.Colors.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: DS.Spacing.xl) {
                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(DS.Colors.success)

                Text("Added to Wardrobe")
                    .font(DS.Font.title2)
                    .foregroundColor(DS.Colors.textPrimary)

                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("Items Added")
                        .font(DS.Font.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.bottom, DS.Spacing.micro)

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(summaryStrings, id: \.self) { str in
                                HStack {
                                    Text(str)
                                        .font(DS.Font.body)
                                        .foregroundColor(DS.Colors.textPrimary)
                                    Spacer()
                                }
                                .padding(.vertical, DS.Spacing.sm)

                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
                .padding(DS.Spacing.md)
                .background(DS.Colors.backgroundCard)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                .dsCardShadow()

                Spacer()

                Button("Done") {
                    Haptics.success()
                    onDone()
                }
                .buttonStyle(DSPrimaryButton())
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.bottom, DS.Spacing.xl)
            }
            .padding(.horizontal, DS.Spacing.screenH)
            .onAppear { Haptics.success() }
        }
    }

    var summaryStrings: [String] {
        let grouped = Dictionary(grouping: savedItems, by: { $0.product })
        return grouped.map { (product, items) in
            let plural = (items.count > 1 && !product.lowercased().hasSuffix("s")) ? "s" : ""
            return "\(items.count) \(product)\(plural)"
        }.sorted()
    }
}
