import Darwin
import Foundation

public enum NVSTNativeSymbol: String, CaseIterable, Sendable {
    case getVersion = "nvstGetVersion"
    case resultToString = "nvstResultToString"
    case createClient = "nvstCreateClient"
    case destroyClient = "nvstDestroyClient"
    case prepareSignalingServerEndpoint = "nvstPrepareSignalingServerEndpoint"
    case setSignalingHeader = "nvstSetSignalingHeader"
    case clearSignalingHeaders = "nvstClearSignalingHeaders"
    case connectToServer = "nvstConnectToServer"
    case disconnectFromServer = "nvstDisconnectFromServer"
    case initializeStreamConfig = "nvstInitializeStreamConfig"
    case createStream = "nvstCreateStream"
    case destroyStream = "nvstDestroyStream"
    case controlStreaming = "nvstControlStreaming"
    case pushStreamData = "nvstPushStreamData"
    case getStats = "nvstGetStats"
}

public enum NVSTNativeRuntimeLoadError: LocalizedError, Equatable, Sendable {
    case missingFrameworksDirectory(String)
    case missingLibrary(String)
    case loadFailed(path: String, reason: String)
    case missingSymbol(String)

    public var errorDescription: String? {
        switch self {
        case .missingFrameworksDirectory(let path):
            "Bundled NVST runtime directory was not found: \(path)"
        case .missingLibrary(let path):
            "Bundled NVST runtime library was not found: \(path)"
        case .loadFailed(let path, let reason):
            "Bundled NVST runtime failed to load: \(path). \(reason)"
        case .missingSymbol(let symbol):
            "Bundled NVST runtime is missing required symbol: \(symbol)"
        }
    }
}

public struct NVSTNativeRuntimeStatus: Equatable, Sendable {
    public let libraryURL: URL
    public let resolvedSymbols: [String]

    public init(libraryURL: URL, resolvedSymbols: [String]) {
        self.libraryURL = libraryURL
        self.resolvedSymbols = resolvedSymbols
    }
}

public final class NVSTNativeRuntime: @unchecked Sendable {
    public static let bundledLibraryName = "libBifrost2.dylib"

    private let handle: UnsafeMutableRawPointer
    private let symbols: [NVSTNativeSymbol: UnsafeMutableRawPointer]
    public let status: NVSTNativeRuntimeStatus

    public convenience init() throws {
        try self.init(frameworksDirectory: Bundle.main.privateFrameworksURL)
    }

    public init(frameworksDirectory: URL?, libraryName: String = NVSTNativeRuntime.bundledLibraryName) throws {
        let directory = try Self.validatedFrameworksDirectory(frameworksDirectory)
        let libraryURL = directory.appendingPathComponent(libraryName, isDirectory: false)
        guard FileManager.default.isReadableFile(atPath: libraryURL.path) else {
            throw NVSTNativeRuntimeLoadError.missingLibrary(libraryURL.path)
        }
        guard let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw NVSTNativeRuntimeLoadError.loadFailed(path: libraryURL.path, reason: Self.currentDLError())
        }

        var resolvedSymbols: [NVSTNativeSymbol: UnsafeMutableRawPointer] = [:]
        do {
            for symbol in NVSTNativeSymbol.allCases {
                guard let address = dlsym(handle, symbol.rawValue) else {
                    throw NVSTNativeRuntimeLoadError.missingSymbol(symbol.rawValue)
                }
                resolvedSymbols[symbol] = address
            }
        } catch {
            dlclose(handle)
            throw error
        }

        self.handle = handle
        self.symbols = resolvedSymbols
        status = NVSTNativeRuntimeStatus(libraryURL: libraryURL, resolvedSymbols: NVSTNativeSymbol.allCases.map(\.rawValue))
    }

    deinit {
        dlclose(handle)
    }

    public static func availability(frameworksDirectory: URL? = Bundle.main.privateFrameworksURL) -> Result<NVSTNativeRuntimeStatus, NVSTNativeRuntimeLoadError> {
        do {
            let runtime = try NVSTNativeRuntime(frameworksDirectory: frameworksDirectory)
            return .success(runtime.status)
        } catch let error as NVSTNativeRuntimeLoadError {
            return .failure(error)
        } catch {
            return .failure(.loadFailed(path: frameworksDirectory?.path ?? "", reason: error.localizedDescription))
        }
    }

    public func symbolAddress(_ symbol: NVSTNativeSymbol) -> UInt {
        guard let address = symbols[symbol] else { return 0 }
        return UInt(bitPattern: address)
    }

    public func rawSymbol(_ symbol: NVSTNativeSymbol) -> UnsafeMutableRawPointer {
        guard let address = symbols[symbol] else { preconditionFailure("NVST symbol was not resolved: \(symbol.rawValue)") }
        return address
    }

    private static func validatedFrameworksDirectory(_ directory: URL?) throws -> URL {
        guard let directory else {
            throw NVSTNativeRuntimeLoadError.missingFrameworksDirectory("<nil>")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NVSTNativeRuntimeLoadError.missingFrameworksDirectory(directory.path)
        }
        return directory
    }

    private static func currentDLError() -> String {
        guard let message = dlerror() else { return "Unknown dynamic loader error." }
        return String(cString: message)
    }
}
