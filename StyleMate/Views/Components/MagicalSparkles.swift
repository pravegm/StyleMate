import SwiftUI

struct MagicalSparkles: View {
    @State private var animate = false
    var body: some View {
        ZStack {
            // Top left sparkle
            Text("✨")
                .font(.system(size: 22))
                .foregroundColor(.yellow.opacity(0.85))
                .offset(x: -38, y: -38)
                .opacity(animate ? 1 : 0.3)
                .scaleEffect(animate ? 1.1 : 0.8)
                .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: animate)
            // Top right sparkle
            Text("✨")
                .font(.system(size: 18))
                .foregroundColor(.blue.opacity(0.7))
                .offset(x: 38, y: -44)
                .opacity(animate ? 0.7 : 0.3)
                .scaleEffect(animate ? 1.2 : 0.7)
                .animation(.easeInOut(duration: 2.7).repeatForever(autoreverses: true), value: animate)
            // Center sparkle
            Text("✨")
                .font(.system(size: 16))
                .foregroundColor(.pink.opacity(0.7))
                .offset(x: 0, y: -60)
                .opacity(animate ? 0.8 : 0.3)
                .scaleEffect(animate ? 1.15 : 0.7)
                .animation(.easeInOut(duration: 2.9).repeatForever(autoreverses: true), value: animate)
        }
        .allowsHitTesting(false)
        .onAppear { animate = true }
    }
} 