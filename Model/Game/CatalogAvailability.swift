import Foundation

/// The vendor's per-variant availability, distinct from ownership. Measured live 2026-09-29:
/// `AVAILABLE`, `SERVER_MAINTENANCE` / `GFN_DEVELOPER_MAINTENANCE`, or `PATCHING` / `PATCHING_AUTO`.
public enum CatalogAvailability: Equatable, Sendable {
    case available
    case maintenance
    case patching
    case unavailable

    /// Only a title the vendor still serves can be launched.
    public var isPlayable: Bool { self == .available }

    /// Down for a vendor-side reason, which earns the offline notice in place of the play button.
    public var isOffline: Bool { self == .maintenance || self == .unavailable }

    public static func classify(catalogStatus: String, stateDetailsSubType: String) -> CatalogAvailability {
        let probe = "\(catalogStatus) \(stateDetailsSubType)".lowercased()
        if probe.contains("maintenance") { return .maintenance }
        if probe.contains("patch") { return .patching }
        if probe.contains("offline") || probe.contains("unavailable") || probe.contains("unsupported") { return .unavailable }
        return .available
    }
}
