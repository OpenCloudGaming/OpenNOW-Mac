//  Cloud DLSS overrides: the object the official client sends in
//  `requestedStreamingFeatures.dlssOverrides`, and the membership that gates it.

import Foundation

/// `DlssSrMode`. The value is the wire value; the input resolution the official client pairs with
/// each fixed mode travels in `srScale`.
public enum DlssSuperResolutionMode: Int, CaseIterable, Sendable {
    case inGame = 0
    case performance = 1
    case balanced = 2
    case quality = 3
    case ultraPerformance = 4
    case dlaa = 5
    case custom = 6

    public var label: String {
        switch self {
        case .inGame: "In-game"
        case .performance: "Performance"
        case .balanced: "Balanced"
        case .quality: "Quality"
        case .ultraPerformance: "Ultra Performance"
        case .dlaa: "DLAA"
        case .custom: "Custom"
        }
    }

    /// The fixed input-resolution percentage this mode carries, or nil for Custom.
    public var fixedInputScale: Int? {
        switch self {
        case .inGame, .dlaa: 100
        case .quality: 67
        case .balanced: 58
        case .performance: 50
        case .ultraPerformance: 33
        case .custom: nil
        }
    }
}

/// `DlssFgMode`.
public enum DlssFrameGenerationMode: Int, CaseIterable, Sendable {
    case inGame = 0
    case dynamic = 1

    public var label: String {
        switch self {
        case .inGame: "In-game"
        case .dynamic: "Dynamic"
        }
    }
}

/// The model presets NVIDIA publishes per feature. The wire value carries the meaning: 0 lets the
/// game choose, 1 is NVIDIA Recommended, 2-7 are presets A-F and 11-14 are J-M.
public enum DlssModelPreset {
    public static let superResolutionModels = [0, 1, 2, 3, 4, 5, 6, 7, 11, 12, 13, 14]
    public static let rayReconstructionModels = [0, 1, 5, 7]
    public static let frameGenerationModels = [0, 1, 2, 3]

    /// The three-way preset the settings card offers above the per-feature pickers.
    public enum Choice: String, CaseIterable, Sendable {
        case inGame
        case recommended
        case custom

        public var label: String {
            switch self {
            case .inGame: "In-game"
            case .recommended: "Recommended"
            case .custom: "Custom"
            }
        }
    }

    private static let presetLetterNames = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    public static func label(for value: Int) -> String {
        guard value > 1 else { return value == 1 ? "Recommended" : "In-game" }
        guard presetLetterNames.indices.contains(value - 2) else { return "In-game" }
        return "Preset \(presetLetterNames[value - 2])"
    }

    public static func labels(for values: [Int]) -> [String] {
        values.map(label(for:))
    }
}

/// The whole `dlssOverrides` object. Every field is an integer wire value.
public struct DlssOverrides: Equatable, Sendable {
    public static let superResolutionModelMaximum = 14
    public static let rayReconstructionModelMaximum = 7
    public static let frameGenerationModelMaximum = 3
    public static let customScaleRange = 33...100
    public static let customScaleDefault = 75
    /// Multipliers the client understands. Which of them a membership includes is a separate
    /// question, answered by `DlssEntitlements`.
    public static let frameGenerationMultipliers = [3, 4, 5, 6]

    public var superResolutionMode: Int
    public var superResolutionModel: Int
    public var superResolutionScale: Int
    public var rayReconstructionModel: Int
    public var frameGenerationMode: Int
    public var frameGenerationModel: Int
    public var frameGenerationMultiplier: Int

    /// What the official client sends when nothing is overridden: every feature follows the game.
    public static let useGameSettings = DlssOverrides(
        superResolutionMode: 0,
        superResolutionModel: 0,
        superResolutionScale: 100,
        rayReconstructionModel: 0,
        frameGenerationMode: 0,
        frameGenerationModel: 0,
        frameGenerationMultiplier: 0
    )

