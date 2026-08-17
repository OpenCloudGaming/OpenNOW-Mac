import AppKit
import Foundation
import Testing
@testable import MacForceNow

@Suite(.serialized)
struct NVSTNativeRuntimeTests {

@Test func nvstNativeRuntimeLoadsVendoredBifrostSymbols() throws {
    let frameworksDirectory = repoRoot().appendingPathComponent("vendor/gfn-runtime/Frameworks", isDirectory: true)

    let runtime = try NVSTNativeRuntime(frameworksDirectory: frameworksDirectory)

    #expect(runtime.status.libraryURL.lastPathComponent == "libBifrost2.dylib")
    #expect(runtime.status.bundledArtifactURLs.map(\.lastPathComponent).contains("libGeronimo.dylib"))
    #expect(runtime.status.bundledArtifactURLs.map(\.lastPathComponent).contains("libGsAudioWebRTC.dylib"))
    #expect(runtime.status.bundledArtifactURLs.contains { $0.path.hasSuffix("SDL2.framework/Versions/A/SDL2") })
    #expect(runtime.status.resolvedSymbols == NVSTNativeSymbol.allCases.map(\.rawValue))
    for symbol in NVSTNativeSymbol.allCases {
        #expect(runtime.symbolAddress(symbol) != 0)
    }
}

@Test func nvstNativeRuntimeReportsMissingBundledLibrary() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macforce-now-nvst-runtime-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let result = NVSTNativeRuntime.availability(frameworksDirectory: directory)

    if case let .failure(error) = result {
        #expect(error == .missingLibrary(directory.appendingPathComponent("libBifrost2.dylib").path))
    } else {
        Issue.record("Expected missing library failure")
    }
}

@Test func nvstNativeBridgeProbeUsesVendoredRuntime() throws {
    let frameworksDirectory = repoRoot().appendingPathComponent("vendor/gfn-runtime/Frameworks", isDirectory: true)
    let result = NVSTNativeBridge.probe(configuration: NVSTNativeBridgeConfiguration(frameworksDirectory: frameworksDirectory))

    if case let .success(status) = result {
        #expect(status.runtimeAvailable)
        #expect(status.libraryURL.lastPathComponent == "libBifrost2.dylib")
        #expect(status.bundledArtifactURLs.count >= 4)
        #expect(status.resolvedSymbols.contains("nvstCreateClient"))
        #expect(status.resolvedSymbols.contains("nvstConnectToServer"))
    } else {
        Issue.record("Expected bundled NVST runtime probe to succeed")
    }
}

@Test func nvstNativeBridgeReadsVersionAndPreparesSignalingEndpoint() throws {
    let bridge = try vendoredBridge()

    let endpoint = try bridge.prepareSignalingServerEndpoint(host: "stream.example.test", port: 443)

    #expect(bridge.runtimeVersion() == "14")
    #expect(endpoint.host == "stream.example.test")
    #expect(endpoint.port == 443)
    #expect(endpoint.transferProtocol == 5)
    #expect(endpoint.portUsage == 5)
}

@Test func nvstNativeBridgeInitializesVideoAndAudioStreamConfigs() throws {
    let bridge = try vendoredBridge()

    let video = try bridge.initializeStreamConfig(mediaType: .video, direction: .receiver)
    let audio = try bridge.initializeStreamConfig(mediaType: .audio, direction: .receiver)

    #expect(video.storedMediaType == NVSTNativeStreamMediaType.video.rawValue)
    #expect(audio.storedMediaType == NVSTNativeStreamMediaType.audio.rawValue)
    #expect(video.nonZeroByteCount > 0)
    #expect(audio.nonZeroByteCount > 0)
}

@Test func nvstNativeBridgeRejectsInvalidSignalingEndpoint() throws {
    let bridge = try vendoredBridge()

    #expect(throws: NVSTNativeBridgeError.invalidEndpoint("Native NVST signaling endpoint is missing a host.")) {
        _ = try bridge.prepareSignalingServerEndpoint(host: " ", port: 443)
    }
}

@Test @MainActor func nvstGeronimoCreatesWithVendoredGridAppCallbackABI() {
    guard ProcessInfo.processInfo.environment["ENABLE_NVST_HARDWARE_TESTS"] == "1" else {
        return
    }

    let frameworksDirectory = repoRoot().appendingPathComponent("vendor/gfn-runtime/Frameworks", isDirectory: true)
    var errorBuffer = [CChar](repeating: 0, count: 1024)
    let session = frameworksDirectory.path.withCString { frameworksPath in
        errorBuffer.withUnsafeMutableBufferPointer { buffer in
            MacForceNowTestNativeNVSTGeronimoCreate(frameworksPath, buffer.baseAddress, buffer.count)
        }
    }
    guard let session else {
        _ = errorBuffer.withUnsafeBufferPointer { buffer in
            Issue.record("Geronimo creation failed: \(buffer.baseAddress.map { String(cString: $0) } ?? "unknown error")")
        }
        return
    }

    let resultName = MacForceNowTestNativeNVSTGeronimoResultCodeName(session, 302)
    #expect(resultName.map { String(cString: $0) } == "NVB_R_SESSION_LIMIT_REACHED")

    var surface: NSView? = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    weak let retainedSurface = surface
    let result = errorBuffer.withUnsafeMutableBufferPointer { buffer in
        MacForceNowTestNativeNVSTGeronimoSetVideoSurface(
            session,
            surface.map { Unmanaged.passUnretained($0).toOpaque() },
            buffer.baseAddress,
            buffer.count
        )
    }
    #expect(result == 0)
    surface = nil
    #expect(retainedSurface != nil)

    let microphoneResult = errorBuffer.withUnsafeMutableBufferPointer { buffer in
        MacForceNowTestNativeNVSTGeronimoSetMicrophoneEnabled(session, 1, buffer.baseAddress, buffer.count)
    }
    #expect(microphoneResult == -3)

    MacForceNowTestNativeNVSTGeronimoDestroy(session)
    #expect(retainedSurface == nil)
}

