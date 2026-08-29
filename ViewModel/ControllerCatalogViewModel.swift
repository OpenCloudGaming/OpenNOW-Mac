//
//  ControllerCatalogViewModel.swift
//  OpenNOW
//

import Combine
import Foundation

enum ControllerCatalogFocusArea {
    case navigation
    /// The search bar at the top of the catalog. Its own area rather than a rail, because it sits
    /// above the hero and has no game selection of its own.
    case search
    case content
}

enum ControllerNavigationItem: CaseIterable, Equatable, Identifiable {
    case home
    case library
    case favorites
    case search
    case recordings
    case settings
    case actions

    var id: String { title }

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .favorites: return "Favorites"
        case .search: return "Search"
        case .recordings: return "Recordings"
        case .settings: return "Settings"
        case .actions: return "Actions"
        }
    }

    var icon: String {
        switch self {
        case .home: return "gamecontroller.fill"
        case .library: return "rectangle.stack.fill"
        case .favorites: return "heart.fill"
        case .search: return "magnifyingglass"
        case .recordings: return "play.rectangle.fill"
        case .settings: return "gearshape.fill"
        case .actions: return "ellipsis.circle.fill"
        }
    }
}

@MainActor
final class ControllerCatalogViewModel: ObservableObject {
    @Published var focusArea = ControllerCatalogFocusArea.navigation
    @Published var selectedNavigationIndex = 0
    @Published var selectedRailIndex = 0
    @Published var selectedGameIndices: [String: Int] = [:]
    @Published var isActionMenuVisible = false
    @Published var actionMenuIndex = 0
    @Published var isSearchVisible = false
    @Published var searchRowIndex = 0
    @Published var searchFilterOptionIndices: [String: Int] = [:]
    @Published var searchResultIndex = 0
    @Published var isDetailVisible = false
    @Published var detailActionIndex = 0

    // Library and Favorites are no longer standalone destinations — they are reached from the
    // Home rails' Show All (revamped, filterable catalog view), so they are omitted from the nav.
    /// Search is deliberately absent: it is an overlay raised by the dedicated search button (and
    /// hinted as such in the hint bar), not a place you land on. Listing it as a destination meant
    /// the bar had to claim something was "active" while an overlay was up, and paging with LB/RB
    /// stepped onto a screen that immediately covered the bar it came from.
    let navigationItems: [ControllerNavigationItem] = [.home, .recordings, .settings, .actions]

    var hasControllerOverlay: Bool {
        isActionMenuVisible || isSearchVisible || isDetailVisible
    }

    func selectedGameIndex(for section: CatalogSectionModel, gameCount: Int) -> Int {
        guard gameCount > 0 else { return 0 }
        return min(max(selectedGameIndices[section.id] ?? 0, 0), gameCount - 1)
    }

    func setSelectedGameIndex(_ index: Int, for section: CatalogSectionModel, gameCount: Int) {
        guard gameCount > 0 else {
            selectedGameIndices[section.id] = 0
            return
        }
        selectedGameIndices[section.id] = min(max(index, 0), gameCount - 1)
    }

    func clampRailSelection(sectionCount: Int) {
        selectedRailIndex = min(max(selectedRailIndex, 0), max(sectionCount - 1, 0))
    }
}