    public init(
        superResolutionMode: Int,
        superResolutionModel: Int,
        superResolutionScale: Int,
        rayReconstructionModel: Int,
        frameGenerationMode: Int,
        frameGenerationModel: Int,
        frameGenerationMultiplier: Int
    ) {
        self.superResolutionMode = superResolutionMode
        self.superResolutionModel = superResolutionModel
        self.superResolutionScale = superResolutionScale
        self.rayReconstructionModel = rayReconstructionModel
        self.frameGenerationMode = frameGenerationMode
        self.frameGenerationModel = frameGenerationModel
        self.frameGenerationMultiplier = frameGenerationMultiplier
    }

    /// Reads a stored object, coercing every field. A missing or malformed dictionary reads as the
    /// defaults rather than as a partial override.
    public init(stored: [String: Any]?) {
        self.init(
            superResolutionMode: Self.integerValue(of: stored?["srMode"]),
            superResolutionModel: Self.integerValue(of: stored?["srModel"]),
            superResolutionScale: Self.integerValue(of: stored?["srScale"], fallback: Self.customScaleDefault),
            rayReconstructionModel: Self.integerValue(of: stored?["rrModel"]),
            frameGenerationMode: Self.integerValue(of: stored?["fgMode"]),
            frameGenerationModel: Self.integerValue(of: stored?["fgModel"]),
            frameGenerationMultiplier: Self.integerValue(of: stored?["fgMultiplier"])
        )
    }

    /// The persisted form. It keeps `fgMultiplier` even when unused, so a round trip through storage
    /// does not silently drop the reader's last multiplier choice.
    public var storedDictionary: [String: Any] {
        [
            "srMode": superResolutionMode,
            "srModel": superResolutionModel,
            "srScale": superResolutionScale,
            "rrModel": rayReconstructionModel,
            "fgMode": frameGenerationMode,
            "fgModel": frameGenerationModel,
            "fgMultiplier": frameGenerationMultiplier,
        ]
    }

    public var isUsingGameSettings: Bool { normalized() == Self.useGameSettings }

    public var superResolution: DlssSuperResolutionMode {
        DlssSuperResolutionMode(rawValue: superResolutionMode) ?? .inGame
    }

    public var frameGeneration: DlssFrameGenerationMode {
        DlssFrameGenerationMode(rawValue: frameGenerationMode) ?? .inGame
    }

    /// Clamps every field and applies the client's coupling: a model left to the game also leaves
    /// its mode to the game, and the multiplier only exists for Dynamic frame generation.
    public func normalized() -> DlssOverrides {
        let superResolutionModel = Self.boundedEnumValue(self.superResolutionModel, maximum: Self.superResolutionModelMaximum)
        let superResolutionMode = superResolutionModel == 0
            ? 0
            : Self.boundedEnumValue(self.superResolutionMode, maximum: DlssSuperResolutionMode.custom.rawValue)
        let fixedScale = DlssSuperResolutionMode(rawValue: superResolutionMode)?.fixedInputScale
        let frameGenerationModel = Self.boundedEnumValue(self.frameGenerationModel, maximum: Self.frameGenerationModelMaximum)
        let frameGenerationMode = frameGenerationModel == 0
            ? 0
            : Self.boundedEnumValue(self.frameGenerationMode, maximum: DlssFrameGenerationMode.dynamic.rawValue)
        return DlssOverrides(
            superResolutionMode: superResolutionMode,
            superResolutionModel: superResolutionModel,
            superResolutionScale: fixedScale ?? Self.clamped(self.superResolutionScale, to: Self.customScaleRange),
            rayReconstructionModel: Self.boundedEnumValue(self.rayReconstructionModel, maximum: Self.rayReconstructionModelMaximum),
            frameGenerationMode: frameGenerationMode,
            frameGenerationModel: frameGenerationModel,
            frameGenerationMultiplier: Self.normalizedMultiplier(
                self.frameGenerationMultiplier,
                frameGenerationMode: frameGenerationMode
            )
        )
    }

