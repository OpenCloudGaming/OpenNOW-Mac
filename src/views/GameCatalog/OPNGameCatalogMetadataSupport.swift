import Foundation

@objc(OPNGameCatalogMetadataSupport)
@objcMembers
final class OPNGameCatalogMetadataSupport: NSObject {
    static func stringEqualsCaseInsensitive(_ lhs: String, rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    static func displayString(_ value: String, fallback: String) -> String {
        let display = OPNGameCatalogArtworkSupport.displayLabel(value)
        return display.isEmpty ? fallback : display
    }

    static func serviceStatusOwnedForLaunch(_ status: String) -> Bool {
        status == "MANUAL" || status == "PLATFORM_SYNC" || status == "IN_LIBRARY"
    }

    static func variantIsLibrarySelected(librarySelected: Bool, inLibrary: Bool, serviceStatus: String) -> Bool {
        librarySelected || inLibrary || serviceStatusOwnedForLaunch(serviceStatus)
    }

    static func variantIsOwned(inLibrary: Bool, librarySelected: Bool, serviceStatus: String) -> Bool {
        inLibrary || librarySelected || serviceStatusOwnedForLaunch(serviceStatus)
    }

    static func primaryActionTitle(needsPurchase: Bool, prominent: Bool) -> String {
        if needsPurchase { return prominent ? "Add to Library" : "ADD" }
        return prominent ? "Play Now" : "PLAY"
    }

    static func availabilityTitle(needsPurchase: Bool, profileEnabled: Bool, storeCount: Int) -> String {
        if needsPurchase { return "Not owned" }
        if profileEnabled { return "Profile active" }
        return storeCount > 1 ? "\(storeCount) stores" : "Cloud ready"
    }
}
