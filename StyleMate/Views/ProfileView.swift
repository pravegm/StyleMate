import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var showingSignOutAlert = false
    
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
        }
    }
}

#Preview {
    ProfileView()
        .environmentObject(AuthService())
} 