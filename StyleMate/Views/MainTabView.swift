import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @Binding var showAddSheet: Bool

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Image(systemName: selectedTab == 0 ? "house.fill" : "house")
                    Text("Home")
                }
                .tag(0)

            MyWardrobeView(showAddSheet: $showAddSheet)
                .tabItem {
                    Image(systemName: selectedTab == 1 ? "tshirt.fill" : "tshirt")
                    Text("Wardrobe")
                }
                .tag(1)

            MyOutfitsView()
                .tabItem {
                    Image(systemName: "calendar")
                    Text("Outfits")
                }
                .tag(2)

            ProfileView()
                .tabItem {
                    Image(systemName: selectedTab == 3 ? "person.circle.fill" : "person.circle")
                    Text("Profile")
                }
                .tag(3)
        }
        .tint(DS.Colors.accent)
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
    }
}

#Preview {
    MainTabView(showAddSheet: .constant(false))
        .environmentObject(WardrobeViewModel())
        .environmentObject(AuthService())
        .environmentObject(MyOutfitsViewModel())
        .environmentObject(OnboardingManager())
}
