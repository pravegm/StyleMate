import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @State private var showingSignOutAlert = false
    @State private var showingOptionsMenu = false
    @State private var showEmptyConfirmation = false
    
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
                        Picker("Preferred Style", selection: .constant(user.preferredStyle)) {
                            Text("Casual").tag("Casual")
                            Text("Formal").tag("Formal")
                            Text("Business").tag("Business")
                            Text("Sporty").tag("Sporty")
                            Text("Bohemian").tag("Bohemian")
                        }
                        .disabled(true)
                        
                        Toggle("Enable Notifications", isOn: .constant(user.notificationsEnabled))
                            .disabled(true)
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
        }
    }
}

#Preview {
    ProfileView()
        .environmentObject(AuthService())
        .environmentObject(WardrobeViewModel())
} 