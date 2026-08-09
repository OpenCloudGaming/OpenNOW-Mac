import Foundation
import Testing
@testable import OpenNOW

@Test func nvstNativeRuntimeLoadsVendoredBifrostSymbols() throws {
    let frameworksDirectory = repoRoot().appendingPathComponent("vendor/gfn-runtime/Frameworks", isDirectory: true)

    let runtime = try NVSTNativeRuntime(frameworksDirectory: frameworksDirectory)

    #expect(runtime.status.libraryURL.lastPathComponent == "libBifrost2.dylib")
    #expect(runtime.status.resolvedSymbols == NVSTNativeSymbol.allCases.map(\.rawValue))
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