    /// The override that may actually be requested for this membership. Saved preferences survive a
    /// lapse in access; this only decides what leaves the Mac.
    public func applyingAccess(_ entitlements: DlssEntitlements) -> DlssOverrides {
        var overrides = normalized()
        if !entitlements.superResolution.isEntitled {
            overrides.superResolutionMode = 0
            overrides.superResolutionModel = 0
            overrides.superResolutionScale = DlssSuperResolutionMode.inGame.fixedInputScale ?? 100
        }
        if !entitlements.frameGeneration.isEntitled {
            overrides.frameGenerationMode = 0
            overrides.frameGenerationModel = 0
            overrides.frameGenerationMultiplier = 0
        }
        if entitlements.frameGeneration.isEntitled, overrides.frameGenerationMode == DlssFrameGenerationMode.dynamic.rawValue {
            let allowed = entitlements.allowedFrameGenerationMultipliers
            overrides.frameGenerationMultiplier = allowed.contains(overrides.frameGenerationMultiplier)
                ? overrides.frameGenerationMultiplier
                : Self.lowestMultiplier(of: allowed)
            overrides.frameGenerationMode = overrides.frameGenerationMultiplier == 0 ? 0 : overrides.frameGenerationMode
        }
        if !entitlements.rayReconstruction.isEntitled {
            overrides.rayReconstructionModel = 0
        }
        return overrides
    }

    /// `requestedStreamingFeatures.dlssOverrides`. Like the official client, the multiplier is
    /// omitted unless frame generation is Dynamic.
    public var sessionRequestDictionary: [String: Any] {
        let overrides = normalized()
        var dictionary: [String: Any] = [
            "srMode": overrides.superResolutionMode,
            "srModel": overrides.superResolutionModel,
            "srScale": overrides.superResolutionScale,
            "rrModel": overrides.rayReconstructionModel,
            "fgMode": overrides.frameGenerationMode,
            "fgModel": overrides.frameGenerationModel,
        ]
        if overrides.frameGenerationMode == DlssFrameGenerationMode.dynamic.rawValue {
            dictionary["fgMultiplier"] = overrides.frameGenerationMultiplier
        }
        return dictionary
    }

    /// What the next session will ask for, described as a request rather than as a measurement. The
    /// stats HUD and the settings card both read these, so the two can never disagree.
    public var superResolutionRequestLabel: String {
        let overrides = normalized()
        guard overrides.superResolution != .inGame else { return "In-game" }
        return "\(overrides.superResolution.label) \(overrides.superResolutionScale)%"
    }

    public var frameGenerationRequestLabel: String {
        let overrides = normalized()
        guard overrides.frameGeneration == .dynamic else { return "In-game" }
        return "Dynamic up to \(overrides.frameGenerationMultiplier)×"
    }

    public var rayReconstructionRequestLabel: String {
        DlssModelPreset.label(for: normalized().rayReconstructionModel)
    }

    public var nextSessionRequestSummary: String {
        "SR \(superResolutionRequestLabel)  ·  FG \(frameGenerationRequestLabel)  ·  RR \(rayReconstructionRequestLabel)"
    }

    private static func normalizedMultiplier(_ multiplier: Int, frameGenerationMode: Int) -> Int {
        guard frameGenerationMode == DlssFrameGenerationMode.dynamic.rawValue else { return 0 }
        guard frameGenerationMultipliers.contains(multiplier) else { return frameGenerationMultipliers[0] }
        return multiplier
    }

    /// 0 when the membership includes no multiplier, which callers read as "Dynamic is unavailable".
    private static func lowestMultiplier(of allowed: [Int]) -> Int {
        allowed.min() ?? 0
    }

