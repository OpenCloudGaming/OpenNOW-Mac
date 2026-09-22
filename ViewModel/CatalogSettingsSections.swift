//  The settings rail's section captions: which pages of one concern share a header, and the run
//  splitter the sidebar draws them with. Pages carry their section, so the case order stays the
//  only list to keep in step.
//

import Foundation

/// A caption over a run of the destination rail. Pages of one concern share a section only when
/// they are contiguous in the case order, so the rail can derive sections by walking the pages and
/// never needs a second list to keep in step.
enum CatalogSettingsSection: String, CaseIterable {
    case app
    case stream
    case connection

    var title: String {
        switch self {
        case .app: return "App"
        case .stream: return "Stream"
        case .connection: return "Connection"
        }
    }
}

struct CatalogSettingsSidebarSection: Identifiable {
    let section: CatalogSettingsSection?
    private(set) var groups: [CatalogSettingsGroup]

    var id: String { section?.rawValue ?? "unsectioned-\(groups.first?.rawValue ?? "")" }
    var title: String? { section?.title }

    /// Splits a page list into headered runs wherever the section changes. Callers pass the same
    /// filtered list the rail draws, so a future conditional page lands in the right section for
    /// free instead of being handled twice.
    static func sections(of groups: [CatalogSettingsGroup]) -> [CatalogSettingsSidebarSection] {
        var runs: [CatalogSettingsSidebarSection] = []
        for group in groups {
            if let last = runs.last, last.section == group.sidebarSection {
                runs[runs.count - 1].groups.append(group)
            } else {
                runs.append(CatalogSettingsSidebarSection(section: group.sidebarSection, groups: [group]))
            }
        }
        return runs
    }
}
