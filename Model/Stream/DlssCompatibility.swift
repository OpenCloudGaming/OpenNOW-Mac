//  Per-game DLSS compatibility from NVIDIA's published RTX games list.
//
//  The GeForce NOW catalog carries no per-game DLSS key, so a title is matched against NVIDIA's own
//  table. The list only decorates what the app shows: when it is missing, oversized or invalid every
//  game reads as unknown and the next demand retries. Nothing here fails a catalog load or a launch.
//
//  Matching is heuristic, so it is deliberately conservative. An exact title always wins, including
//  when its row lists no DLSS at all — that must not fall through to a loosely matching edition that
//  does. Only then is a bounded edition-suffix fallback tried, and "Remastered" is never stripped
//  because a remaster is a different release with different support.

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
        if cell.hasPrefix("NV") { return .override }
        return nil
    }
}

/// Multi Frame Generation, whose cell lists a maximum multiplier rather than a yes/no.
public struct DlssMultiFrameGeneration: Codable, Equatable, Sendable {
    public let maxMultiplier: Int

    public init(maxMultiplier: Int) {
        self.maxMultiplier = maxMultiplier
    }

    static func fromCell(_ cell: String) -> DlssMultiFrameGeneration? {
        let tokens = cell.split { !$0.isLetter && !$0.isNumber }
        for token in tokens {
            guard let last = token.last, last == "X" || last == "x", let value = Int(token.dropLast()) else { continue }
            guard (2...16).contains(value) else { continue }
            return DlssMultiFrameGeneration(maxMultiplier: value)
        }
        return nil
    }
}

/// One game's row from NVIDIA's list, per feature. A `nil` feature means the list does not report
/// support for it, which is not the same as "unsupported".
public struct DlssGameSupport: Codable, Equatable, Sendable {
    public var superResolution: DlssSupport?
    public var frameGeneration: DlssSupport?
    public var multiFrameGeneration: DlssMultiFrameGeneration?
    public var rayReconstruction: DlssSupport?
    public var dlaa: DlssSupport?

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

    /// The features the compatibility section draws, in the order NVIDIA's table lists them.
    public var featureRows: [(feature: DlssCompatibilityFeature, support: DlssSupport?)] {
        DlssCompatibilityFeature.allCases.map { (feature: $0, support: support(for: $0)) }
    }

    public func support(for feature: DlssCompatibilityFeature) -> DlssSupport? {
        switch feature {
        case .superResolution: superResolution
        case .frameGeneration: frameGeneration
        case .rayReconstruction: rayReconstruction
        case .dlaa: dlaa
        }
    }
}

/// The features the Game Details compatibility table reports on. Multi Frame Generation is
/// deliberately absent: its multiplier is a separate, account-limited number rather than a
/// native/override cell, and it is presented with Frame Generation instead.
public enum DlssCompatibilityFeature: String, CaseIterable, Sendable, Identifiable {
    case superResolution
    case frameGeneration
    case rayReconstruction
    case dlaa

    public var id: String { rawValue }

    /// The features an override can actually be requested for, in the order the access block lists
    /// them. DLAA is a Super Resolution mode rather than a separate entitlement, so it is absent.
    public static let overridableFeatures: [DlssCompatibilityFeature] = [
        .superResolution, .frameGeneration, .rayReconstruction,
    ]

    public var title: String {
        switch self {
        case .superResolution: "Super Resolution"
        case .frameGeneration: "Frame Generation"
        case .rayReconstruction: "Ray Reconstruction"
        case .dlaa: "DLAA"
        }
    }
}

/// The outcome of looking a title up in the list. "Listed without support" is kept apart from
/// "unknown" so a diagnostic can tell an unlisted title from a row that lists no DLSS; both read as
/// unknown compatibility in the UI.
public enum DlssMatchOutcome: Equatable, Sendable {
    case matched(DlssGameSupport)
    case listedWithoutSupport
    case unknown

    public var support: DlssGameSupport? {
        guard case let .matched(support) = self else { return nil }
        return support
    }

    public var isMatched: Bool {
        if case .matched = self { return true }
        return false
    }
}

/// One parsed row: the title NVIDIA lists and what it says about DLSS.
public struct DlssGamesRow: Codable, Equatable, Sendable {
    public let title: String
    public let support: DlssGameSupport?

    public init(title: String, support: DlssGameSupport?) {
        self.title = title
        self.support = support
    }
}

