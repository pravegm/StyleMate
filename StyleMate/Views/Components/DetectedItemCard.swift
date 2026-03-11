import SwiftUI
import PhotosUI
import Foundation

struct DetectedItemCard: View {
    @Binding var item: AddNewItemView.DetectedItem
    @Binding var brand: String
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                if let cropped = item.croppedImage {
                    Image(uiImage: cropped)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                }

                Spacer()

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: DS.Spacing.sm) {
                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    Text("Category")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textTertiary)
                    Picker("Category", selection: $item.category) {
                        ForEach(Category.allCases) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(DS.Colors.accent)
                }

                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    Text("Product")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textTertiary)
                    Picker("Product", selection: $item.product) {
                        ForEach(productOptionsByCategory(item.category), id: \.self) { prod in
                            Text(prod).tag(prod)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(DS.Colors.accent)
                }
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Colors")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textTertiary)

                ForEach(Array(item.colors.enumerated()), id: \.offset) { colorIdx, _ in
                    HStack(spacing: DS.Spacing.xs) {
                        colorSwatch(for: item.colors[colorIdx])

                        TextField("Color", text: Binding(
                            get: { item.colors[colorIdx] },
                            set: { item.colors[colorIdx] = $0 }
                        ))
                        .font(DS.Font.body)
                        .textContentType(.none)
                        .autocapitalization(.none)
                        .submitLabel(.done)
                        .onSubmit {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }

                        if item.colors.count > 1 {
                            Button {
                                var colors = item.colors
                                colors.remove(at: colorIdx)
                                item.colors = colors
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(DS.Colors.error)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Button {
                    var colors = item.colors
                    colors.append("")
                    item.colors = colors
                } label: {
                    HStack(spacing: DS.Spacing.micro) {
                        Image(systemName: "plus.circle.fill").foregroundColor(DS.Colors.success)
                        Text("Add Color").font(DS.Font.subheadline).foregroundColor(DS.Colors.accent)
                    }
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: DS.Spacing.sm) {
                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    Text("Pattern")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textTertiary)
                    Picker("Pattern", selection: $item.pattern) {
                        ForEach(Pattern.allCases) { pattern in
                            Text(pattern.rawValue).tag(pattern)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(DS.Colors.accent)
                }

                VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                    Text("Brand")
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textTertiary)
                    TextField("e.g. Nike", text: $brand)
                        .font(DS.Font.body)
                        .textContentType(.none)
                        .autocapitalization(.none)
                        .submitLabel(.done)
                        .onSubmit {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                }
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .dsCardShadow()
    }

    @ViewBuilder
    private func colorSwatch(for colorName: String) -> some View {
        let name = colorName.lowercased().trimmingCharacters(in: .whitespaces)
        let color: Color = {
            switch name {
            case "black":  return .black
            case "white":  return .white
            case "red":    return .red
            case "blue":   return .blue
            case "green":  return .green
            case "yellow": return .yellow
            case "orange": return .orange
            case "pink":   return .pink
            case "purple": return .purple
            case "brown":  return .brown
            case "gray", "grey": return .gray
            case "navy":   return Color(red: 0, green: 0, blue: 0.5)
            case "beige":  return Color(red: 0.96, green: 0.96, blue: 0.86)
            case "cream":  return Color(red: 1, green: 0.99, blue: 0.82)
            case "maroon": return Color(red: 0.5, green: 0, blue: 0)
            case "teal":   return .teal
            case "olive":  return Color(red: 0.5, green: 0.5, blue: 0)
            default:       return DS.Colors.backgroundSecondary
            }
        }()

        Circle()
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.black.opacity(0.1), lineWidth: 1))
    }

    private func productOptionsByCategory(_ category: Category) -> [String] {
        productTypesByCategory[category] ?? []
    }
}
