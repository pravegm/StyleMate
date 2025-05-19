import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @State private var showingSignOutAlert = false
    @State private var showingOptionsMenu = false
    @State private var showEmptyConfirmation = false
    @State private var showStyleSheet = false
    @State private var tempSelectedStyles: [OutfitType] = []
    @State private var showStyleError = false
    
    private let maxStyles = 6
    private let allStyles = OutfitType.allCases
    
    var body: some View {
        NavigationStack {
            Form {
                if let user = authService.user {
                    Section("Personal Information") {
                        TextField("Your Name", text: .constant(user.name))
                            .textContentType(.name)
                            .disabled(true)
                        
                        Text(user.email)
                            .foregroundStyle(.secondary)
                    }
                    
                    Section("Preferences") {
                        VStack(alignment: .leading, spacing: 0) {
                            Button(action: {
                                if let user = authService.user {
                                    tempSelectedStyles = user.preferredStyles
                                    showStyleSheet = true
                                }
                            }) {
                                HStack {
                                    Text("Your Style Preferences")
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.gray)
                                }
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            Divider()
                            Toggle("Enable Notifications", isOn: .constant(user.notificationsEnabled))
                                .disabled(true)
                                .padding(.vertical, 8)
                        }
                    }
                }
                
                Section {
                    Button(role: .destructive) {
                        showingSignOutAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Sign Out")
                            Spacer()
                        }
                    }
                }
                
                Section("App Information") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            showEmptyConfirmation = true
                        } label: {
                            Label("Empty My Wardrobe", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .imageScale(.large)
                            .accessibilityLabel("Options Menu")
                    }
                }
            }
            .alert("Sign Out", isPresented: $showingSignOutAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) {
                    do {
                        try authService.signOut()
                    } catch {
                        // Error handling removed
                    }
                }
            } message: {
                Text("Are you sure you want to sign out?")
            }
            .alert("Are you sure you want to empty your wardrobe?", isPresented: $showEmptyConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Empty", role: .destructive) {
                    for item in wardrobeViewModel.items {
                        WardrobeImageFileHelper.deleteImage(at: item.imagePath)
                        WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath)
                    }
                    wardrobeViewModel.items.removeAll()
                }
            } message: {
                Text("This will remove all items from your wardrobe and cannot be undone.")
            }
            .padding(.bottom, 120)
            .sheet(isPresented: $showStyleSheet) {
                StylePreferencesSheet(
                    selectedStyles: $tempSelectedStyles,
                    showStyleError: $showStyleError,
                    onApply: {
                        if tempSelectedStyles.count == maxStyles {
                            if var user = authService.user {
                                user.preferredStyles = tempSelectedStyles
                                authService.user = user
                                authService.saveCurrentUser()
                                showStyleSheet = false
                            }
                        } else {
                            showStyleError = true
                        }
                    },
                    onCancel: {
                        showStyleSheet = false
                        showStyleError = false
                    }
                )
                .environmentObject(authService)
            }
        }
    }
}

struct StylePreferencesSheet: View {
    @Binding var selectedStyles: [OutfitType]
    @Binding var showStyleError: Bool
    var onApply: () -> Void
    var onCancel: () -> Void
    @EnvironmentObject var authService: AuthService
    private let maxStyles = 6
    private let allStyles = OutfitType.allCases
    private let columns = [GridItem(.flexible(minimum: 0, maximum: .infinity)), GridItem(.flexible(minimum: 0, maximum: .infinity))]
    private let cellHeight: CGFloat = 56
    var isChanged: Bool {
        guard let user = authService.user else { return false }
        return Set(selectedStyles) != Set(user.preferredStyles)
    }
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Edit Style Preferences")
                    .font(.title2.bold())
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("Choose exactly 6 preferred styles")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .center)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(0..<10) { idx in
                        let style = allStyles[idx]
                        Button(action: {
                            if selectedStyles.contains(style) {
                                selectedStyles.removeAll { $0 == style }
                            } else if selectedStyles.count < maxStyles {
                                selectedStyles.append(style)
                            } else {
                                showStyleError = true
                            }
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: selectedStyles.contains(style) ? "checkmark.square.fill" : "square")
                                    .foregroundColor(selectedStyles.contains(style) ? .accentColor : .gray)
                                    .font(.title3)
                                Image(systemName: style.icon)
                                    .foregroundColor(.primary)
                                    .font(.title3)
                                Text(style.rawValue)
                                    .foregroundColor(.primary)
                                    .font(.body)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .padding(.leading, 12)
                            .frame(maxWidth: .infinity, minHeight: cellHeight, maxHeight: cellHeight, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(selectedStyles.contains(style) ? Color.accentColor.opacity(0.13) : Color(.systemGray6))
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                if showStyleError {
                    Text("Please select exactly 6 styles.")
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Spacer()
                VStack(spacing: 12) {
                    Button(action: {
                        if selectedStyles.count == maxStyles && isChanged {
                            onApply()
                        } else {
                            showStyleError = true
                        }
                    }) {
                        Text("Save My Style Preferences")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isChanged && selectedStyles.count == maxStyles ? Color.accentColor : Color.gray.opacity(0.4))
                            .cornerRadius(12)
                    }
                    .disabled(!isChanged || selectedStyles.count != maxStyles)
                    Button("Cancel") { onCancel() }
                        .styleMateSecondaryButton()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 16)
            .background(Color(.systemBackground))
        }
    }
}

#Preview {
    ProfileView()
        .environmentObject(AuthService())
        .environmentObject(WardrobeViewModel())
} 