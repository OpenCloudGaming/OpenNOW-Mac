import Foundation

@objc(OPNGameCatalogDataSupport)
@objcMembers
final class OPNGameCatalogDataSupport: NSObject {
    static func gameCount(in panelObjects: [OPNCatalogPanelObject]) -> Int {
        panelObjects.reduce(0) { panelTotal, panel in
            panelTotal + panel.sections.reduce(0) { sectionTotal, section in
                sectionTotal + section.games.count
            }
        }
    }

    static func browseGameCount(_ result: OPNCatalogBrowseResultObject?) -> Int {
        guard let result else { return 0 }
        return result.totalCount > 0 ? result.totalCount : result.games.count
    }

    static func hasGames(in panelObjects: [OPNCatalogPanelObject]) -> Bool {
        panelObjects.contains { panel in
            panel.sections.contains { !$0.games.isEmpty }
        }
    }

    static func normalizedTitle(_ title: String?) -> String {
        OPNGameCatalogSearchSupport.normalizedString(title ?? "")
    }
}
