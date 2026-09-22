//  The glyph a user collection draws. Two shapes share one stored value: a built-in SF Symbol, or a
//  reader-supplied image whose bytes live in `OPNCollectionIconStore` and travel to iCloud through
//  the mirrored icon directory. A collection therefore stores only the asset id, never the image.

import Foundation

/// One collection's chosen icon. A value rather than a reference: the symbol name or the image asset
/// id is all a collection keeps, so the stored payload stays small and the collection — not a file —
/// is the source of truth for what it draws.
public struct OPNCollectionIcon: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case symbol
        case image
    }

    /// The catalog's own glyph, drawn wherever a collection has not chosen one.
    public static let defaultSymbolName = "square.stack.3d.up.fill"
    public static let maximumSymbolNameLength = 128
    public static let maximumAssetIdentifierLength = 128

    public let kind: Kind
    public let value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    public static func symbol(_ name: String) -> OPNCollectionIcon {
        OPNCollectionIcon(kind: .symbol, value: name)
    }

    public static func image(assetIdentifier: String) -> OPNCollectionIcon {
        OPNCollectionIcon(kind: .image, value: assetIdentifier)
    }

    /// The glyph a collection without an icon of its own draws.
    public static let fallback = OPNCollectionIcon.symbol(defaultSymbolName)

    /// A storable copy, or nil when the value cannot be kept. A symbol name must be a non-empty,
    /// bounded identifier; an image asset id must look like the lowercase UUID the store writes, so
    /// a hand-edited payload cannot point at an arbitrary path.
    public var validated: OPNCollectionIcon? {
        switch kind {
        case .symbol:
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= Self.maximumSymbolNameLength else { return nil }
            return .symbol(name)
        case .image:
            let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isAssetIdentifier(identifier) else { return nil }
            return .image(assetIdentifier: identifier)
        }
    }

    static func isAssetIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maximumAssetIdentifierLength else { return false }
        return value.allSatisfy { ($0.isHexDigit && $0.isASCII) || $0 == "-" }
    }
}
