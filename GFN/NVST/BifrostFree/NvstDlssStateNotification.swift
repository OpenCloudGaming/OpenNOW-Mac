import Foundation

/// The seat's DLSS override state, the custom message Bifrost dispatches as `"DlssState"`. It
/// reports what the seat applied, which is the only confirmation a client gets.
public struct NvstDlssStateNotification: Equatable, Sendable {
    /// The `messageType` the seat stamps on the custom message this notification is carried in.
    public static let messageTypeName = "DlssState"

    /// The values the seat settled on, as the same integer wire values a request carries. Every
    /// field reads as 0 when the seat omits it, which is also the value that means "follow the game".
    public struct Overrides: Equatable, Sendable {
        public let superResolutionMode: Int
        public let superResolutionModel: Int
        public let superResolutionScale: Int
        public let rayReconstructionModel: Int
        public let frameGenerationMode: Int
        public let frameGenerationModel: Int
        public let frameGenerationMultiplier: Int

        /// What the object reads as when the seat reports no override at all.
        public static let none = Overrides(
            superResolutionMode: 0,
            superResolutionModel: 0,
            superResolutionScale: 0,
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

        init(dictionary: [String: Any]) {
            func wireValue(_ key: String) -> Int {
                NvstDlssStateNotification.integer(in: dictionary, keys: [key]) ?? 0
            }
            self.init(
                superResolutionMode: wireValue("srMode"),
                superResolutionModel: wireValue("srModel"),
                superResolutionScale: wireValue("srScale"),
                rayReconstructionModel: wireValue("rrModel"),
                frameGenerationMode: wireValue("fgMode"),
                frameGenerationModel: wireValue("fgModel"),
                frameGenerationMultiplier: wireValue("fgMultiplier")
            )
        }
    }

    public let isSuperResolutionOverridden: Bool
    public let isRayReconstructionOverridden: Bool
    public let isFrameGenerationOverridden: Bool
    /// The multiplier the seat is running, 0 while frame generation is off.
    public let activeFrameGenerationMultiplier: Int
    public let overrides: Overrides

    public init(
        isSuperResolutionOverridden: Bool,
        isRayReconstructionOverridden: Bool,
        isFrameGenerationOverridden: Bool,
        activeFrameGenerationMultiplier: Int,
        overrides: Overrides
    ) {
        self.isSuperResolutionOverridden = isSuperResolutionOverridden
        self.isRayReconstructionOverridden = isRayReconstructionOverridden
        self.isFrameGenerationOverridden = isFrameGenerationOverridden
        self.activeFrameGenerationMultiplier = max(0, activeFrameGenerationMultiplier)
        self.overrides = overrides
    }

    // MARK: - Applied values

    /// The Super Resolution the seat is running, or "In-game" when it applied no override.
    public var superResolutionLabel: String {
        guard isSuperResolutionOverridden,
              let mode = DlssSuperResolutionMode(rawValue: overrides.superResolutionMode),
              mode != .inGame else { return "In-game" }
        return "\(mode.label) \(mode.fixedInputScale ?? overrides.superResolutionScale)%"
    }

    /// The Frame Generation the seat is running, or "In-game" when it applied no override.
    public var frameGenerationLabel: String {
        guard isFrameGenerationOverridden,
              let mode = NvstAppliedFrameGenerationMode(rawValue: overrides.frameGenerationMode),
              mode != .inGame else { return "In-game" }
        guard effectiveFrameGenerationMultiplier > 0 else { return mode.label }
        return "\(mode.label) up to \(effectiveFrameGenerationMultiplier)×"
    }

    /// The Ray Reconstruction model the seat is running, or "In-game" when it applied no override.
    public var rayReconstructionLabel: String {
        guard isRayReconstructionOverridden else { return "In-game" }
        return DlssModelPreset.label(for: overrides.rayReconstructionModel)
    }

    /// The three applied values as one line, shaped like `DlssOverrides.nextSessionRequestSummary`.
    public var currentSessionSummary: String {
        "SR \(superResolutionLabel)  ·  FG \(frameGenerationLabel)  ·  RR \(rayReconstructionLabel)"
    }

    /// A single log line, in the order the features are presented everywhere else.
    public var summary: String {
        "sr=\(isSuperResolutionOverridden ? superResolutionLabel : "off")"
            + " rr=\(isRayReconstructionOverridden ? rayReconstructionLabel : "off")"
            + " fg=\(isFrameGenerationOverridden ? frameGenerationLabel : "off")"
    }

    /// The multiplier the seat is running, or the ceiling the override asked for while it reports none.
    private var effectiveFrameGenerationMultiplier: Int {
        guard activeFrameGenerationMultiplier == 0 else { return activeFrameGenerationMultiplier }
        return overrides.frameGenerationMultiplier
    }
}

/// `DlssFgMode` as the seat reports it. The settings card only offers the two modes NVIDIA's own
/// client offers, so `fixed` is named here rather than widened into the picker.
private enum NvstAppliedFrameGenerationMode: Int {
    case inGame = 0
    case dynamic = 1
    case fixed = 2