@Test func nvstGeronimoConversionRejectsUnsupportedServerAndAuthTypes() {
    #expect((1...5).map { MacForceNowNativeNVSTGeronimoConvertServerType(Int32($0)) } == [0, 1, 2, 3, 4])
    #expect(MacForceNowNativeNVSTGeronimoConvertServerType(1001) == 0x33)
    #expect(MacForceNowNativeNVSTGeronimoConvertServerType(0) == -1)
    #expect(MacForceNowNativeNVSTGeronimoConvertServerType(52) == -1)
    #expect(convertedAuthTokenType("7") == 7)
    #expect(convertedAuthTokenType("jarvis") == 7)
    #expect(convertedAuthTokenType("JWT") == 8)
    #expect(convertedAuthTokenType("jwt-gfn") == 9)
    #expect(convertedAuthTokenType("unsupported") == -1)
    #expect(MacForceNowNativeNVSTGeronimoConvertAuthTokenType(nil) == -1)
}

@Test func nvstGeronimoEndpointParsingPreservesSessionPortAndIPv6() {
    #expect(inspectedEndpoint("stream.example.test", fallbackPort: 47984) == ParsedNativeEndpoint(host: "stream.example.test", port: 47984))
    #expect(inspectedEndpoint("stream.example.test:47989", fallbackPort: 47984) == ParsedNativeEndpoint(host: "stream.example.test", port: 47989))
    #expect(inspectedEndpoint("[2001:db8::1]", fallbackPort: 47984) == ParsedNativeEndpoint(host: "2001:db8::1", port: 47984))
    #expect(inspectedEndpoint("[2001:db8::1]:47989", fallbackPort: 47984) == ParsedNativeEndpoint(host: "2001:db8::1", port: 47989))
}

@Test func nvstGeronimoMicrophoneControlRejectsMissingSession() {
    var errorBuffer = [CChar](repeating: 0, count: 256)
    let result = errorBuffer.withUnsafeMutableBufferPointer { buffer in
        MacForceNowTestNativeNVSTGeronimoSetMicrophoneEnabled(nil, 1, buffer.baseAddress, buffer.count)
    }

    #expect(result == -1)
}

}

private func vendoredBridge() throws -> NVSTNativeBridge {
    let frameworksDirectory = repoRoot().appendingPathComponent("vendor/gfn-runtime/Frameworks", isDirectory: true)
    return try NVSTNativeBridge(configuration: NVSTNativeBridgeConfiguration(frameworksDirectory: frameworksDirectory))
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func convertedAuthTokenType(_ tokenType: String) -> Int32 {
    tokenType.withCString { MacForceNowNativeNVSTGeronimoConvertAuthTokenType($0) }
}

private struct ParsedNativeEndpoint: Equatable {
    let host: String
    let port: UInt16
}

private func inspectedEndpoint(_ address: String, fallbackPort: UInt16) -> ParsedNativeEndpoint? {
    var host = [CChar](repeating: 0, count: 256)
    var port: UInt16 = 0
    let result = address.withCString { addressPointer in
        host.withUnsafeMutableBufferPointer { hostBuffer in
            MacForceNowNativeNVSTGeronimoInspectEndpoint(addressPointer, fallbackPort, hostBuffer.baseAddress, hostBuffer.count, &port)
        }
    }
    guard result == 0 else { return nil }
    return host.withUnsafeBufferPointer { buffer in
        buffer.baseAddress.map { ParsedNativeEndpoint(host: String(cString: $0), port: port) }
    }
}

@_silgen_name("MacForceNowNativeNVSTGeronimoConvertServerType")
private func MacForceNowNativeNVSTGeronimoConvertServerType(_ serverType: Int32) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoConvertAuthTokenType")
private func MacForceNowNativeNVSTGeronimoConvertAuthTokenType(_ tokenType: UnsafePointer<CChar>?) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoInspectEndpoint")
private func MacForceNowNativeNVSTGeronimoInspectEndpoint(_ address: UnsafePointer<CChar>?, _ fallbackPort: UInt16, _ hostBuffer: UnsafeMutablePointer<CChar>?, _ hostBufferLength: Int, _ port: UnsafeMutablePointer<UInt16>?) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoCreate")
private func MacForceNowTestNativeNVSTGeronimoCreate(_ frameworksPath: UnsafePointer<CChar>?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> UnsafeMutableRawPointer?

@_silgen_name("MacForceNowNativeNVSTGeronimoDestroy")
private func MacForceNowTestNativeNVSTGeronimoDestroy(_ session: UnsafeMutableRawPointer?)

@_silgen_name("MacForceNowNativeNVSTGeronimoSetVideoSurface")
private func MacForceNowTestNativeNVSTGeronimoSetVideoSurface(_ session: UnsafeMutableRawPointer?, _ nativeHandle: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoSetMicrophoneEnabled")
private func MacForceNowTestNativeNVSTGeronimoSetMicrophoneEnabled(_ session: UnsafeMutableRawPointer?, _ enabled: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoResultCodeName")
private func MacForceNowTestNativeNVSTGeronimoResultCodeName(_ session: UnsafeMutableRawPointer?, _ resultCode: Int32) -> UnsafePointer<CChar>?
