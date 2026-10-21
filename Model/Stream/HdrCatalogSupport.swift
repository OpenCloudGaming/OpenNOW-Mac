//  What the catalog says about HDR for the store edition a launch picks, and the one reason a
//  session can end up in SDR although HDR was asked for.

import Foundation

/// The catalog's per-variant HDR answer. `unknown` is "the catalog sent no feature list at all",
/// which is never evidence that an edition cannot stream HDR: only a list that was present and
/// silent about HDR says that.
public enum HdrCatalogSupport: String, Codable, Equatable, Sendable {
    case supported
    case unsupported
    case unknown
}

/// Why a session streams SDR although HDR was asked for. The saved preference is never the reason
/// and is never rewritten by it: the next launch on an edition that has HDR asks for it again.
public enum HdrDowngrade: String, Codable, Equatable, Sendable {
    /// The catalog lists the store edition being launched without HDR.
    case gameUnsupported = "game-unsupported"
}