/// The bounds the list is held to. A document past either is rejected as a whole rather than
/// partially trusted.
public enum DlssCompatibilityLimits {
    public static let listURL = URL(string: "https://www.nvidia.com/content/dam/en-zz/Solutions/geforce/news/nvidia-rtx-games-engines-apps/dlss-rt-games-apps-overrides.json")!
    public static let maximumListBytes = 4 * 1024 * 1024
    public static let maximumRows = 5_000
    public static let maximumNameBytes = 512
    public static let maximumCellBytes = 64
    public static let fetchTimeout: TimeInterval = 15
    public static let cacheLifetime: TimeInterval = 24 * 60 * 60
    public static let retryInterval: TimeInterval = 60
    public static let firstLookupWait: TimeInterval = 1.5
    /// How long the UI waits before it stops showing a loading state. Later background recovery may
    /// still replace the result once.
    public static let presentationWait: TimeInterval = 1.5
    public static let sourceName = "nvidia-rtx-games-list"
    public static let sourceLabel = "NVIDIA's DLSS games list"

    /// Column order of a row in NVIDIA's table.
    static let columns = [
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
    public static func normalize(_ title: String) -> String {
        let stripped = String(String.UnicodeScalarView(title.unicodeScalars.filter { !strippedScalars.contains($0) }))
        let folded = stripped.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let ascii = String(String.UnicodeScalarView(folded.unicodeScalars.filter { $0.isASCII }))
        let ampersands = ascii.lowercased().replacingOccurrences(of: "&", with: " and ")
        return ampersands
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    /// A normalized title without "the"/"tm" and without trailing edition words.
    public static func loose(_ normalized: String) -> String {
        var words = normalized.split(separator: " ").map(String.init).filter { $0 != "the" && $0 != "tm" }
        while true {
            let before = words.count
            if words.count > 1, let last = words.last, last == "edition" || last == "pc" {
                words.removeLast()
            }
            if let suffix = dlssEditionSuffixes.first(where: { words.count > $0.count && words.suffix($0.count) == $0 }) {
                words.removeLast(suffix.count)
            }
            if words.count == before { return words.joined(separator: " ") }
        }
    }
}

/// Every parsed row indexed for lookup. Rows without DLSS are indexed too, so an exact title with no
/// DLSS never falls through to a loosely matching edition that has it.
public struct DlssGamesIndex: Sendable {
    private var exact: [String: DlssGameSupport?] = [:]
    private var loose: [String: DlssGameSupport?] = [:]
    public let rowCount: Int

    public init(rows: [DlssGamesRow]) {
        var exact: [String: DlssGameSupport?] = [:]
        var loose: [String: DlssGameSupport?] = [:]
        for row in rows {
            let normalized = DlssTitleMatcher.normalize(row.title)
            guard !normalized.isEmpty else { continue }
            let support = row.support?.hasAnySupport == true ? row.support : nil
            loose.updateValue(support, forKey: DlssTitleMatcher.loose(normalized))
            exact.updateValue(support, forKey: normalized)
        }
        self.exact = exact
        self.loose = loose
        self.rowCount = rows.count
    }

    public var isEmpty: Bool { exact.isEmpty }

    public func lookup(_ title: String) -> DlssMatchOutcome {
        let normalized = DlssTitleMatcher.normalize(title)
        guard !normalized.isEmpty else { return .unknown }
        if let stored = exact[normalized] {
            return Self.outcome(stored)
        }
        guard let stored = loose[DlssTitleMatcher.loose(normalized)] else { return .unknown }
        return Self.outcome(stored)
    }

    private static func outcome(_ support: DlssGameSupport?) -> DlssMatchOutcome {
        guard let support else { return .listedWithoutSupport }
        return .matched(support)
    }
}

public enum DlssGamesListError: Error, Equatable, Sendable {
    case tooLarge
    case malformed(String)

    public var message: String {
        switch self {
        case .tooLarge: "larger than 4 MiB"
        case let .malformed(reason): reason
        }
    }
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
        return rows.compactMap { row -> DlssGamesRow? in
            guard let row = row as? [String: Any], row["type"] as? String == "Game" else { return nil }
            let title: String
            if let name = row["name"] as? String {
                title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let name = row["name"] as? NSNumber {
                title = name.stringValue
            } else {
                return nil
            }
            guard !title.isEmpty, title.utf8.count <= DlssCompatibilityLimits.maximumNameBytes else { return nil }
            let cells = DlssCompatibilityLimits.columns.map { column -> String in
                guard let cell = row[column] as? String else { return "" }
                let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.utf8.count <= DlssCompatibilityLimits.maximumCellBytes ? trimmed : ""
            }
            return DlssGamesRow(title: title, support: support(from: cells))
        }
    }

    static func support(from cells: [String]) -> DlssGameSupport? {
        guard cells.count == 5 else { return nil }
        let support = DlssGameSupport(
            superResolution: DlssSupport.fromCell(cells[0]),
            frameGeneration: DlssSupport.fromCell(cells[1]),
            multiFrameGeneration: DlssMultiFrameGeneration.fromCell(cells[2]),
            rayReconstruction: DlssSupport.fromCell(cells[3]),
            dlaa: DlssSupport.fromCell(cells[4])
        )
        return support.hasAnySupport ? support : nil
    }
}
