import Foundation
import Testing
@testable import OpenNOWTelemetry

@Test func telemetryDisabledPreferenceRoundTrips() throws {
    let suiteName = "OpenNOWTelemetryTests.telemetryDisabled.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(OPNSentry.telemetryDisabled(defaults: defaults) == false)
    OPNSentry.setTelemetryDisabled(true, defaults: defaults)
    #expect(OPNSentry.telemetryDisabled(defaults: defaults) == true)
    OPNSentry.setTelemetryDisabled(false, defaults: defaults)
    #expect(OPNSentry.telemetryDisabled(defaults: defaults) == false)
}

@Test func diagnosticsUploadAcceptsCreatedPasteResponse() async throws {
    let host = "diagnostics-created.example.test"
    DiagnosticsUploadURLProtocol.install(host: host) { _, _ in
        (201, Data("https://paste.rs/created".utf8))
    }
    defer { DiagnosticsUploadURLProtocol.uninstall(host: host) }

    let uploadURL = try #require(URL(string: "https://\(host)"))
    let result = try await OPNSentry.uploadDiagnosticsLog("diagnostic line", session: diagnosticsUploadSession(), uploadURL: uploadURL)

    #expect(result.absoluteString == "https://paste.rs/created")
    let bodies = DiagnosticsUploadURLProtocol.recordedBodies(host: host)
    #expect(bodies.count == 1)
    #expect(String(decoding: bodies.first ?? Data(), as: UTF8.self) == "diagnostic line")
}

@Test func diagnosticsUploadRejectsPartialPasteResponse() async throws {
    let host = "diagnostics-partial.example.test"
    DiagnosticsUploadURLProtocol.install(host: host) { _, _ in
        (206, Data("https://paste.rs/partial".utf8))
    }
    defer { DiagnosticsUploadURLProtocol.uninstall(host: host) }

    let uploadURL = try #require(URL(string: "https://\(host)"))

    do {
        _ = try await OPNSentry.uploadDiagnosticsLog("diagnostic line", session: diagnosticsUploadSession(), uploadURL: uploadURL)
        Issue.record("Expected partial paste response to fail")
    } catch OPNSentryDiagnosticsUploadError.partialUpload {
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func diagnosticsUploadMapsServiceFailuresToRetryableMessage() async throws {
    let host = "diagnostics-service-failure.example.test"
    DiagnosticsUploadURLProtocol.install(host: host) { _, _ in
        (500, Data("temporary failure".utf8))
    }
    defer { DiagnosticsUploadURLProtocol.uninstall(host: host) }

    let uploadURL = try #require(URL(string: "https://\(host)"))

    do {
        _ = try await OPNSentry.uploadDiagnosticsLog("diagnostic line", session: diagnosticsUploadSession(), uploadURL: uploadURL)
        Issue.record("Expected service failure to throw")
    } catch OPNSentryDiagnosticsUploadError.serviceUnavailable(let status) {
        #expect(status == 500)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func diagnosticsUploadCapsOversizedBodyAndSanitizesContent() async throws {
    let host = "diagnostics-oversized.example.test"
    DiagnosticsUploadURLProtocol.install(host: host) { _, _ in
        (201, Data("https://paste.rs/oversized".utf8))
    }
    defer { DiagnosticsUploadURLProtocol.uninstall(host: host) }

    let uploadURL = try #require(URL(string: "https://\(host)"))
    let oversizedLog = String(repeating: "diagnostic line serverIp=10.1.2.3 token=secret-value\n", count: 12_000)
    let result = try await OPNSentry.uploadDiagnosticsLog(oversizedLog, session: diagnosticsUploadSession(), uploadURL: uploadURL)

    #expect(result.absoluteString == "https://paste.rs/oversized")
    let body = try #require(DiagnosticsUploadURLProtocol.recordedBodies(host: host).first)
    let text = String(decoding: body, as: UTF8.self)
    #expect(body.count <= 384 * 1024)
    #expect(text.contains("upload is limited to the most recent 384 KiB"))
    #expect(text.contains("[redacted-secret]"))
    #expect(!text.contains("10.1.2.3"))
    #expect(!text.contains("secret-value"))
}

private func diagnosticsUploadSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DiagnosticsUploadURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class DiagnosticsUploadURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var bodiesByHost: [String: [Data]] = [:]
    nonisolated(unsafe) private static var installed = false

    static func install(host: String, handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
            bodiesByHost[host] = []
            if !installed {
                URLProtocol.registerClass(Self.self)
                installed = true
            }
        }
    }

    static func uninstall(host: String) {
        lock.withLock {
            handlers[host] = nil
            bodiesByHost[host] = nil
            if handlers.isEmpty, installed {
                URLProtocol.unregisterClass(Self.self)
                installed = false
            }
        }
    }

    static func recordedBodies(host: String) -> [Data] {
        lock.withLock { bodiesByHost[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { handlers[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let host = request.url?.host, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.bodyData(from: request) ?? Data()
        let handler = Self.lock.withLock { () -> Handler? in
            Self.bodiesByHost[host, default: []].append(body)
            return Self.handlers[host]
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request, body)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/plain"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}
