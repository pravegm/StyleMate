import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @Binding var showAddSheet: Bool
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var tutorialManager: TutorialManager

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
        .sensoryFeedback(.selection, trigger: selectedTab)
        // Host the coach-mark tour over the whole tab UI. It reads the Home
        // elements' frames (anchors) from the selected tab's content.
        .overlayPreferenceValue(CoachAnchorKey.self) { anchors in
            GeometryReader { geo in
                if tutorialManager.activeTour == .home {
                    CoachMarkOverlay(tutorial: tutorialManager, tour: .home, anchors: anchors, proxy: geo)
                }
            }
            .ignoresSafeArea()   // full-screen geo: anchors + scrim share one coordinate space
        }
        // The Home tour navigates between tabs; follow the current step's tab, and
        // return to Home when it ends.
        .onChange(of: tutorialManager.activeTour) { tour in
            if tour == .home { selectedTab = tutorialManager.current?.tab ?? 0 }
            else if tour == nil { selectedTab = 0 }
        }
        .onChange(of: tutorialManager.stepIndex) { _ in
            if tutorialManager.activeTour == .home {
                selectedTab = tutorialManager.current?.tab ?? 0
            }
        }
        .onAppear {
            Haptics.prepare()
            if let uid = authService.user?.id {
                tutorialManager.configure(forUser: uid)
                // Brief beat so the tour doesn't start mid-entrance-animation; the
                // spotlight targets are already measured on first render.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    tutorialManager.startIfFirstTime(.home)
                }
            }
        }
    }
}

#Preview {
    MainTabView(showAddSheet: .constant(false))
        .environmentObject(WardrobeViewModel())
        .environmentObject(AuthService())
        .environmentObject(MyOutfitsViewModel())
        .environmentObject(OnboardingManager())
        .environmentObject(TutorialManager())
}