    private static func integerValue(of value: Any?, fallback: Int = 0) -> Int {
        guard let value else { return fallback }
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? fallback }
        return fallback
    }

    private static func boundedEnumValue(_ value: Int, maximum: Int) -> Int {
        (0...maximum).contains(value) ? value : 0
    }

    private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// One membership capability: whether the account has it, and whether NVIDIA upsells it.
public struct DlssCapability: Equatable, Sendable {
    public let isEntitled: Bool
    public let isUpsell: Bool

    public init(isEntitled: Bool = false, isUpsell: Bool = false) {
        self.isEntitled = isEntitled
        self.isUpsell = isUpsell
    }
}

/// Which DLSS overrides the membership includes, read from the MES subscription payload's
/// `features.features` and `upsells`. Absent or unreadable data is never entitled.
public struct DlssEntitlements: Equatable, Sendable {
    public let superResolution: DlssCapability
    public let frameGeneration: DlssCapability
    public let rayReconstruction: DlssCapability
    /// Multi Frame Generation multipliers this membership includes, ascending.
    public let frameGenerationMultipliers: [Int]

    public static let none = DlssEntitlements()

    public init(
        superResolution: DlssCapability = DlssCapability(),
        frameGeneration: DlssCapability = DlssCapability(),
        rayReconstruction: DlssCapability = DlssCapability(),
        frameGenerationMultipliers: [Int] = []
    ) {
        self.superResolution = superResolution
        self.frameGeneration = frameGeneration
        self.rayReconstruction = rayReconstruction
        self.frameGenerationMultipliers = frameGenerationMultipliers.sorted()
    }

    public var hasAnyEntitlement: Bool {
        superResolution.isEntitled || frameGeneration.isEntitled || rayReconstruction.isEntitled
    }

    /// The features the membership lacks but NVIDIA upsells, in display order.
    public var upsellFeatureLabels: [String] {
        var labels: [String] = []
        if !superResolution.isEntitled, superResolution.isUpsell { labels.append("Super Resolution") }
        if !frameGeneration.isEntitled, frameGeneration.isUpsell { labels.append("Frame Generation") }
        if !rayReconstruction.isEntitled, rayReconstruction.isUpsell { labels.append("Ray Reconstruction") }
        return labels
    }

    public var allowedFrameGenerationMultipliers: [Int] {
        guard frameGeneration.isEntitled else { return [] }
        return frameGenerationMultipliers
    }

    public var highestAllowedFrameGenerationMultiplier: Int? {
        allowedFrameGenerationMultipliers.max()
    }

    /// Dynamic frame generation needs both the FG override and at least one multiplier.
    public var supportsDynamicFrameGeneration: Bool {
        frameGeneration.isEntitled && !frameGenerationMultipliers.isEmpty
    }

    public func capability(for feature: DlssCompatibilityFeature) -> DlssCapability {
        switch feature {
        case .superResolution, .dlaa: superResolution
        case .frameGeneration: frameGeneration
        case .rayReconstruction: rayReconstruction
        }
    }

    /// Reads the entitlements out of a membership payload. The nesting around the feature list is
    /// not a documented contract, so this accepts the shapes the subscription reader already does.
    public static func parse(subscription: NSDictionary?) -> DlssEntitlements {
        guard let subscription else { return .none }
        let root = (subscription["subscription"] as? NSDictionary) ?? subscription
        let features = featureArray(from: root["features"])
        let upsells = root["upsells"] as? [Any] ?? []
        return parse(features: features, upsells: upsells)
    }

