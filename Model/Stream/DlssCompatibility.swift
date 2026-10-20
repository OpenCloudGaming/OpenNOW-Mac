//  Per-game DLSS compatibility from NVIDIA's published RTX games list. The list only decorates what
//  the app shows: a missing or invalid document leaves every title unknown and never fails a load.

import Foundation

/// NVIDIA's list cell for one feature.
public enum DlssSupport: String, Codable, Equatable, Sendable {
    /// The feature is built into the game.
    case native
    /// NVIDIA lists an override for the feature.
    case override

    public var label: String {
        switch self {
        case .native: "Built into game"
        case .override: "Available via override"
        }
    }

    public var helpText: String {
        switch self {
        case .native: "NVIDIA lists this feature as built into the game."
        case .override: "NVIDIA lists an override for this feature. Requires a supported cloud rig and eligible membership."
        }
    }

    static func fromCell(_ cell: String) -> DlssSupport? {
        if cell.caseInsensitiveCompare("yes") == .orderedSame { return .native }
        guard cell.hasPrefix("NV") else { return nil }
        return .override
    }
}

/// Multi Frame Generation, whose cell lists a maximum multiplier rather than a yes/no.
public struct DlssMultiFrameGeneration: Codable, Equatable, Sendable {
    public let maxMultiplier: Int

    public init(maxMultiplier: Int) {
        self.maxMultiplier = maxMultiplier
    }

    static func fromCell(_ cell: String) -> DlssMultiFrameGeneration? {
        for component in cell.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            guard let suffix = component.last, suffix == "X" || suffix == "x" else { continue }
            guard let multiplier = Int(component.dropLast()), (2...16).contains(multiplier) else { continue }
            return DlssMultiFrameGeneration(maxMultiplier: multiplier)
        }
        return nil
    }
}

/// One game's row from NVIDIA's list, per feature. A nil feature means the list does not report
/// support for it, which is not the same as "unsupported".
public struct DlssGameSupport: Codable, Equatable, Sendable {
    public let superResolution: DlssSupport?
    public let frameGeneration: DlssSupport?
    public let multiFrameGeneration: DlssMultiFrameGeneration?
    public let rayReconstruction: DlssSupport?
    public let dlaa: DlssSupport?

    public init(
        superResolution: DlssSupport? = nil,
        frameGeneration: DlssSupport? = nil,
        multiFrameGeneration: DlssMultiFrameGeneration? = nil,
        rayReconstruction: DlssSupport? = nil,
        dlaa: DlssSupport? = nil
    ) {
        self.superResolution = superResolution
        self.frameGeneration = frameGeneration
        self.multiFrameGeneration = multiFrameGeneration
        self.rayReconstruction = rayReconstruction
        self.dlaa = dlaa
    }

    /// Whether the row lists any DLSS technology at all. A row that only lists ray tracing is not
    /// DLSS information.
    public var hasAnySupport: Bool {
        superResolution != nil || frameGeneration != nil || multiFrameGeneration != nil || rayReconstruction != nil || dlaa != nil
    }

    public var featureRows: [(feature: DlssCompatibilityFeature, support: DlssSupport?)] {
        DlssCompatibilityFeature.allCases.map { (feature: $0, support: reportedSupport(for: $0)) }
    }

    public func reportedSupport(for feature: DlssCompatibilityFeature) -> DlssSupport? {
        switch feature {
        case .superResolution: superResolution
        case .frameGeneration: frameGeneration
        case .rayReconstruction: rayReconstruction
        case .dlaa: dlaa
        }
    }
}

/// The features the Game Details table reports on. Multi Frame Generation is absent: its multiplier
/// is a separate, account-limited number and is presented with Frame Generation instead.
public enum DlssCompatibilityFeature: String, CaseIterable, Sendable, Identifiable {
    case superResolution
    case frameGeneration
    case rayReconstruction
    case dlaa

    /// The features an override can be requested for, in the order the access block lists them.
    /// DLAA is a Super Resolution mode rather than a separate entitlement.
    public static let overridableFeatures: [DlssCompatibilityFeature] = [
        .superResolution, .frameGeneration, .rayReconstruction,
    ]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .superResolution: "Super Resolution"
        case .frameGeneration: "Frame Generation"
        case .rayReconstruction: "Ray Reconstruction"
        case .dlaa: "DLAA"
        }
    }
}

