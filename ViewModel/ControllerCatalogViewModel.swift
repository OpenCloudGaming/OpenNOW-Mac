//
//  ControllerCatalogViewModel.swift
//  MacForceNow
//

import Combine
import Foundation

enum ControllerCatalogFocusArea {
    case navigation
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
    @Published var searchResultColumnCount = 4
    @Published var isDetailVisible = false
    @Published var detailActionIndex = 0
    @Published var showAllSection: CatalogSectionModel?
    @Published var showAllIndex = 0
    @Published var showAllColumnCount = 4

    let navigationItems = ControllerNavigationItem.allCases

    var hasControllerOverlay: Bool {
        isActionMenuVisible || isSearchVisible || isDetailVisible || showAllSection != nil
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

