import SwiftUI

struct ItemDetailSheet: View {
    let item: WardrobeItem
    var onEdit: () -> Void
    var onReplacePhoto: () -> Void
    var onDelete: () -> Void
    var onImageTap: (UIImage) -> Void

    @State private var showDeleteConfirmation = false
    @State private var sheetAppeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.md) {
                itemImage
                itemHeader
                attributeChips
                colorsSection
                detailsSection
                actionButtons
            }
            .padding(.horizontal, DS.Spacing.screenH)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.xl)
        }
        .background(DS.Colors.backgroundPrimary)
        .opacity(sheetAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.15)) { sheetAppeared = true }
        }
        .alert("Delete Item?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove this item from your wardrobe.")
        }
    }

    // MARK: - Item Image

    @ViewBuilder
    private var itemImage: some View {
        Button {
            if let img = item.croppedImage ?? item.image {
                onImageTap(img)
            }
        } label: {
            Group {
                if let img = item.croppedImage ?? item.image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: DS.Radius.hero)
                        .fill(DS.Colors.backgroundSecondary)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 32))
                                .foregroundColor(DS.Colors.textTertiary)
                        )
                }
            }
            .frame(maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.hero))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Header

    @ViewBuilder
    private var itemHeader: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.micro) {
            Text(item.name)
                .font(DS.Font.title3)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Circle()
                    .fill(DS.Colors.accent)
                    .frame(width: 6, height: 6)
                Text(item.category.rawValue)
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.accent)
            }

            if !item.brand.isEmpty {
                Text(item.brand)
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Attribute Chips

    @ViewBuilder
    private var attributeChips: some View {
        let chips = buildChips()
        if !chips.isEmpty {
            FlowLayout(spacing: DS.Spacing.xs) {
                ForEach(chips, id: \.self) { chip in
                    Text(chip)
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, DS.Spacing.xs)
                        .background(DS.Colors.backgroundSecondary)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(DS.Colors.textTertiary.opacity(0.2), lineWidth: 0.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func buildChips() -> [String] {
        var chips: [String] = []

        if let material = item.material, !material.isEmpty {
            chips.append(material)
        }
        if let fit = item.fit, fit != .regular {
            chips.append(fit.rawValue)
        }
        if item.pattern != .solid {
            chips.append(item.pattern.rawValue)
        }
        if let neckline = item.neckline {
            chips.append(neckline.rawValue)
        }
        if let sleeve = item.sleeveLength {
            chips.append(sleeve.rawValue)
        }
        if let length = item.garmentLength {
            chips.append(length.rawValue)
        }

        return chips
    }

    // MARK: - Colors

    @ViewBuilder
    private var colorsSection: some View {
        if !item.colors.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Colors")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textTertiary)

                HStack(spacing: DS.Spacing.sm) {
                    ForEach(item.colors, id: \.self) { colorName in
                        HStack(spacing: DS.Spacing.micro) {
                            Circle()
                                .fill(ColorMapping.color(for: colorName))
                                .frame(width: 16, height: 16)
                                .overlay(Circle().stroke(Color.black.opacity(0.1), lineWidth: 1))
                            Text(colorName)
                                .font(DS.Font.subheadline)
                                .foregroundColor(DS.Colors.textPrimary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Details

    @ViewBuilder
    private var detailsSection: some View {
        if let details = item.details, !details.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Details")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textTertiary)

                Text(details)
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Button(action: onEdit) {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "pencil")
                        Text("Edit")
                    }
                }
                .buttonStyle(DSSecondaryButton())

                Button(action: onReplacePhoto) {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "camera")
                        Text("Replace Photo")
                    }
                }
                .buttonStyle(DSSecondaryButton())
            }

            Button(action: { showDeleteConfirmation = true }) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "trash")
                    Text("Delete")
                }
                .foregroundColor(DS.Colors.error)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.xs)
                .background(DS.Colors.error.opacity(0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(DSTapBounce())
            .frame(height: 44)
        }
        .padding(.top, DS.Spacing.xs)
    }
}
