import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @Binding var showAddSheet: Bool
    @Binding var activeAddFlow: AddFlow?
    
    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem {
                        Label("Home", systemImage: "house.fill")
                    }
                    .tag(0)
                
                MyWardrobeView()
                    .tabItem {
                        Label("Wardrobe", systemImage: "tshirt.fill")
                    }
                    .tag(1)
            }
            .tint(.blue)
            
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: { showAddSheet = true }) {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 62, height: 62)
                                .shadow(color: Color.blue.opacity(0.25), radius: 8, x: 0, y: 4)
                            Image(systemName: "plus")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .accessibilityLabel("Add new item")
                    .offset(y: -38)
                    Spacer()
                }
                .frame(height: 0)
            }
        }
    }
}

#Preview {
    MainTabView(showAddSheet: .constant(false), activeAddFlow: .constant(nil))
} 