/// The outcome of looking a title up. "Listed without support" is kept apart from "unknown" so a
/// diagnostic can tell them apart; both read as unknown compatibility in the UI.
public enum DlssMatchOutcome: Equatable, Sendable {
    case matched(DlssGameSupport)
    case listedWithoutSupport
    case unknown

    public var gameSupport: DlssGameSupport? {
        guard case let .matched(support) = self else { return nil }
        return support
    }

    public var isMatched: Bool { gameSupport != nil }
}

/// One parsed row: the title NVIDIA lists and what it says about DLSS.
public struct DlssGamesRow: Codable, Equatable, Sendable {
    public let title: String
    public let gameSupport: DlssGameSupport?

    public init(title: String, gameSupport: DlssGameSupport?) {
        self.title = title
        self.gameSupport = gameSupport
    }
}

/// The bounds the list is held to. A document past either is rejected as a whole rather than
/// partially trusted.
public enum DlssCompatibilityLimits {
    public static let listURLString = "https://www.nvidia.com/content/dam/en-zz/Solutions/geforce/news/nvidia-rtx-games-engines-apps/dlss-rt-games-apps-overrides.json"
    public static let maximumListBytes = 4 * 1024 * 1024
    public static let maximumRows = 5_000
    public static let maximumNameBytes = 512
    public static let maximumCellBytes = 64
    public static let fetchTimeout: TimeInterval = 15
    public static let cacheLifetime: TimeInterval = 24 * 60 * 60
    public static let retryInterval: TimeInterval = 60
    public static let firstLookupWait: TimeInterval = 1.5
    /// How long the UI waits before it stops showing a loading state.
    public static let presentationWait: TimeInterval = 1.5
    public static let sourceLabel = "NVIDIA's DLSS games list"

    /// Column order of a row in NVIDIA's table.
    static let listColumns = [
        "dlss super resolution",
        "dlss frame generation",
        "dlss multi frame generation",
        "dlss ray reconstruction",
        "dlaa",
    ]
}

/// Trailing title words that name an edition of the same game. "Remastered" is deliberately absent:
/// remasters are listed separately and differ in support.
private let dlssEditionSuffixes: [[String]] = [
    ["game", "of", "year"],
    ["goty"],
    ["definitive"],
    ["enhanced"],
    ["complete"],
    ["deluxe"],
    ["standard"],
    ["ultimate"],
    ["directors", "cut"],
    ["director", "s", "cut"],
    ["anniversary"],
]

/// Title normalization and the exact/loose index the matcher looks through.
public enum DlssTitleMatcher {
    private static let strippedScalars: Set<Unicode.Scalar> = [
        "\u{2122}", "\u{00AE}", "\u{00A9}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}",
    ]