    var label: String {
        switch self {
        case .inGame: "In-game"
        case .dynamic: "Dynamic"
        case .fixed: "Fixed"
        }
    }
}

// MARK: - Custom-message parsing

extension NvstDlssStateNotification {
    /// Whether the command carries a seat custom message. Both codes are the client's inbound
    /// carriers; which of the two the seat picks is its business.
    public static func isCustomMessage(_ command: NvstControlCommand) -> Bool {
        command.code == .customMessage || command.code == .customMessageFinal
    }

    /// The `messageType` of a seat custom message, or nil when the payload is not the seat's JSON
    /// envelope. Lets the transport name the custom messages it does not act on.
    public static func messageType(of command: NvstControlCommand) -> String? {
        guard isCustomMessage(command) else { return nil }
        guard let dictionary = jsonDictionary(command.payload) else { return nil }
        return messageType(in: dictionary)
    }

    /// Nil unless the command is a custom message whose `messageType` is `DlssState` and whose
    /// payload carries at least one field of the state.
    public static func parse(_ command: NvstControlCommand) -> NvstDlssStateNotification? {
        guard isCustomMessage(command) else { return nil }
        guard let object = jsonObject(command.payload) else { return nil }
        return parse(envelope: object)
    }

    /// The envelope a custom message arrives in. A payload with no `messageType` is read as the
    /// state itself, because the seat sends both.
    static func parse(envelope value: Any) -> NvstDlssStateNotification? {
        guard let dictionary = jsonDictionary(value) else { return nil }
        guard let type = messageType(in: dictionary) else { return parse(state: dictionary) }
        guard type.caseInsensitiveCompare(messageTypeName) == .orderedSame else { return nil }
        return state(fromEnvelope: dictionary)
    }

    /// The state object itself. Nil unless it carries the override flags, the live multiplier or an
    /// override object, so an unrelated JSON message cannot be read as a state.
    static func parse(state value: Any) -> NvstDlssStateNotification? {
        guard let dictionary = jsonDictionary(value) else { return nil }
        let overrides = overridesDictionary(in: dictionary)
        let superResolution = boolean(in: dictionary, keys: superResolutionFlagKeys)
        let rayReconstruction = boolean(in: dictionary, keys: rayReconstructionFlagKeys)
        let frameGeneration = boolean(in: dictionary, keys: frameGenerationFlagKeys)
        let multiplier = integer(in: dictionary, keys: frameGenerationMultiplierKeys)
        let isRecognizedState = overrides != nil || superResolution != nil || rayReconstruction != nil
            || frameGeneration != nil || multiplier != nil
        guard isRecognizedState else { return nil }
        return NvstDlssStateNotification(
            isSuperResolutionOverridden: superResolution ?? false,
            isRayReconstructionOverridden: rayReconstruction ?? false,
            isFrameGenerationOverridden: frameGeneration ?? false,
            activeFrameGenerationMultiplier: multiplier ?? 0,
            overrides: overrides.map(Overrides.init(dictionary:)) ?? .none
        )
    }

    private static func state(fromEnvelope dictionary: [String: Any]) -> NvstDlssStateNotification? {
        for key in envelopeStateKeys {
            guard let nested = dictionary[key] else { continue }
            guard let state = parse(state: nested) else { continue }
            return state
        }
        return nil
    }

    private static func overridesDictionary(in dictionary: [String: Any]) -> [String: Any]? {
        jsonDictionary(dictionary["overrides"])
    }

    private static func messageType(in dictionary: [String: Any]) -> String? {
        messageTypeKeys.lazy.compactMap { dictionary[$0] as? String }.first { !$0.isEmpty }
    }

    private static func boolean(in dictionary: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            guard let isEnabled = booleanValue(value) else { continue }
            return isEnabled
        }
        return nil
    }

    private static func booleanValue(_ value: Any) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.doubleValue != 0 }
        return nil
    }

    private static func integer(in dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            guard let number = integerValue(value) else { continue }
            return number
        }
        return nil
    }

    private static func integerValue(_ value: Any) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func jsonObject(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    /// A JSON object, the raw payload bytes, or a JSON string carrying one: the seat nests the
    /// state's JSON as a string inside the envelope.
    private static func jsonDictionary(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let data = value as? Data { return jsonObject(data) as? [String: Any] }
        guard let text = value as? String else { return nil }
        guard let object = jsonObject(Data(text.utf8)) else { return nil }
        return object as? [String: Any]
    }

    // Recovered from libBifrost2's `NVB::Streamer::onDLSSStateChange`, reached from
    // `onNvstCustomMessage` on `strcmp(messageType, "DlssState")`.
    private static let messageTypeKeys = ["messageType", "type"]
    private static let envelopeStateKeys = ["data", "messageData", "payload"]
    // Bifrost's own spellings, then the ones the native client's bridge renames them to.
    private static let superResolutionFlagKeys = ["srOverrideActive", "superResolutionActive"]
    private static let rayReconstructionFlagKeys = ["rrOverrideActive", "rayReconstructionActive"]
    private static let frameGenerationFlagKeys = ["fgOverrideActive", "frameGenerationActive"]
    private static let frameGenerationMultiplierKeys = ["fgCurrentMultiplier", "activeFgMultiplier"]
}
