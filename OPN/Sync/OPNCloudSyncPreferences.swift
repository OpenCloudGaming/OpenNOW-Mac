import Foundation

/// What the reader can choose to carry through iCloud. Each category is independent: a reader may
/// back up screenshots without their stream settings, or the reverse.
public enum OPNCloudSyncCategory: String, CaseIterable, Identifiable, Sendable {
    case settings
    case catalog
    case screenshots

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .settings: return "Settings"
        case .catalog: return "Catalog"
        case .screenshots: return "Screenshots"
        }
    }

    public var subtitle: String {
        switch self {
        case .settings:
            return "Stream, interface, input, and app preferences. Secrets such as passwords and tokens are never included."
        case .catalog:
            return "Your collections and the order of the home page rails. Favorites and play history live on NVIDIA's service and are not copied."
        case .screenshots:
            return "Every screenshot and album from your library. Images are large, so they count against your iCloud storage."
        }
    }

    public var systemImage: String {
        switch self {
        case .settings: return "slider.horizontal.3"
        case .catalog: return "square.grid.2x2.fill"
        case .screenshots: return "photo.on.rectangle.angled"
        }
    }

    var storageKey: String { "OpenNOW.CloudSync.Category.\(rawValue)" }
}

/// The iCloud sync toggles. The master switch ships off, so nothing reaches iCloud until the reader
/// enables it. Category switches default on: enabling the feature starts with everything selected.
public enum OPNCloudSyncPreferences {
    public static let enabledKey = "OpenNOW.CloudSync.Enabled"

    /// The defaults key for one category, so a view can bind to it with `@AppStorage`.
    public static func categoryKey(_ category: OPNCloudSyncCategory) -> String {
        category.storageKey
    }

    public static var isEnabled: Bool {
        get { OPNAppPreferenceStorage.standard.bool(forKey: enabledKey) }
        set { OPNAppPreferenceStorage.standard.set(newValue, forKey: enabledKey) }
    }

    public static func isCategoryEnabled(_ category: OPNCloudSyncCategory) -> Bool {
        guard let stored = OPNAppPreferenceStorage.standard.object(forKey: category.storageKey) as? Bool else {
            return true
        }
        return stored
    }

    public static func setCategory(_ category: OPNCloudSyncCategory, isEnabled: Bool) {
        OPNAppPreferenceStorage.standard.set(isEnabled, forKey: category.storageKey)
    }

    public static var enabledCategories: Set<OPNCloudSyncCategory> {
        Set(OPNCloudSyncCategory.allCases.filter(isCategoryEnabled))
    }
}