    /// Lowercase ASCII words: trademark and zero-width characters removed, accents folded, "&"
    /// spelled "and", and every other non-alphanumeric run collapsed to one space.
    public static func normalizedTitle(_ title: String) -> String {
        let withoutMarks = String(String.UnicodeScalarView(title.unicodeScalars.filter { !strippedScalars.contains($0) }))
        let folded = withoutMarks.folding(
            options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let asciiOnly = String(String.UnicodeScalarView(folded.unicodeScalars.filter { $0.isASCII }))
        return asciiOnly
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    /// A normalized title without "the"/"tm" and without trailing edition words.
    public static func looseTitle(_ normalizedTitle: String) -> String {
        var words = normalizedTitle.split(separator: " ").map(String.init).filter { $0 != "the" && $0 != "tm" }
        while true {
            let countBeforeTrimming = words.count
            if words.count > 1, let last = words.last, last == "edition" || last == "pc" {
                words.removeLast()
            }
            if let suffix = dlssEditionSuffixes.first(where: { words.count > $0.count && words.suffix($0.count) == $0 }) {
                words.removeLast(suffix.count)
            }
            guard words.count != countBeforeTrimming else { return words.joined(separator: " ") }
        }
    }
}

/// Every parsed row indexed for lookup. Rows without DLSS are indexed too, so an exact title with no
/// DLSS never falls through to a loosely matching edition that has it.
public struct DlssGamesIndex: Sendable {
    private let exactSupportByTitle: [String: DlssGameSupport?]
    private let looseSupportByTitle: [String: DlssGameSupport?]

    public init(rows: [DlssGamesRow]) {
        var exactSupportByTitle: [String: DlssGameSupport?] = [:]
        var looseSupportByTitle: [String: DlssGameSupport?] = [:]
        for row in rows {
            let normalizedTitle = DlssTitleMatcher.normalizedTitle(row.title)
            guard !normalizedTitle.isEmpty else { continue }
            let support = row.gameSupport?.hasAnySupport == true ? row.gameSupport : nil
            looseSupportByTitle.updateValue(support, forKey: DlssTitleMatcher.looseTitle(normalizedTitle))
            exactSupportByTitle.updateValue(support, forKey: normalizedTitle)
        }
        self.exactSupportByTitle = exactSupportByTitle
        self.looseSupportByTitle = looseSupportByTitle
    }

    public func lookup(_ title: String) -> DlssMatchOutcome {
        let normalizedTitle = DlssTitleMatcher.normalizedTitle(title)
        guard !normalizedTitle.isEmpty else { return .unknown }
        if let storedSupport = exactSupportByTitle[normalizedTitle] { return Self.matchOutcome(for: storedSupport) }
        guard let storedSupport = looseSupportByTitle[DlssTitleMatcher.looseTitle(normalizedTitle)] else { return .unknown }
        return Self.matchOutcome(for: storedSupport)
    }

    private static func matchOutcome(for support: DlssGameSupport?) -> DlssMatchOutcome {
        guard let support else { return .listedWithoutSupport }
        return .matched(support)
    }
}

public enum DlssGamesListError: Error, Equatable, Sendable {
    case tooLarge
    case malformed(String)
}

/// Parses NVIDIA's list into bounded rows. Apps and malformed rows are skipped; an oversized or
/// structurally invalid document is rejected as a whole.
public enum DlssGamesListParser {
    public static func parse(_ data: Data) throws -> [DlssGamesRow] {
        guard data.count <= DlssCompatibilityLimits.maximumListBytes else { throw DlssGamesListError.tooLarge }
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DlssGamesListError.malformed("not valid JSON")
        }
        guard let rows = document["data"] as? [Any] else {
            throw DlssGamesListError.malformed("no data array")
        }
        guard rows.count <= DlssCompatibilityLimits.maximumRows else {
            throw DlssGamesListError.malformed("more than 5,000 rows")
        }
        return rows.compactMap(row(from:))
    }

    static func gameSupport(from cells: [String]) -> DlssGameSupport? {
        guard cells.count == DlssCompatibilityLimits.listColumns.count else { return nil }
        let support = DlssGameSupport(
            superResolution: DlssSupport.fromCell(cells[0]),
            frameGeneration: DlssSupport.fromCell(cells[1]),
            multiFrameGeneration: DlssMultiFrameGeneration.fromCell(cells[2]),
            rayReconstruction: DlssSupport.fromCell(cells[3]),
            dlaa: DlssSupport.fromCell(cells[4])
        )
        guard support.hasAnySupport else { return nil }
        return support
    }

    private static func row(from rawRow: Any) -> DlssGamesRow? {
        guard let rawRow = rawRow as? [String: Any], rawRow["type"] as? String == "Game" else { return nil }
        guard let title = title(from: rawRow["name"]) else { return nil }
        let cells = DlssCompatibilityLimits.listColumns.map { cell(from: rawRow[$0]) }
        return DlssGamesRow(title: title, gameSupport: gameSupport(from: cells))
    }

    private static func title(from rawName: Any?) -> String? {
        guard let rawName else { return nil }
        let title = titleText(from: rawName)
        guard !title.isEmpty, title.utf8.count <= DlssCompatibilityLimits.maximumNameBytes else { return nil }
        return title
    }

    /// NVIDIA's list carries a few numeric names, so a number is a title rather than a malformed row.
    private static func titleText(from rawName: Any) -> String {
        if let name = rawName as? String { return name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let name = rawName as? NSNumber { return name.stringValue }
        return ""
    }

    private static func cell(from rawCell: Any?) -> String {
        guard let rawCell = rawCell as? String else { return "" }
        let trimmed = rawCell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= DlssCompatibilityLimits.maximumCellBytes else { return "" }
        return trimmed
    }
}
