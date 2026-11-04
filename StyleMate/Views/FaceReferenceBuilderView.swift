import SwiftUI

/// "Find yourself" as a sheet (from Profile): looks through recent photos on the phone, groups
/// faces of the same person and asks "Is this you?", so the app recognizes you in photos with
/// other people. The onboarding uses the same `FindYourselfView` inline.
struct FaceReferenceBuilderView: View {
    let userId: String
    @Binding var isPresented: Bool
    var onComplete: ((Int) -> Void)? = nil

    var body: some View {
        NavigationStack {
            FindYourselfView(userId: userId, mode: .standalone) { added in
                onComplete?(added)
                isPresented = false
            }
            .navigationTitle("Find yourself")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }
}
