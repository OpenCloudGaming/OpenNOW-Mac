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
    public let resolvedSymbols: [String]
    public let runtimeAvailable: Bool

    public init(libraryURL: URL, resolvedSymbols: [String], runtimeAvailable: Bool) {
        self.libraryURL = libraryURL
        self.resolvedSymbols = resolvedSymbols
        self.runtimeAvailable = runtimeAvailable
    }
}

public enum NVSTNativeBridgeError: LocalizedError, Equatable, Sendable {
    case runtimeUnavailable(NVSTNativeRuntimeLoadError)

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let error):
            error.errorDescription
        }
    }
}

public final class NVSTNativeBridge: @unchecked Sendable {
    public typealias NvstResultToStringFunction = @convention(c) (Int32) -> UnsafePointer<CChar>?

    private let runtime: NVSTNativeRuntime
    public let status: NVSTNativeBridgeStatus

    public init(configuration: NVSTNativeBridgeConfiguration = NVSTNativeBridgeConfiguration()) throws {
        do {
            runtime = try NVSTNativeRuntime(frameworksDirectory: configuration.frameworksDirectory, libraryName: configuration.libraryName)
            status = NVSTNativeBridgeStatus(libraryURL: runtime.status.libraryURL, resolvedSymbols: runtime.status.resolvedSymbols, runtimeAvailable: true)
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

    public func symbolAddress(_ symbol: NVSTNativeSymbol) -> UInt {
        runtime.symbolAddress(symbol)
    }
}
