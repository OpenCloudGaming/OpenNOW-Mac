//
//  OpenNOWSessionFixtures.swift
//  OpenNOW
//
//  The CloudMatch responses and settings dictionaries the session tests are written
//  against, plus the stub URL protocol that serves them.
//  Split out of OpenNOWSessionClaimTests.swift.
//

import Testing
import Foundation
@testable import OpenNOW

func minimalSettings() -> [String: Any] {
    [
        "resolution": "1920x1080",
        "fps": 60,
        "codec": "h264",
        "colorQuality": "standard",
        "maxBitrateMbps": 50,
        "selectedStore": "Steam",
        "accountLinked": true,
        "gameLanguage": "en_US",
        "keyboardLayout": "us",
    ]
}

func parsePhysicalResolutionMetadata(_ metadata: [[String: String]]) -> [String: Any]? {
    guard let value = metadata.first(where: { $0["key"] == "clientPhysicalResolution" })?["value"],
          let data = value.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

func sessionResponse(statusCode: Int, sessionStatus: Int, controlHost: String = "control.example.test", extraSession: [String: Any] = [:]) -> [String: Any] {
    var session: [String: Any] = [
        "sessionId": "resume-session",
        "status": sessionStatus,
        "gpuType": "L40",
        "sessionRequestData": ["appId": 123],
        "sessionControlInfo": ["ip": controlHost],
        "connectionInfo": [[
            "usage": 14,
            "ip": "signaling.example.test",
            "port": 443,
            "resourcePath": "/nvst/",
        ]],
        "monitorSettings": [[
            "widthInPixels": 1920,
            "heightInPixels": 1080,
            "framesPerSecond": 60,
            "dpi": 96,
        ]],
    ]
    for (key, value) in extraSession {
        session[key] = value
    }

    return [
        "requestStatus": [
            "statusCode": statusCode,
            "statusDescription": statusCode == 1 ? "SUCCESS" : "ERROR",
        ],
        "session": session,
    ]
}

func staleSessionResponse() -> [String: Any] {
    [
        "requestStatus": [
            "statusCode": 4,
            "statusDescription": "INTERNAL_ERROR_STATUS 8A8C0000",
        ],
        "session": [
            "sessionId": "resume-session",
            "status": 4,
            "sessionRequestData": ["appId": 0],
        ],
    ]
}

func limitedModeSessionResponse() -> [String: Any] {
    [
        "requestStatus": [
            "statusCode": 81,
            "statusDescription": "STREAMING_NOT_ALLOWED_IN_LIMITED_MODE 8A91000D",
            "unifiedErrorCode": -1970208755,
        ],
        "session": [
            "sessionId": "limited-mode-session",
            "status": 0,
            "seatSetupInfo": ["queuePosition": 1, "seatSetupStep": 0, "seatSetupEta": 0],
        ],
    ]
}

func catalogGraphQLGame(id: String, title: String? = nil, libraryStatus: String = "NOT_OWNED", librarySelected: Bool = false, appStore: String = "STEAM", variantId: String? = nil, favorited: Bool = false, freeToPlay: Bool = false) -> [String: Any] {
    [
        "id": id,
        "title": title ?? "Catalog Game \(id)",
        "shortName": "vendor-title",
        "developerName": "Vendor Developer",
        "publisherName": "Vendor Publisher",
        "maxLocalPlayers": 4,
        "maxOnlinePlayers": 8,
        "supportedControls": ["KEYBOARD_MOUSE"],
        "displaysOwnRatingDuringGameplay": true,
        "genres": ["ACTION"],
        "contentRatings": [["categoryKey": "TEEN", "contentDescriptorKeys": ["VIOLENCE"], "interactiveElementKeys": ["USERS_INTERACT"], "type": "ESRB"]],
        "library": ["favorited": favorited],
        "images": ["TV_BANNER": ["https://assets.example.invalid/\(id).jpg"]],
        "variants": [[
            "id": variantId ?? "1\(abs(id.hashValue % 1_000_000))",
            "shortName": "vendor-short",
            "appStore": appStore,
            "storeUrl": "https://store.example.invalid/\(id)",
            "developerName": "Variant Developer",
            "publisherName": "Variant Publisher",
            "streetDate": "2026-07-17",
            "supportedControls": ["GAMEPAD"],
            "subscriptions": ["sub-ultimate"],
            "paymentModels": [["__typename": freeToPlay ? "FreeToPlay" : "IncludedWithSubscription"]],
            "minimumSizeInBytes": 42_000_000,
            "cloudSaveSupported": true,
            "gfn": [
                "status": "AVAILABLE",
                "installTimeInMinutes": 7,
                "supportedLanguages": [["language": "en_US"]],
                "features": [["__typename": "GfnSubscriptionFeatureValue", "key": "RAY_TRACING", "value": "SUPPORTED"]],
                "library": ["status": libraryStatus, "selected": librarySelected, "playStatus": "PLAYABLE", "installed": true, "subscription": "GFN_PREMIUM"],
            ],
        ]],
        "gfn": ["playabilityState": "PLAYABLE", "minimumMembershipTierLabel": "Free", "playType": "FULL_GAME", "catalogSkuStrings": ["SKU_BASED_TAG": ["NEW_ON_GFN"], "SKU_BASED_PLAYABILITY_TEXT": "Included with membership", "SKU_BASED_UNPLAYABLE_DIALOG_HEADER": "Upgrade required", "SKU_BASED_UNPLAYABLE_DIALOG_BODY_UPGRADE": "Upgrade to play", "SKU_BASED_UNPLAYABLE_DIALOG_BODY_UPGRADE_ECOMM_RESTRICTED": "Upgrade in your account"]],
        "itemMetadata": ["campaignIds": []],
    ]
}

final class SessionManagerURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    /// Paths a wildcard handler is willing to claim.
    ///
    /// A `"*"` handler otherwise claims every host, including traffic from a test that has already
    /// finished - a request that outlived its own handler lands on whichever wildcard is installed
    /// next. That handler then answers it with the wrong body and, if it asserts, records the failure
    /// against no test at all, because a `URLProtocol` runs outside any test's scope.
    nonisolated(unsafe) private static var wildcardPaths: [String] = []
    nonisolated(unsafe) private static var requestsByHost: [String: [URLRequest]] = [:]
    nonisolated(unsafe) private static var bodiesByHost: [String: [Data]] = [:]
    nonisolated(unsafe) private static var installed = false

    /// `paths` narrows a wildcard handler to the requests its test actually expects. Ignored for a
    /// named host, which is already scoped by the host itself.
    static func install(host: String, paths: [String] = [], handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
            if host == "*" { wildcardPaths = paths }
            requestsByHost[host] = []
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
            if host == "*" { wildcardPaths = [] }
            requestsByHost[host] = nil
            bodiesByHost[host] = nil
            if handlers.isEmpty, installed {
                URLProtocol.unregisterClass(Self.self)
                installed = false
            }
        }
    }

    static func recordedRequests(host: String) -> [URLRequest] {
        lock.withLock { requestsByHost[host] ?? [] }
    }

    static func recordedJSONBodies(host: String) -> [[String: Any]] {
        lock.withLock { bodiesByHost[host] ?? [] }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    static func response(json: [String: Any], status: Int = 200) -> (Int, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return (status, data)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        let path = request.url?.path ?? ""
        return lock.withLock {
            if handlers[host] != nil { return true }
            guard handlers["*"] != nil else { return false }
            return wildcardPaths.isEmpty || wildcardPaths.contains(path)
        }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let host = request.url?.host, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.bodyData(from: request)
        let handler = Self.lock.withLock { () -> Handler? in
            let key = Self.handlers[host] == nil && Self.handlers["*"] != nil ? "*" : host
            guard key != "*" || Self.wildcardPaths.isEmpty || Self.wildcardPaths.contains(url.path) else { return nil }
            Self.requestsByHost[key, default: []].append(request)
            if let body { Self.bodiesByHost[key, default: []].append(body) }
            return Self.handlers[key]
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
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