    public static func parse(features: [Any], upsells: [Any]) -> DlssEntitlements {
        func feature(named key: String) -> NSDictionary? {
            features.compactMap { $0 as? NSDictionary }.first { $0["key"] as? String == key }
        }
        func isEntitled(named name: String) -> Bool {
            guard let feature = feature(named: "SUPPORTED_DLSS_OVERRIDE_\(name)") else { return false }
            return isFeatureValueEnabled(feature["textValue"] ?? feature["value"] ?? feature["booleanValue"])
        }
        func isUpsold(named name: String) -> Bool {
            let key = "SUPPORT_DLSS_OVERRIDE_\(name)"
            return upsells.compactMap { $0 as? NSDictionary }.contains { $0["key"] as? String == key && ($0["booleanValue"] as? Bool) == true }
        }
        func capability(named name: String) -> DlssCapability {
            DlssCapability(isEntitled: isEntitled(named: name), isUpsell: isUpsold(named: name))
        }
        return DlssEntitlements(
            superResolution: capability(named: "SR"),
            frameGeneration: capability(named: "FG"),
            rayReconstruction: capability(named: "RR"),
            frameGenerationMultipliers: parseFrameGenerationMultipliers(from: feature(named: "SUPPORTED_DLSS_FG_MULTIPLIERS"))
        )
    }

    /// The feature list arrives either as a bare array or nested one level under an object that also
    /// carries unrelated keys.
    private static func featureArray(from rawValue: Any?) -> [Any] {
        if let array = rawValue as? [Any] { return array }
        guard let dictionary = rawValue as? NSDictionary else { return [] }
        if let nested = dictionary["features"] as? [Any] { return nested }
        for value in dictionary.allValues {
            if let array = value as? [Any] { return array }
        }
        return []
    }

    /// `SUPPORTED_DLSS_FG_MULTIPLIERS` carries either `{value, isEntitled}` rows, a plain list of
    /// labels, or a single boolean that entitles all of them.
    private static func parseFrameGenerationMultipliers(from feature: NSDictionary?) -> [Int] {
        guard let feature else { return [] }
        guard let text = feature["textValue"] as? String else {
            return parseMultiplierList(feature["setValue"]) ?? parseMultiplierFlag(feature["booleanValue"])
        }
        guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            return []
        }
        if let isEnabled = value as? Bool { return isEnabled ? DlssOverrides.frameGenerationMultipliers : [] }
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { row -> Int? in
            guard let row = row as? NSDictionary, (row["isEntitled"] as? Bool) == true else { return nil }
            return frameGenerationMultiplier(fromLabel: row["value"] as? String)
        }
    }

    private static func parseMultiplierList(_ rawValue: Any?) -> [Int]? {
        guard let values = rawValue as? [Any] else { return nil }
        return values.compactMap { frameGenerationMultiplier(fromLabel: $0 as? String) }
    }

    private static func parseMultiplierFlag(_ rawValue: Any?) -> [Int] {
        guard let isEnabled = rawValue as? Bool, isEnabled else { return [] }
        return DlssOverrides.frameGenerationMultipliers
    }

    private static func frameGenerationMultiplier(fromLabel label: String?) -> Int? {
        guard let label, label.hasSuffix("X") || label.hasSuffix("x") else { return nil }
        return Int(label.dropLast())
    }

    /// The official client's feature reader: truthy when non-null, non-zero, non-empty or an object.
    /// Anything unreadable counts as not entitled.
    private static func isFeatureValueEnabled(_ rawValue: Any?) -> Bool {
        guard let rawValue, !(rawValue is NSNull) else { return false }
        if let value = rawValue as? Bool { return value }
        if let value = rawValue as? NSNumber { return value.doubleValue != 0 }
        guard let text = rawValue as? String else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let data = trimmed.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            return isJSONFeatureValueEnabled(value)
        }
        return ["true", "1", "yes"].contains(trimmed.lowercased())
    }

    private static func isJSONFeatureValueEnabled(_ value: Any) -> Bool {
        switch value {
        case let isEnabled as Bool: isEnabled
        case let number as NSNumber: number.doubleValue != 0
        case let text as String: !text.isEmpty
        case let items as [Any]: !items.isEmpty
        case is [String: Any]: true
        default: false
        }
    }
}
