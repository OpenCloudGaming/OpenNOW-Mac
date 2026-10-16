//  The cloud-side DLSS override object OpenNOW asks the seat to apply, plus the membership
//  entitlements that decide which parts of it may be sent.
//
//  This mirrors the official GeForce NOW client's `DlssSrMode`, `DlssSrModel`, `DlssRrModel`,
//  `DlssFgMode` and `DlssFgModel` enumerations. Zero means "leave this to the game", so a stored
//  preference that names no model also names no mode. The object is normalized on every read:
//  unknown values fall back to the game's own setting rather than being forwarded.
//
//  DLSS runs on the cloud rig. Nothing here touches MetalFX, decoding, presentation or the HUD.

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

    public var detail: String {
        guard let scale = fixedInputScale else { return "\(DlssOverrides.customScaleRange.lowerBound)-\(DlssOverrides.customScaleRange.upperBound)%" }
        return self == .inGame ? "Game decides" : "\(scale)%"
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

/// One picker row for a model enumeration.
public struct DlssModelOption: Equatable, Sendable, Identifiable {
    public var id: Int { value }
    public let value: Int
    public let label: String

    public init(value: Int, label: String) {
        self.value = value
        self.label = label
    }
}

/// The model presets NVIDIA publishes for each feature. `srModel`/`rrModel`/`fgModel` are the wire
/// values; the letter is the client's own name for the preset, not a DLSS version.
public enum DlssModelPreset {
    /// 0 lets the game choose, 1 is NVIDIA Recommended, 2-7 are presets A-F and 11-14 are J-M.
    public static let superResolutionModels = [0, 1, 2, 3, 4, 5, 6, 7, 11, 12, 13, 14]
    public static let rayReconstructionModels = [0, 1, 5, 7]
    public static let frameGenerationModels = [0, 1, 2, 3]

    private static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    public static func label(for value: Int) -> String {
        if value == 0 { return "In-game" }
        if value == 1 { return "Recommended" }
        guard letters.indices.contains(value - 2) else { return "In-game" }
        return "Preset \(letters[value - 2])"
    }

    public static func options(_ values: [Int]) -> [DlssModelOption] {
        values.map { DlssModelOption(value: $0, label: label(for: $0)) }
    }

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
}

/// The whole `dlssOverrides` object. Every field is an integer wire value.
public struct DlssOverrides: Equatable, Sendable {
    public static let superResolutionModelMaximum = 14
    public static let rayReconstructionModelMaximum = 7
    public static let frameGenerationModelMaximum = 3
    public static let customScaleRange = 33...100
    public static let customScaleDefault = 75
    /// Multi Frame Generation multipliers the client understands. Which of them a membership
    /// actually includes is a separate question, answered by `DlssEntitlements`.
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

    /// Reads a stored object, coercing every field the way the payload builder does. A missing or
    /// malformed dictionary reads as the defaults rather than as a partial override.
    public init(stored: [String: Any]?) {
        self.init(
            superResolutionMode: Self.integer(stored?["srMode"]),
            superResolutionModel: Self.integer(stored?["srModel"]),
            superResolutionScale: Self.integer(stored?["srScale"], fallback: Self.customScaleDefault),
            rayReconstructionModel: Self.integer(stored?["rrModel"]),
            frameGenerationMode: Self.integer(stored?["fgMode"]),
            frameGenerationModel: Self.integer(stored?["fgModel"]),
            frameGenerationMultiplier: Self.integer(stored?["fgMultiplier"])
        )
    }

    /// The persisted form. It keeps `fgMultiplier` even when it is unused so a round trip through
    /// storage does not silently drop the reader's last multiplier choice.
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

    /// Clamps every field to a known value and applies the client's coupling: a model left to the
    /// game also leaves its mode to the game, fixed SR modes carry their fixed input resolution, and
    /// the multiplier only exists for Dynamic frame generation.
    public func normalized() -> DlssOverrides {
        let srModel = Self.bounded(superResolutionModel, maximum: Self.superResolutionModelMaximum)
        let srMode = srModel == 0 ? 0 : Self.bounded(superResolutionMode, maximum: DlssSuperResolutionMode.custom.rawValue)
        let srScale = (DlssSuperResolutionMode(rawValue: srMode)?.fixedInputScale)
            ?? Self.clamp(superResolutionScale, Self.customScaleRange)
        let fgModel = Self.bounded(frameGenerationModel, maximum: Self.frameGenerationModelMaximum)
        let fgMode = fgModel == 0 ? 0 : Self.bounded(frameGenerationMode, maximum: DlssFrameGenerationMode.dynamic.rawValue)
        let fgMultiplier = fgMode == DlssFrameGenerationMode.dynamic.rawValue
            ? (Self.frameGenerationMultipliers.contains(frameGenerationMultiplier) ? frameGenerationMultiplier : Self.frameGenerationMultipliers[0])
            : 0
        return DlssOverrides(
            superResolutionMode: srMode,
            superResolutionModel: srModel,
            superResolutionScale: srScale,
            rayReconstructionModel: Self.bounded(rayReconstructionModel, maximum: Self.rayReconstructionModelMaximum),
            frameGenerationMode: fgMode,
            frameGenerationModel: fgModel,
            frameGenerationMultiplier: fgMultiplier
        )
    }

    /// The override that may actually be requested for this membership. Saved preferences survive a
    /// lapse in access — this only decides what leaves the Mac. An unentitled feature falls back to
    /// the game's own setting rather than being forwarded and refused by the seat.
    public func applyingAccess(_ entitlements: DlssEntitlements) -> DlssOverrides {
        var result = normalized()
        if !entitlements.superResolution.isEntitled {
            result.superResolutionMode = 0
            result.superResolutionModel = 0
            result.superResolutionScale = DlssSuperResolutionMode.inGame.fixedInputScale ?? 100
        }
        if !entitlements.frameGeneration.isEntitled {
            result.frameGenerationMode = 0
            result.frameGenerationModel = 0
            result.frameGenerationMultiplier = 0
        } else if result.frameGenerationMode == DlssFrameGenerationMode.dynamic.rawValue {
            let allowed = entitlements.frameGenerationMultipliers
            if let lowest = allowed.min() {
                if !allowed.contains(result.frameGenerationMultiplier) {
                    result.frameGenerationMultiplier = lowest
                }
            } else {
                result.frameGenerationMode = 0
                result.frameGenerationMultiplier = 0
            }
        }
        if !entitlements.rayReconstruction.isEntitled {
            result.rayReconstructionModel = 0
        }
        return result
    }

    /// `requestedStreamingFeatures.dlssOverrides`. Like the official client, the multiplier is
    /// omitted unless frame generation is Dynamic.
    public var sessionRequestDictionary: [String: Any] {
        let normalized = normalized()
        var dictionary: [String: Any] = [
            "srMode": normalized.superResolutionMode,
            "srModel": normalized.superResolutionModel,
            "srScale": normalized.superResolutionScale,
            "rrModel": normalized.rayReconstructionModel,
            "fgMode": normalized.frameGenerationMode,
            "fgModel": normalized.frameGenerationModel,
        ]
        if normalized.frameGenerationMode == DlssFrameGenerationMode.dynamic.rawValue {
            dictionary["fgMultiplier"] = normalized.frameGenerationMultiplier
        }
        return dictionary
    }

    /// What the next session will ask for, described as a request rather than as a measurement.
    public var nextSessionRequestSummary: String {
        let normalized = normalized()
        let superResolutionText = normalized.superResolution == .inGame
            ? "In-game"
            : "\(normalized.superResolution.label) \(normalized.superResolutionScale)%"
        let frameGenerationText = normalized.frameGeneration == .dynamic
            ? "Dynamic up to \(normalized.frameGenerationMultiplier)×"
            : "In-game"
        let rayReconstructionText = DlssModelPreset.label(for: normalized.rayReconstructionModel)
        return "SR \(superResolutionText)  ·  FG \(frameGenerationText)  ·  RR \(rayReconstructionText)"
    }

    private static func integer(_ value: Any?, fallback: Int = 0) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? fallback }
        return fallback
    }

    private static func bounded(_ value: Int, maximum: Int) -> Int {
        (0...maximum).contains(value) ? value : 0
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// One membership capability: whether the account has it, and whether NVIDIA upsells it.
public struct DlssCapability: Equatable, Sendable {
    public var isEntitled: Bool
    public var isUpsell: Bool

    public init(isEntitled: Bool = false, isUpsell: Bool = false) {
        self.isEntitled = isEntitled
        self.isUpsell = isUpsell
    }
}

/// Which DLSS overrides the membership includes, read from the MES subscription payload's
/// `features.features` and `upsells` exactly as the official client's ecommerce service reads them.
///
/// Absent or unreadable data is *not* entitled: an unknown membership must never be treated as an
/// entitled one.
public struct DlssEntitlements: Equatable, Sendable {
    public var superResolution: DlssCapability
    public var frameGeneration: DlssCapability
    public var rayReconstruction: DlssCapability
    /// Multi Frame Generation multipliers this membership includes, ascending.
    public var frameGenerationMultipliers: [Int]

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
        frameGeneration.isEntitled ? frameGenerationMultipliers : []
    }

    public var lowestAllowedFrameGenerationMultiplier: Int? {
        allowedFrameGenerationMultipliers.min()
    }

    public var highestAllowedFrameGenerationMultiplier: Int? {
        allowedFrameGenerationMultipliers.max()
    }

    /// Dynamic frame generation needs both the FG override and at least one multiplier.
    public var supportsDynamicFrameGeneration: Bool {
        frameGeneration.isEntitled && !frameGenerationMultipliers.isEmpty
    }

    /// Reads the entitlements out of a membership payload. The nesting around the feature list is
    /// not a documented contract, so this accepts the shapes the subscription reader already does.
    public static func parse(subscription: NSDictionary?) -> DlssEntitlements {
        guard let subscription else { return .none }
        let root = (subscription["subscription"] as? NSDictionary) ?? subscription
        let features = featureList(root["features"])
        let upsells = root["upsells"] as? [Any] ?? []
        return parse(features: features, upsells: upsells)
    }

    public static func parse(features: [Any], upsells: [Any]) -> DlssEntitlements {
        let feature = { (key: String) -> NSDictionary? in
            features.compactMap { $0 as? NSDictionary }.first { $0["key"] as? String == key }
        }
        let entitled = { (key: String) -> Bool in
            guard let feature = feature(key) else { return false }
            return isEnabled(feature["textValue"] ?? feature["value"] ?? feature["booleanValue"])
        }
        let upsell = { (name: String) -> Bool in
            let key = "SUPPORT_DLSS_OVERRIDE_\(name)"
            return upsells.compactMap { $0 as? NSDictionary }.contains { $0["key"] as? String == key && ($0["booleanValue"] as? Bool) == true }
        }
        let capability = { (name: String) -> DlssCapability in
            DlssCapability(
                isEntitled: entitled("SUPPORTED_DLSS_OVERRIDE_\(name)"),
                isUpsell: upsell(name)
            )
        }
        return DlssEntitlements(
            superResolution: capability("SR"),
            frameGeneration: capability("FG"),
            rayReconstruction: capability("RR"),
            frameGenerationMultipliers: frameGenerationMultipliers(feature("SUPPORTED_DLSS_FG_MULTIPLIERS"))
        )
    }

    /// The membership feature list arrives either as a bare array or nested one level under an
    /// object that also carries unrelated keys.
    private static func featureList(_ rawValue: Any?) -> [Any] {
        if let array = rawValue as? [Any] { return array }
        guard let dictionary = rawValue as? NSDictionary else { return [] }
        if let nested = dictionary["features"] as? [Any] { return nested }
        for value in dictionary.allValues {
            if let array = value as? [Any] { return array }
        }
        return []
    }

    /// `SUPPORTED_DLSS_FG_MULTIPLIERS` carries either an array of `{value: "3X", isEntitled}` rows,
    /// a plain list of labels, or a single boolean that entitles all of them.
    private static func frameGenerationMultipliers(_ feature: NSDictionary?) -> [Int] {
        guard let feature else { return [] }
        if let text = feature["textValue"] as? String {
            if let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
                if let enabled = value as? Bool {
                    return enabled ? DlssOverrides.frameGenerationMultipliers : []
                }
                if let rows = value as? [Any] {
                    return rows.compactMap { row -> Int? in
                        guard let row = row as? NSDictionary, (row["isEntitled"] as? Bool) == true else { return nil }
                        return multiplier(row["value"] as? String)
                    }
                }
            }
            return []
        }
        if let enabled = feature["booleanValue"] as? Bool {
            return enabled ? DlssOverrides.frameGenerationMultipliers : []
        }
        if let set = feature["setValue"] as? [Any] {
            return set.compactMap { multiplier($0 as? String) }
        }
        return []
    }

    private static func multiplier(_ label: String?) -> Int? {
        guard let label, label.hasSuffix("X") || label.hasSuffix("x") else { return nil }
        return Int(label.dropLast())
    }

    /// The official client's feature reader: a JSON scalar, truthy when it is non-null, non-zero,
    /// non-empty, or an object. Anything unreadable counts as not entitled.
    private static func isEnabled(_ rawValue: Any?) -> Bool {
        guard let rawValue, !(rawValue is NSNull) else { return false }
        if let value = rawValue as? Bool { return value }
        if let value = rawValue as? NSNumber { return value.doubleValue != 0 }
        guard let text = rawValue as? String else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let data = trimmed.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            switch value {
            case let bool as Bool: return bool
            case let number as NSNumber: return number.doubleValue != 0
            case let string as String: return !string.isEmpty
            case let array as [Any]: return !array.isEmpty
            case is [String: Any]: return true
            default: return false
            }
        }
        return ["true", "1", "yes"].contains(trimmed.lowercased())
    }
}
