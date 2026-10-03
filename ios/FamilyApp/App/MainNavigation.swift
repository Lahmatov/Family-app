import SwiftUI

/// The top-level areas of the app.
enum AppSection: String, CaseIterable, Identifiable {
    case budget, listings, children, goals, family

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .budget: "tab.budget"
        case .listings: "tab.listings"
        case .children: "tab.children"
        case .goals: "tab.goals"
        case .family: "tab.family"
        }
    }

    var icon: String {
        switch self {
        case .budget: "eurosign.circle"
        case .listings: "building.2"
        case .children: "figure.and.child.holdinghands"
        case .goals: "target"
        case .family: "person.3"
        }
    }

    @ViewBuilder var content: some View {
        switch self {
        case .budget: BudgetHomeView()
        case .listings: ListingsHomeView()
        case .children: ChildrenHomeView()
        case .goals: GoalsHomeView()
        case .family: FamilyView()
        }
    }
}

/// Tab bar on narrow screens (iPhone), sidebar with a detail column on wide ones
/// (iPad, iPhone Max in landscape, Split View). The selected area survives a size change.
struct MainNavigation: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var section = AppSection.budget

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                List(AppSection.allCases, selection: Binding(get: { section }, set: { section = $0 ?? section })) { item in
                    Label(item.title, systemImage: item.icon)
                        .tag(item)
                        // One element for the whole row (VoiceOver reads it once; UI tests tap the row, not the icon).
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("section-\(item.rawValue)")
                }
                .navigationTitle("app.name")
            } detail: {
                section.content.id(section)
            }
        } else {
            TabView(selection: $section) {
                ForEach(AppSection.allCases) { item in
                    item.content
                        .tabItem { Label(item.title, systemImage: item.icon) }
                        .tag(item)
                }
            }
        }
    }
}
