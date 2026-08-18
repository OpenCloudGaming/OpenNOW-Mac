import AppKit
import AppKit
import Foundation
import Testing
@testable import OpenNOW

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
    #expect(runtime.status.artifactUUIDs.count == 4)
    #expect(runtime.status.artifactUUIDs["libGeronimo.dylib"] == "0F367B2B-77D9-319B-A183-E9F27469CFE5")
    for symbol in NVSTNativeSymbol.allCases {
        #expect(runtime.symbolAddress(symbol) != 0)
    }
}

@Test func nvstNativeRuntimeReportsMissingBundledLibrary() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opennow-nvst-runtime-\(UUID().uuidString)", isDirectory: true)
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
    let frameworksDirectory = repoRoot().appendingPathComponent("vendor/gfn-runtime/Frameworks", isDirectory: true)
    var errorBuffer = [CChar](repeating: 0, count: 1024)
    let session = frameworksDirectory.path.withCString { frameworksPath in
        errorBuffer.withUnsafeMutableBufferPointer { buffer in
            OpenNOWTestNativeNVSTGeronimoCreate(frameworksPath, buffer.baseAddress, buffer.count)
        }
    }
    guard let session else {
        _ = errorBuffer.withUnsafeBufferPointer { buffer in
            Issue.record("Geronimo creation failed: \(buffer.baseAddress.map { String(cString: $0) } ?? "unknown error")")
        }
        return
    }

    let resultName = OpenNOWTestNativeNVSTGeronimoResultCodeName(session, 302)
    #expect(resultName.map { String(cString: $0) } == "NVB_R_SESSION_LIMIT_REACHED")

    var surface: NSView? = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    weak let retainedSurface = surface
    let result = errorBuffer.withUnsafeMutableBufferPointer { buffer in
        OpenNOWTestNativeNVSTGeronimoSetVideoSurface(
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
        OpenNOWTestNativeNVSTGeronimoSetMicrophoneEnabled(session, 1, buffer.baseAddress, buffer.count)
    }
    #expect(microphoneResult == -3)

    OpenNOWTestNativeNVSTGeronimoDestroy(session)
    #expect(retainedSurface == nil)
}

@Test func nvstGeronimoConversionRejectsUnsupportedServerAndAuthTypes() {
    #expect((1...5).map { OpenNOWNativeNVSTGeronimoConvertServerType(Int32($0)) } == [0, 1, 2, 3, 4])
    #expect(OpenNOWNativeNVSTGeronimoConvertServerType(1001) == 0x33)
    #expect(OpenNOWNativeNVSTGeronimoConvertServerType(0) == -1)
    #expect(OpenNOWNativeNVSTGeronimoConvertServerType(52) == -1)
    #expect(convertedAuthTokenType("7") == 7)
    #expect(convertedAuthTokenType("jarvis") == 7)
    #expect(convertedAuthTokenType("JWT") == 8)
    #expect(convertedAuthTokenType("jwt-gfn") == 9)
    #expect(convertedAuthTokenType("unsupported") == -1)
    #expect(OpenNOWNativeNVSTGeronimoConvertAuthTokenType(nil) == -1)
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
        OpenNOWTestNativeNVSTGeronimoSetMicrophoneEnabled(nil, 1, buffer.baseAddress, buffer.count)
    }

    #expect(result == -1)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OPN_NVST_E2E_ENABLED"] == "1"))
@MainActor func nvstAuthenticatedFreshLaunchPumpsAndStops() async throws {
    let environment = ProcessInfo.processInfo.environment
    let token = try #require(environment["OPN_NVST_TEST_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines))
    let applicationID = try #require(environment["OPN_NVST_TEST_APP_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(!token.isEmpty)
    #expect(!applicationID.isEmpty)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    defer { window.close() }

    let configuration = StreamLaunchConfiguration(
        title: "NVST Authenticated Test",
        applicationID: applicationID,
        accessToken: token,
        accountLinked: true
    )
    let provider = OpenNOWStreamSessionCoordinator()
    let surfaceHandle = UInt(bitPattern: Unmanaged.passUnretained(window).toOpaque())
    let transport = NativeNVSTBifrostTransport(nativeVideoSurfaceHandle: surfaceHandle)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)

    let session = try await path.start(configuration: configuration)
    #expect(session.applicationID == applicationID)
    try await Task.sleep(for: .seconds(5))
    let report = try await path.stop(reason: .userRequested, message: "Authenticated NVST validation completed.")
    #expect(report.success)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OPN_NVST_E2E_ENABLED"] == "1"))
