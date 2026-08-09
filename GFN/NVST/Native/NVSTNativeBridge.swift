import Foundation

public struct NVSTNativeBridgeConfiguration: Equatable, Sendable {
    public var frameworksDirectory: URL?
    public var libraryName: String

    public init(frameworksDirectory: URL? = Bundle.main.privateFrameworksURL,
                libraryName: String = NVSTNativeRuntime.bundledLibraryName) {
        self.frameworksDirectory = frameworksDirectory
        self.libraryName = libraryName
    }
}

public struct NVSTNativeBridgeStatus: Equatable, Sendable {
    public let libraryURL: URL
    public let bundledArtifactURLs: [URL]
    public let resolvedSymbols: [String]
    public let runtimeAvailable: Bool

    public init(libraryURL: URL, bundledArtifactURLs: [URL], resolvedSymbols: [String], runtimeAvailable: Bool) {
        self.libraryURL = libraryURL
        self.bundledArtifactURLs = bundledArtifactURLs
        self.resolvedSymbols = resolvedSymbols
        self.runtimeAvailable = runtimeAvailable
    }
}

public struct NVSTPreparedSignalingEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let transferProtocol: UInt32
    public let portUsage: UInt32

    public init(host: String, port: UInt16, transferProtocol: UInt32, portUsage: UInt32) {
        self.host = host
        self.port = port
        self.transferProtocol = transferProtocol
        self.portUsage = portUsage
    }
}

public enum NVSTNativeStreamMediaType: UInt32, Equatable, Sendable {
    case video = 1
    case audio = 2
    case input = 4
    case microphone = 5
}

public enum NVSTNativeStreamDirection: UInt32, Equatable, Sendable {
    case sender = 0
    case receiver = 1
}

public struct NVSTInitializedStreamConfig: Equatable, Sendable {
    public let mediaType: NVSTNativeStreamMediaType
    public let direction: NVSTNativeStreamDirection
    public let storedMediaType: UInt32
    public let nonZeroByteCount: Int

    public init(mediaType: NVSTNativeStreamMediaType, direction: NVSTNativeStreamDirection, storedMediaType: UInt32, nonZeroByteCount: Int) {
        self.mediaType = mediaType
        self.direction = direction
        self.storedMediaType = storedMediaType
        self.nonZeroByteCount = nonZeroByteCount
    }
}

public enum NVSTNativeBridgeError: LocalizedError, Equatable, Sendable {
    case runtimeUnavailable(NVSTNativeRuntimeLoadError)
    case invalidEndpoint(String)
    case nativeCallFailed(function: String, code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let error):
            error.errorDescription
        case .invalidEndpoint(let message):
            message
        case .nativeCallFailed(let function, let code, let message):
            "\(function) failed with NVST result \(code): \(message)"
        }
    }
}

public final class NVSTNativeBridge: @unchecked Sendable {
    public typealias NvstGetVersionFunction = @convention(c) () -> UnsafePointer<CChar>?
    public typealias NvstResultToStringFunction = @convention(c) (Int32) -> UnsafePointer<CChar>?
    public typealias NvstPrepareSignalingServerEndpointFunction = @convention(c) (UnsafePointer<CChar>, UInt16, UnsafeMutableRawPointer) -> Int32
    public typealias NvstInitializeStreamConfigFunction = @convention(c) (UInt32, UInt32, UnsafeMutableRawPointer) -> Int32

    private static let serverEndpointByteCount = 32
    private static let streamConfigProbeByteCount = 4096

    private let runtime: NVSTNativeRuntime
    public let status: NVSTNativeBridgeStatus

    public init(configuration: NVSTNativeBridgeConfiguration = NVSTNativeBridgeConfiguration()) throws {
        do {
            runtime = try NVSTNativeRuntime(frameworksDirectory: configuration.frameworksDirectory, libraryName: configuration.libraryName)
            status = NVSTNativeBridgeStatus(libraryURL: runtime.status.libraryURL, bundledArtifactURLs: runtime.status.bundledArtifactURLs, resolvedSymbols: runtime.status.resolvedSymbols, runtimeAvailable: true)
        } catch let error as NVSTNativeRuntimeLoadError {
            throw NVSTNativeBridgeError.runtimeUnavailable(error)
        }
    }

