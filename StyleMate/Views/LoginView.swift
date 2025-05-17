import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var name: String = ""
    @State private var isSignUp = false
    @State private var appear = false
    @State private var selectedQuote: String = ""
    
    let aiQuotes = [
        "Unlock daily style inspiration, powered by AI magic.",
        "Your next outfit is just an algorithm away.",
        "Style meets intelligence—welcome to your AI wardrobe.",
        "Fashion, reimagined by artificial intelligence.",
        "Let AI curate your closet, one look at a time.",
        "Smarter style starts here—with AI.",
        "AI: Your new personal stylist.",
        "Discover the future of fashion with AI.",
        "Dress smart. Dress AI.",
        "Where technology meets trend.",
        "AI-powered looks for every day.",
        "Let algorithms inspire your attire.",
        "Your wardrobe, upgraded by AI.",
        "From code to couture—AI styles you.",
        "Step into tomorrow's fashion, today.",
        "AI knows what looks good on you.",
        "Personalized fashion, powered by AI.",
        "Let AI help you find your signature style.",
        "The smartest way to dress is here."
    ]
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Magical gradient background
                LinearGradient(
                    colors: [Color.pink.opacity(0.18), Color.blue.opacity(0.18), Color.yellow.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                VStack(spacing: 28) {
                    Spacer(minLength: 24)
                    // Logo and magical intro
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.18))
                                .frame(width: 100, height: 100)
                                .blur(radius: 16)
                            Image(systemName: "tshirt.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 64, height: 64)
                                .foregroundColor(.accentColor)
                                .shadow(color: Color.accentColor.opacity(0.18), radius: 8, x: 0, y: 4)
                            // Subtle sparkles
                            MagicalSparkles()
                        }
                        Text("StyleMate")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                        Text(selectedQuote)
                            .font(.headline)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.accentColor, Color.pink.opacity(0.85), Color.blue.opacity(0.85)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .multilineTextAlignment(.center)
                            .padding(.top, 2)
                    }
                    .padding(.top, 36)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 24)
                    .animation(.easeOut(duration: 1.1), value: appear)
                    
                    Spacer(minLength: 8)
                    // Card for input fields
                    VStack(spacing: 16) {
                        if isSignUp {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Name")
                                    .font(.headline)
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                                TextField("Enter your name here", text: $name)
                                    .textContentType(.name)
                                    .padding()
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(10)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Email")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            TextField("Enter your email here", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Password")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            SecureField("Enter your password here", text: $password)
                                .textContentType(.password)
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                        }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(.systemBackground).opacity(0.96))
                            .shadow(color: Color.accentColor.opacity(0.08), radius: 8, x: 0, y: 4)
                    )
                    .padding(.horizontal, 24)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 24)
                    .animation(.easeOut(duration: 1.2).delay(0.2), value: appear)
                    
                    // Sign In/Up Buttons
                    VStack(spacing: 16) {
                        Button(isSignUp ? "Create Your Style Account" : "Sign in to the Style Portal") {
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
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(height: 50)
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(colors: [Color.accentColor, Color.pink.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: Color.accentColor.opacity(0.13), radius: 8, x: 0, y: 4)
                        .accessibilityLabel(isSignUp ? "Sign up for StyleMate" : "Sign in to StyleMate")
                        Button(isSignUp ? "Already have an account? Sign In" : "Don't have an account? Sign Up") {
                            withAnimation { isSignUp.toggle() }
                        }
                        .font(.footnote)
                        .foregroundColor(.accentColor)
                    }
                    .padding(.horizontal, 24)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 24)
                    .animation(.easeOut(duration: 1.2).delay(0.3), value: appear)
                    
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
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 12)
                    .animation(.easeOut(duration: 1.2).delay(0.4), value: appear)
                }
                .onAppear {
                    appear = true
                    selectedQuote = aiQuotes.shuffled().first ?? aiQuotes[0]
                }
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