@MainActor func nvstAuthenticatedPauseAndPublicResume() async throws {
    let environment = ProcessInfo.processInfo.environment
    let token = try #require(environment["OPN_NVST_TEST_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines))
    let applicationID = try #require(environment["OPN_NVST_TEST_APP_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(!token.isEmpty)
    #expect(!applicationID.isEmpty)

    let provider = OpenNOWStreamSessionCoordinator()
    let initialWindow = nativeNVSTTestWindow()
    initialWindow.orderFront(nil)
    defer { initialWindow.close() }
    let initialConfiguration = StreamLaunchConfiguration(
        title: "NVST Authenticated Resume Test",
        applicationID: applicationID,
        accessToken: token,
        accountLinked: true
    )
    let initialTransport = NativeNVSTBifrostTransport(nativeVideoSurfaceHandle: UInt(bitPattern: Unmanaged.passUnretained(initialWindow).toOpaque()))
    let initialPath = NativeNVSTStreamingPath(sessionProvider: provider, transport: initialTransport)
    let initialSession = try await initialPath.start(configuration: initialConfiguration)
    try await Task.sleep(for: .seconds(3))
    let pauseReport = try await initialPath.pause(message: "Authenticated NVST pause validation.")
    #expect(pauseReport.success)
    #expect(pauseReport.reason == .paused)
    initialWindow.close()

    let resumeWindow = nativeNVSTTestWindow()
    resumeWindow.orderFront(nil)
    defer { resumeWindow.close() }
    let resumeConfiguration = StreamLaunchConfiguration(
        title: initialConfiguration.title,
        applicationID: applicationID,
        accessToken: token,
        accountLinked: true,
        resumeSessionID: initialSession.id,
        resumeServer: initialSession.serverAddress
    )
    let resumeTransport = NativeNVSTBifrostTransport(nativeVideoSurfaceHandle: UInt(bitPattern: Unmanaged.passUnretained(resumeWindow).toOpaque()))
    let resumePath = NativeNVSTStreamingPath(sessionProvider: provider, transport: resumeTransport)
    let resumedSession = try await resumePath.start(configuration: resumeConfiguration)
    #expect(resumedSession.id == initialSession.id)
    try await Task.sleep(for: .seconds(3))
    let stopReport = try await resumePath.stop(reason: .userRequested, message: "Authenticated NVST resume validation completed.")
    #expect(stopReport.success)
}

}

private func vendoredBridge() throws -> NVSTNativeBridge {
    let frameworksDirectory = repoRoot().appendingPathComponent("vendor/gfn-runtime/Frameworks", isDirectory: true)
    return try NVSTNativeBridge(configuration: NVSTNativeBridgeConfiguration(frameworksDirectory: frameworksDirectory))
}

@MainActor private func nativeNVSTTestWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    return window
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func convertedAuthTokenType(_ tokenType: String) -> Int32 {
    tokenType.withCString { OpenNOWNativeNVSTGeronimoConvertAuthTokenType($0) }
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
            OpenNOWNativeNVSTGeronimoInspectEndpoint(addressPointer, fallbackPort, hostBuffer.baseAddress, hostBuffer.count, &port)
        }
    }
    guard result == 0 else { return nil }
    return host.withUnsafeBufferPointer { buffer in
        buffer.baseAddress.map { ParsedNativeEndpoint(host: String(cString: $0), port: port) }
    }
}

@_silgen_name("OpenNOWNativeNVSTGeronimoConvertServerType")
private func OpenNOWNativeNVSTGeronimoConvertServerType(_ serverType: Int32) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoConvertAuthTokenType")
private func OpenNOWNativeNVSTGeronimoConvertAuthTokenType(_ tokenType: UnsafePointer<CChar>?) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoInspectEndpoint")
private func OpenNOWNativeNVSTGeronimoInspectEndpoint(_ address: UnsafePointer<CChar>?, _ fallbackPort: UInt16, _ hostBuffer: UnsafeMutablePointer<CChar>?, _ hostBufferLength: Int, _ port: UnsafeMutablePointer<UInt16>?) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoCreate")
private func OpenNOWTestNativeNVSTGeronimoCreate(_ frameworksPath: UnsafePointer<CChar>?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> UnsafeMutableRawPointer?

@_silgen_name("OpenNOWNativeNVSTGeronimoDestroy")
private func OpenNOWTestNativeNVSTGeronimoDestroy(_ session: UnsafeMutableRawPointer?)

@_silgen_name("OpenNOWNativeNVSTGeronimoSetVideoSurface")
private func OpenNOWTestNativeNVSTGeronimoSetVideoSurface(_ session: UnsafeMutableRawPointer?, _ nativeHandle: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoSetMicrophoneEnabled")
private func OpenNOWTestNativeNVSTGeronimoSetMicrophoneEnabled(_ session: UnsafeMutableRawPointer?, _ enabled: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoResultCodeName")
private func OpenNOWTestNativeNVSTGeronimoResultCodeName(_ session: UnsafeMutableRawPointer?, _ resultCode: Int32) -> UnsafePointer<CChar>?