    public static func probe(configuration: NVSTNativeBridgeConfiguration = NVSTNativeBridgeConfiguration()) -> Result<NVSTNativeBridgeStatus, NVSTNativeBridgeError> {
        do {
            let bridge = try NVSTNativeBridge(configuration: configuration)
            return .success(bridge.status)
        } catch let error as NVSTNativeBridgeError {
            return .failure(error)
        } catch let error as NVSTNativeRuntimeLoadError {
            return .failure(.runtimeUnavailable(error))
        } catch {
            let runtimeError = NVSTNativeRuntimeLoadError.loadFailed(path: configuration.frameworksDirectory?.path ?? "", reason: error.localizedDescription)
            return .failure(.runtimeUnavailable(runtimeError))
        }
    }

    public func resultDescription(code: Int32) -> String {
        let function = unsafeBitCast(runtime.rawSymbol(.resultToString), to: NvstResultToStringFunction.self)
        guard let text = function(code) else { return "NVST result \(code)" }
        let message = String(cString: text)
        return message.isEmpty ? "NVST result \(code)" : message
    }

    public func runtimeVersion() -> String {
        let function = unsafeBitCast(runtime.rawSymbol(.getVersion), to: NvstGetVersionFunction.self)
        guard let version = function() else { return "" }
        return String(cString: version)
    }

    public func prepareSignalingServerEndpoint(host: String, port: UInt16) throws -> NVSTPreparedSignalingEndpoint {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else {
            throw NVSTNativeBridgeError.invalidEndpoint("Native NVST signaling endpoint is missing a host.")
        }

        let function = unsafeBitCast(runtime.rawSymbol(.prepareSignalingServerEndpoint), to: NvstPrepareSignalingServerEndpointFunction.self)
        return try normalizedHost.withCString { hostPointer in
            let endpoint = UnsafeMutableRawPointer.allocate(byteCount: Self.serverEndpointByteCount, alignment: MemoryLayout<UInt64>.alignment)
            defer { endpoint.deallocate() }
            endpoint.initializeMemory(as: UInt8.self, repeating: 0, count: Self.serverEndpointByteCount)

            let result = function(hostPointer, port, endpoint)
            guard result == 0 else {
                throw NVSTNativeBridgeError.nativeCallFailed(function: NVSTNativeSymbol.prepareSignalingServerEndpoint.rawValue, code: result, message: resultDescription(code: result))
            }
            let preparedHostPointer = endpoint.load(as: UInt.self)
            guard preparedHostPointer != 0 else {
                throw NVSTNativeBridgeError.invalidEndpoint("Native NVST did not preserve the signaling endpoint host pointer.")
            }
            let preparedPort = endpoint.advanced(by: 8).load(as: UInt16.self)
            let transferProtocol = endpoint.advanced(by: 12).load(as: UInt32.self)
            let portUsage = endpoint.advanced(by: 16).load(as: UInt32.self)
            return NVSTPreparedSignalingEndpoint(host: normalizedHost, port: preparedPort, transferProtocol: transferProtocol, portUsage: portUsage)
        }
    }

    public func initializeStreamConfig(mediaType: NVSTNativeStreamMediaType, direction: NVSTNativeStreamDirection) throws -> NVSTInitializedStreamConfig {
        let function = unsafeBitCast(runtime.rawSymbol(.initializeStreamConfig), to: NvstInitializeStreamConfigFunction.self)
        let streamConfig = UnsafeMutableRawPointer.allocate(byteCount: Self.streamConfigProbeByteCount, alignment: MemoryLayout<UInt64>.alignment)
        defer { streamConfig.deallocate() }
        streamConfig.initializeMemory(as: UInt8.self, repeating: 0, count: Self.streamConfigProbeByteCount)

        let result = function(mediaType.rawValue, direction.rawValue, streamConfig)
        guard result == 0 else {
            throw NVSTNativeBridgeError.nativeCallFailed(function: NVSTNativeSymbol.initializeStreamConfig.rawValue, code: result, message: resultDescription(code: result))
        }
        let storedMediaType = streamConfig.load(as: UInt32.self)
        let bytes = UnsafeBufferPointer(start: streamConfig.assumingMemoryBound(to: UInt8.self), count: Self.streamConfigProbeByteCount)
        return NVSTInitializedStreamConfig(mediaType: mediaType, direction: direction, storedMediaType: storedMediaType, nonZeroByteCount: bytes.reduce(0) { $0 + ($1 == 0 ? 0 : 1) })
    }

    public func symbolAddress(_ symbol: NVSTNativeSymbol) -> UInt {
        runtime.symbolAddress(symbol)
    }
}
