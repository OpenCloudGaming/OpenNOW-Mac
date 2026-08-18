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
    case artifactIdentityMismatch(path: String, expected: String, actual: String?)

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
        case .artifactIdentityMismatch(let path, let expected, let actual):
            "Bundled NVST runtime identity mismatch: \(path). Expected \(expected), received \(actual ?? "no Mach-O UUID")."
        }
    }
}

public struct NVSTNativeRuntimeStatus: Equatable, Sendable {
    public let libraryURL: URL
    public let bundledArtifactURLs: [URL]
    public let resolvedSymbols: [String]
    public let artifactUUIDs: [String: String]

    public init(libraryURL: URL, bundledArtifactURLs: [URL], resolvedSymbols: [String], artifactUUIDs: [String: String]) {
        self.libraryURL = libraryURL
        self.bundledArtifactURLs = bundledArtifactURLs
        self.resolvedSymbols = resolvedSymbols
        self.artifactUUIDs = artifactUUIDs
    }
}

public final class NVSTNativeRuntime: @unchecked Sendable {
    public static let bundledLibraryName = "libBifrost2.dylib"
    public static let bundledAuxiliaryArtifactPaths = [
        "libGeronimo.dylib",
        "libGsAudioWebRTC.dylib",
        "SDL2.framework/Versions/A/SDL2",
    ]
    private static let verifiedArtifactUUIDs: [String: String] = [
#if arch(arm64)
        "libBifrost2.dylib": "A80FA3C0-2522-3E14-B20B-D871F886B1AC",
        "libGeronimo.dylib": "0F367B2B-77D9-319B-A183-E9F27469CFE5",
        "libGsAudioWebRTC.dylib": "36BB135F-70E7-336C-A8B3-B070055E6595",
        "SDL2.framework/Versions/A/SDL2": "4902919F-6CCE-3FE0-BCC3-0EFB63BDBB8E",
#elseif arch(x86_64)
        "libBifrost2.dylib": "F8A3AD93-1D5D-3072-99ED-B17493CF1819",
        "libGeronimo.dylib": "37D47DFE-6018-32C2-85E9-989E6AA509E2",
        "libGsAudioWebRTC.dylib": "148B2860-6540-31AF-BF87-5E28FD9282A7",
        "SDL2.framework/Versions/A/SDL2": "8347A2BA-9EEF-3D72-B031-CEF271260D71",
#endif
    ]

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
        let auxiliaryArtifactURLs = try Self.validatedAuxiliaryArtifacts(in: directory)
        let artifactURLs = [libraryURL] + auxiliaryArtifactURLs
        let artifactUUIDs = try Self.validatedArtifactUUIDs(artifactURLs, relativeTo: directory)
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
        status = NVSTNativeRuntimeStatus(libraryURL: libraryURL, bundledArtifactURLs: artifactURLs, resolvedSymbols: NVSTNativeSymbol.allCases.map(\.rawValue), artifactUUIDs: artifactUUIDs)
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

    private static func validatedAuxiliaryArtifacts(in directory: URL) throws -> [URL] {
        try bundledAuxiliaryArtifactPaths.map { relativePath in
            let url = directory.appendingPathComponent(relativePath, isDirectory: false)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw NVSTNativeRuntimeLoadError.missingLibrary(url.path)
            }
            return url
        }
    }

    private static func validatedArtifactUUIDs(_ urls: [URL], relativeTo directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for url in urls {
            let relativePath = String(url.path.dropFirst(directory.path.count + 1))
            guard let expected = verifiedArtifactUUIDs[relativePath] else {
                throw NVSTNativeRuntimeLoadError.artifactIdentityMismatch(path: relativePath, expected: "manifest entry", actual: nil)
            }
            let actual = try machoUUID(at: url)
            guard actual == expected else {
                throw NVSTNativeRuntimeLoadError.artifactIdentityMismatch(path: relativePath, expected: expected, actual: actual)
            }
            result[relativePath] = actual
        }
        return result
    }

    private static func machoUUID(at url: URL) throws -> String? {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw NVSTNativeRuntimeLoadError.loadFailed(path: url.path, reason: error.localizedDescription)
        }
        let sliceOffset: Int
        if uint32(data, at: 0, endian: .big) == 0xcafebabe {
            guard let architectureCount = uint32(data, at: 4, endian: .big) else { return nil }
#if arch(arm64)
            let desiredCPUType: UInt32 = 0x0100000c
#elseif arch(x86_64)
            let desiredCPUType: UInt32 = 0x01000007
#else
            return nil
#endif
            var selectedOffset: Int?
            for index in 0..<Int(architectureCount) {
                let architectureOffset = 8 + index * 20
                guard let cpuType = uint32(data, at: architectureOffset, endian: .big),
                      let offset = uint32(data, at: architectureOffset + 8, endian: .big) else { return nil }
                if cpuType == desiredCPUType {
                    selectedOffset = Int(offset)
                    break
                }
            }
            guard let selectedOffset else { return nil }
            sliceOffset = selectedOffset
        } else {
            sliceOffset = 0
        }
        guard uint32(data, at: sliceOffset, endian: .little) == 0xfeedfacf,
              let commandCount = uint32(data, at: sliceOffset + 16, endian: .little) else { return nil }
        var commandOffset = sliceOffset + 32
        for _ in 0..<commandCount {
            guard let command = uint32(data, at: commandOffset, endian: .little),
                  let commandSize = uint32(data, at: commandOffset + 4, endian: .little),
                  commandSize >= 8 else { return nil }
            if command == 0x1b {
                let uuidOffset = commandOffset + 8
                guard uuidOffset + 16 <= data.count else { return nil }
                return formattedUUID(Array(data[uuidOffset..<(uuidOffset + 16)]))
            }
            commandOffset += Int(commandSize)
            if commandOffset > data.count { return nil }
        }
        return nil
    }

    private enum ByteOrder {
        case big
        case little
    }

    private static func uint32(_ data: Data, at offset: Int, endian: ByteOrder) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let bytes = data[offset..<(offset + 4)]
        switch endian {
        case .big:
            return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
        case .little:
            return bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
    }

    private static func formattedUUID(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }
        let hexadecimal = bytes.map { String(format: "%02X", $0) }
        return hexadecimal[0..<4].joined() + "-" +
            hexadecimal[4..<6].joined() + "-" +
            hexadecimal[6..<8].joined() + "-" +
            hexadecimal[8..<10].joined() + "-" +
            hexadecimal[10..<16].joined()
    }

    private static func currentDLError() -> String {
        guard let message = dlerror() else { return "Unknown dynamic loader error." }
        return String(cString: message)
    }
}
