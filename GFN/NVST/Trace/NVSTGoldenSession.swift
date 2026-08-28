import Foundation

public enum NVSTTraceEventKind: String, Codable, Equatable, Sendable {
    case call
    case ret
    case callback
    case marker
}

/// One JSONL event emitted by the native `nvb*` interposition tracer
/// (`NativeNVSTBifrostTracer`). Optional fields carry semantic decodes for the functions
/// whose ABI is verified against the official client; arguments and results are raw
/// register values as lowercase hex strings. Credential material is never recorded.
public struct NVSTTraceEvent: Codable, Equatable, Sendable {
    public let seq: UInt64
    public let tMs: Double
    public let kind: NVSTTraceEventKind
    public let fn: String
    public let tid: UInt64
    public let args: [String]?
    public let results: [String]?
    public let note: String?
    public let authType: Int?
    public let tokenLength: Int?
    public let sessionIDLength: Int?
    public let inputEventType: Int?
    public let featureType: Int?
    public let micSampleRate: Int?
    public let micChannelCount: Int?
    public let micPCMByteCount: Int?
    public let callbackType: Int?
    public let clientEvent: Int?
    public let sessionNotification: Int?
    public let callbackWrapped: Bool?
    public let discovered: Int?
    public let dataPreview: String?
    public let argSymbols: [String]?
    public let resultSymbol: String?
    public let paramsSymbols: [String: String]?
    public let paramsHex: String?
    public let streamSettingsHex: String?

    public init(seq: UInt64,
                tMs: Double,
                kind: NVSTTraceEventKind,
                fn: String,
                tid: UInt64,
                args: [String]? = nil,
                results: [String]? = nil,
                note: String? = nil,
                authType: Int? = nil,
                tokenLength: Int? = nil,
                sessionIDLength: Int? = nil,
                inputEventType: Int? = nil,
                featureType: Int? = nil,
                micSampleRate: Int? = nil,
                micChannelCount: Int? = nil,
                micPCMByteCount: Int? = nil,
                callbackType: Int? = nil,
                clientEvent: Int? = nil,
                sessionNotification: Int? = nil,
                callbackWrapped: Bool? = nil,
                discovered: Int? = nil,
                dataPreview: String? = nil,
                argSymbols: [String]? = nil,
                resultSymbol: String? = nil,
                paramsSymbols: [String: String]? = nil,
                paramsHex: String? = nil,
                streamSettingsHex: String? = nil) {
        self.seq = seq
        self.tMs = tMs
        self.kind = kind
        self.fn = fn
        self.tid = tid
        self.args = args
        self.results = results
        self.note = note
        self.authType = authType
        self.tokenLength = tokenLength
        self.sessionIDLength = sessionIDLength
        self.inputEventType = inputEventType
        self.featureType = featureType
        self.micSampleRate = micSampleRate
        self.micChannelCount = micChannelCount
        self.micPCMByteCount = micPCMByteCount
        self.callbackType = callbackType
        self.clientEvent = clientEvent
        self.sessionNotification = sessionNotification
        self.callbackWrapped = callbackWrapped
        self.discovered = discovered
        self.dataPreview = dataPreview
        self.argSymbols = argSymbols
        self.resultSymbol = resultSymbol
        self.paramsSymbols = paramsSymbols
        self.paramsHex = paramsHex
        self.streamSettingsHex = streamSettingsHex
    }
}

public enum NVSTGoldenSessionParseError: LocalizedError, Equatable, Sendable {
    case malformedLine(line: Int, content: String)

    public var errorDescription: String? {
        switch self {
        case .malformedLine(let line, let content):
            "Malformed golden-session event at line \(line): \(content)"
        }
    }
}

/// A recorded `nvb*` session capture. Fixtures and live captures share this model so
/// deterministic tests can assert call ordering against the same structure that the
/// authenticated hardware gate produces.
public struct NVSTGoldenSession: Equatable, Sendable {
    public let events: [NVSTTraceEvent]

    public init(events: [NVSTTraceEvent]) {
        self.events = events
    }

    public init(jsonl: String) throws {
        let decoder = JSONDecoder()
        var parsed: [NVSTTraceEvent] = []
        var lineNumber = 0
        for rawLine in jsonl.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8), let event = try? decoder.decode(NVSTTraceEvent.self, from: data) else {
                throw NVSTGoldenSessionParseError.malformedLine(line: lineNumber, content: String(line.prefix(120)))
            }
            parsed.append(event)
        }
        events = parsed
    }

    /// Ordered names of `nvb*` calls (kind == .call), excluding returns, callbacks, and markers.
    public var callSequence: [String] {
        events.filter { $0.kind == .call }.map(\.fn)
    }

    public var callbackEvents: [NVSTTraceEvent] {
        events.filter { $0.kind == .callback }
    }

    public func callCount(_ function: String) -> Int {
        events.reduce(0) { $0 + ($1.kind == .call && $1.fn == function ? 1 : 0) }
    }

    public func firstCallIndex(_ function: String) -> Int? {
        callSequence.firstIndex(of: function)
    }

    public func containsOrderedSubsequence(_ names: [String]) -> Bool {
        let sequence = callSequence
        var position = sequence.startIndex
        for name in names {
            guard let match = sequence[position...].firstIndex(of: name) else { return false }
            position = sequence.index(after: match)
        }
        return true
    }

    /// The launch handshake of a cloud-allocated native session, verified against a real
    /// capture (docs/NVST/NativeNVSTProtocolObservations.md): GFN allocates the session via
    /// the web API, so the native client resumes it rather than calling `nvbStartSession`.
    public static let expectedLaunchSequence = [
        "nvbCreateClient",
        "nvbRegisterCallback",
        "nvbInitializeClient",
        "nvbSetAuthInfo",
        "nvbResumeSession",
        "nvbStartStreaming",
    ]

    /// The verified teardown sequence of a user-stopped session. Notification 59
    /// (`NVB_SN_PAUSED_BY_USER`) leaves the cloud session resumable.
    public static let expectedTeardownSequence = [
        "nvbStopStreaming",
        "nvbStopSession",
        "nvbDestroyClient",
    ]

    /// Bifrost readiness gate: client event 0x0e (SessionNotification) with notification 1
    /// (StreamerConnected) delivered on callback type 2.
    public func reachedStreamerConnectedGate() -> Bool {
        callbackEvents.contains { $0.callbackType == 2 && $0.clientEvent == 14 && $0.sessionNotification == 1 }
    }
}
