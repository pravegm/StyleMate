import SwiftUI

struct OutfitCardActionsColumn: View {
    let notes: String?
    @Binding var showEditSheet: Bool
    @Binding var showDeleteAlert: Bool
    var onEdit: () -> Void
    var onDelete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Notes (narrower width)
            if let notes = notes, !notes.isEmpty {
                Text(notes)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                    .frame(width: 64, alignment: .topLeading)
            }
            // Edit/Delete buttons (vertical stack)
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onEdit) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .foregroundColor(.accentColor)
                        Text("Edit")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
                .accessibilityLabel("Edit Outfit")
                Button(action: onDelete) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                        Text("Delete")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .accessibilityLabel("Delete Outfit")
            }
            .padding(.top, 2)
        }
    }
} 