import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var name: String = ""
    @State private var isSignUp = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // App Logo and Title
                VStack(spacing: 16) {
                    Image(systemName: "tshirt.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                    
                    Text("StyleMate")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Your AI Fashion Stylist")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 60)
                
                Spacer()
                
                // User Info Fields
                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(8)
                    if isSignUp {
                        TextField("Name", text: $name)
                            .textContentType(.name)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 20)
                
                // Sign In/Up Buttons
                VStack(spacing: 16) {
                    Button(isSignUp ? "Sign Up" : "Sign In") {
                        Task {
                            if isSignUp {
                                let result = await authService.signUpWithEmail(email: email, password: password, name: name)
                                if let error = result {
                                    errorMessage = error
                                    showError = true
                                }
                            } else {
                                let result = await authService.signInWithEmail(email: email, password: password)
                                if let error = result {
                                    errorMessage = error
                                    showError = true
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    
                    Button(isSignUp ? "Already have an account? Sign In" : "Don't have an account? Sign Up") {
                        isSignUp.toggle()
                    }
                    .font(.footnote)
                }
                .padding(.horizontal, 20)
                
                Spacer()
                
                // Terms and Privacy
                VStack(spacing: 8) {
                    Text("By continuing, you agree to our")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 4) {
                        Link("Terms of Service", destination: URL(string: "https://your-terms-url.com")!)
                        Text("and")
                        Link("Privacy Policy", destination: URL(string: "https://your-privacy-url.com")!)
                    }
                    .font(.footnote)
                }
                .padding(.bottom, 20)
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }
}

#Preview {
    LoginView()
} 