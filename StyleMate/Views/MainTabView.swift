import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @Binding var showAddSheet: Bool
    @Binding var activeAddFlow: AddFlow?
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case 0:
                    HomeView()
                case 1:
                    MyWardrobeView()
                case 2:
                    MyOutfitsView()
                case 3:
                    ProfileView()
                default:
                    HomeView()
                }
            }
            CustomTabBar(selectedTab: $selectedTab, showAddSheet: $showAddSheet)
        }
    }
}

struct CustomTabBar: View {
    @Binding var selectedTab: Int
    @Binding var showAddSheet: Bool
    let tabIcons = ["house.fill", "hanger", "plus", "tshirt.fill", "person.crop.circle"]
    let tabTitles = ["Home", "My Wardrobe", "", "My Outfits", "Profile"]
    var body: some View {
        HStack {
            ForEach(0..<5) { idx in
                Spacer()
                if idx == 2 {
                    Button(action: { showAddSheet = true }) {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 62, height: 62)
                                .shadow(color: Color.blue.opacity(0.25), radius: 8, x: 0, y: 4)
                            Image(systemName: tabIcons[idx])
                                .font(.system(size: 30, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .offset(y: -18)
                    .accessibilityLabel("Add new item")
                } else {
                    Button(action: { selectedTab = idx < 2 ? idx : idx - 1 }) {
                        VStack(spacing: 4) {
                            Image(systemName: tabIcons[idx])
                                .font(.system(size: 24, weight: .regular))
                                .foregroundColor(selectedTab == (idx < 2 ? idx : idx - 1) ? .accentColor : .gray)
                            if !tabTitles[idx].isEmpty {
                                Text(tabTitles[idx])
                                    .font(.caption)
                                    .foregroundColor(selectedTab == (idx < 2 ? idx : idx - 1) ? .accentColor : .gray)
                            }
                        }
                    }
                }
                Spacer()
            }
        }
        .padding(.bottom, 8)
        .background(
            Color(.systemBackground)
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: -2)
        )
    }
}

#Preview {
    MainTabView(showAddSheet: .constant(false), activeAddFlow: .constant(nil))
} 