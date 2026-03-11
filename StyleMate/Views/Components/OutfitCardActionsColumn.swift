import SwiftUI

struct OutfitCardActionsColumn: View {
    let notes: String?
    @Binding var showEditSheet: Bool
    @Binding var showDeleteAlert: Bool
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if let notes = notes, !notes.isEmpty {
                Text(notes)
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 64, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Button(action: onEdit) {
                    HStack(spacing: DS.Spacing.micro) {
                        Image(systemName: "pencil")
                        Text("Edit")
                            .font(DS.Font.caption1)
                    }
                    .foregroundColor(DS.Colors.accent)
                }

                Button(action: onDelete) {
                    HStack(spacing: DS.Spacing.micro) {
                        Image(systemName: "trash")
                        Text("Delete")
                            .font(DS.Font.caption1)
                    }
                    .foregroundColor(DS.Colors.error)
                }
            }
        }
    }
}
