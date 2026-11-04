import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @Binding var showAddSheet: Bool
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var tutorialManager: TutorialManager

    var body: some View {
        // Tab API + sidebarAdaptable: a glass tab bar on iPhone and the Duo's
        // cover display, a sidebar on the wide inner display.
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: 0) {
                HomeView()
            }
            Tab("Wardrobe", systemImage: "tshirt", value: 1) {
                MyWardrobeView(showAddSheet: $showAddSheet)
            }
            Tab("Outfits", systemImage: "calendar", value: 2) {
                MyOutfitsView()
            }
            Tab("Profile", systemImage: "person.circle", value: 3) {
                ProfileView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(DS.Colors.accent)
        .sensoryFeedback(.selection, trigger: selectedTab)
        // The outfit sheet's "View in Calendar" jumps to the Outfits tab.
        .onReceive(NotificationCenter.default.publisher(for: .showOutfitsCalendar)) { _ in
            selectedTab = 2
        }
        // The outfit sheet's "add shoes" tip opens the add-clothes sheet.
        .onReceive(NotificationCenter.default.publisher(for: .showAddClothes)) { _ in
            selectedTab = 1
            showAddSheet = true
        }
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
