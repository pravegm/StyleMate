import SwiftUI

struct SummaryView: View {
    let savedItems: [WardrobeItem]
    var onDone: () -> Void
    @State private var animate = false
    let emojis = ["🎉", "✨", "🥳", "🎊", "💫"]
    let burstCount = 18

    var body: some View {
        ZStack {
            // Colorful celebratory background
            LinearGradient(
                colors: [Color.pink.opacity(0.2), Color.blue.opacity(0.2), Color.yellow.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                // Big celebratory emoji/icon
                Text("🎉")
                    .font(.system(size: 80))
                    .scaleEffect(1.2)
                    .shadow(radius: 10)

                // Congratulatory text
                Text("Added to your wardrobe!")
                    .font(.largeTitle.bold())
                    .foregroundColor(.accentColor)
                    .multilineTextAlignment(.center)
                    .transition(.scale)

                // Summary of items
                ForEach(summaryStrings, id: \.self) { str in
                    Text(str)
                        .font(.title2)
                        .foregroundColor(.primary)
                        .padding(.vertical, 2)
                }

                Spacer()

                // Done button
                Button("Done") { onDone() }
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                    .shadow(radius: 4)
            }
            .padding()
            .onAppear { animate = true }

            // Native SwiftUI emoji burst
            ZStack {
                ForEach(0..<burstCount, id: \.self) { i in
                    let angle = Double(i) / Double(burstCount) * 2 * Double.pi
                    let radius: CGFloat = animate ? CGFloat.random(in: 120...220) : 0
                    let x = cos(angle) * radius
                    let y = sin(angle) * radius
                    Text(emojis.randomElement()!)
                        .font(.system(size: 36))
                        .opacity(animate ? 0 : 1)
                        .offset(x: x, y: y)
                        .scaleEffect(animate ? 1.6 : 0.7)
                        .animation(
                            .easeOut(duration: 1.2).delay(Double(i) * 0.03),
                            value: animate
                        )
                }
            }
            .allowsHitTesting(false)
        }
    }

    var summaryStrings: [String] {
        let grouped = Dictionary(grouping: savedItems, by: { $0.product })
        return grouped.map { (product, items) in
            let plural = (items.count > 1 && !product.lowercased().hasSuffix("s")) ? "s" : ""
            return "\(items.count) \(product)\(plural)"
        }.sorted()
    }
} 