import Foundation
import Testing
@testable import OpenNOW

@Suite struct GitHubUpdaterVersionComparisonTests {
    /// `0.8.0` outranking `0.8.0-beta.4` is the shipped regression: splitting on `.-_` put "beta"
    /// where a core field belongs, so a beta subscriber was never offered the stable cut from it.
    @Test(arguments: [
        ("0.8.0", "0.8.0-beta.4", 1),
        ("0.8.0-beta.4", "0.8.0", -1),
        ("0.8.0-beta.4", "0.8.0-beta.2", 1),
        ("0.8.0-beta.10", "0.8.0-beta.9", 1),
        ("0.8.1", "0.8.0", 1),
        ("0.8.1", "0.8.0-beta.4", 1),
        ("0.9.0-beta.1", "0.8.0", 1),
        ("0.9.0-beta.1", "0.8.0-beta.4", 1),
        ("0.10.0", "0.9.1", 1),
        ("0.7.1", "0.10.0", -1),
        ("v0.8.0", "0.8.0", 0),
        ("0.8", "0.8.0", 0),
        ("0.8.0-beta.4", "0.8.0-beta.4", 0),
        ("1.0.0-alpha", "1.0.0-alpha.1", -1),
        ("1.0.0-alpha.1", "1.0.0-alpha.beta", -1),
        ("1.0.0-beta.11", "1.0.0-rc.1", -1),
        ("1.0.0-rc.1", "1.0.0", -1),
    ])
    func versionPrecedenceFollowsSemver(sample: (left: String, right: String, expected: Int)) {
        let result = OpenNOWGitHubUpdater.compareVersion(sample.left, to: sample.right)
        #expect(result.signum() == sample.expected, "\(sample.left) vs \(sample.right) gave \(result)")
        // The mirror catches a fix that only ranks one direction, such as "non-numeric wins".
        let mirrored = OpenNOWGitHubUpdater.compareVersion(sample.right, to: sample.left)
        #expect(mirrored.signum() == -sample.expected, "\(sample.right) vs \(sample.left) gave \(mirrored)")
    }
}

@Suite(.serialized) struct GitHubUpdaterChannelFetchTests {
    @Test func betaIsOfferedTheStableReleaseTheMomentItShips() async throws {
        try await withStubbedGitHub(list: currentReleaseList()) { updater in
            let release = try await updater.checkForUpdate(channel: .beta)
            #expect(release?.version == "0.8.0")
            #expect(release?.summary.isPrerelease == false)
        }
    }

    @Test func betaSkipsANewestReleaseThatHasNoMacOSArchiveYet() async throws {
        // release-beta.yml publishes the release and only then builds it, so the newest slot carries
        // no zip for the whole notarization window.
        let list = [releaseJSON(tag: "v0.8.1", assetName: nil)] + currentReleaseList()
        try await withStubbedGitHub(list: list) { updater in
            let release = try await updater.checkForUpdate(channel: .beta)
            #expect(release?.version == "0.8.0")
        }
    }

    @Test func betaSkipsAnAssetThatIsStillUploading() async throws {
        let list = [releaseJSON(tag: "v0.8.1", assetState: "starting")] + currentReleaseList()
        try await withStubbedGitHub(list: list) { updater in
            let release = try await updater.checkForUpdate(channel: .beta)
            #expect(release?.version == "0.8.0")
        }
    }

    @Test func betaSkipsADraftRelease() async throws {
        let list = [releaseJSON(tag: "v0.8.1", draft: true)] + currentReleaseList()
        try await withStubbedGitHub(list: list) { updater in
            let release = try await updater.checkForUpdate(channel: .beta)
            #expect(release?.version == "0.8.0")
        }
    }

    @Test func betaTakesTheHighestVersionRatherThanTheFirstEntry() async throws {
        // GitHub orders by the tagged commit's date, so a hotfix cut from an older branch leads.
        let list = [releaseJSON(tag: "v0.7.2")] + currentReleaseList()
        try await withStubbedGitHub(list: list) { updater in
            let release = try await updater.checkForUpdate(channel: .beta)
            #expect(release?.version == "0.8.0")
        }
    }

    @Test func betaReturnsNilWhenNoListedReleaseIsInstallable() async throws {
        let list = [releaseJSON(tag: "v0.8.1", assetName: nil), releaseJSON(tag: "v0.8.0", assetName: nil)]
        try await withStubbedGitHub(list: list) { updater in
            let release = try await updater.checkForUpdate(channel: .beta)
            #expect(release == nil)
        }
    }

    @Test func betaReachesAnInstallableReleaseBehindAWholeUnbuiltVersionLine() async throws {
        // The window the page size is chosen for: a draft plus two version lines whose archives never
        // landed sit above the last good release. Asking for one slot reported "up to date" instead.
        let stalled = [releaseJSON(tag: "v0.9.1", draft: true), releaseJSON(tag: "v0.9.0", assetName: nil)]
            + (1...4).map { releaseJSON(tag: "v0.9.0-beta.\($0)", prerelease: true, assetName: nil) }
            + (1...3).map { releaseJSON(tag: "v0.8.1-beta.\($0)", prerelease: true, assetState: "starting") }
        try await withStubbedGitHub(list: stalled + currentReleaseList()) { updater in
            let release = try await updater.checkForUpdate(channel: .beta)
            #expect(release?.version == "0.8.0")
            let url = try #require(SessionManagerURLProtocol.recordedRequests(host: gitHubAPIHost).first?.url)
            #expect(url.path.hasSuffix("/releases"))
            #expect(pageSizeQueryValue(url) ?? 0 > 1)
        }
    }

    @Test func stableNeverSelectsAPrerelease() async throws {
        let list = [releaseJSON(tag: "v0.9.0-beta.1", prerelease: true)] + currentReleaseList()
        try await withStubbedGitHub(list: list, currentVersion: "0.7.1") { updater in
            let release = try await updater.checkForUpdate(channel: .stable)
            #expect(release?.version == "0.8.0")
            #expect(release?.summary.isPrerelease == false)
            #expect(SessionManagerURLProtocol.recordedRequests(host: gitHubAPIHost).count == 1)
        }
    }

    @Test func stableSkipsANewestReleaseThatHasNoMacOSArchiveYet() async throws {
        // release-please.yml publishes the release and only then builds it, and a build that never
        // finishes leaves that slot asset-less for good, so the last good stable must stay reachable.
        let list = [releaseJSON(tag: "v0.8.1", assetName: nil)] + currentReleaseList()
        try await withStubbedGitHub(list: list, currentVersion: "0.7.1") { updater in
            let release = try await updater.checkForUpdate(channel: .stable)
            #expect(release?.version == "0.8.0")
        }
    }

    @Test func stableReachesPastAWindowFullOfBetasThroughLatest() async throws {
        let list = (1...10).map { releaseJSON(tag: "v0.9.0-beta.\($0)", prerelease: true) } + [releaseJSON(tag: "v0.8.0")]
        try await withStubbedGitHub(list: list, currentVersion: "0.7.1") { updater in
            let release = try await updater.checkForUpdate(channel: .stable)
            #expect(release?.version == "0.8.0")
            let paths = SessionManagerURLProtocol.recordedRequests(host: gitHubAPIHost).compactMap { $0.url?.path }
            #expect(paths.contains { $0.hasSuffix("/releases/latest") })
        }
    }

    @Test func stableReturnsNilRatherThanFailingWhenNothingIsInstallable() async throws {
        let list = [releaseJSON(tag: "v0.8.1", assetName: nil), releaseJSON(tag: "v0.8.0", assetName: nil)]
        try await withStubbedGitHub(list: list, currentVersion: "0.7.1") { updater in
            let release = try await updater.checkForUpdate(channel: .stable)
            #expect(release == nil)
        }
    }

    @Test func aCurrentInstallIsOfferedNothingOnEitherChannel() async throws {
        try await withStubbedGitHub(list: currentReleaseList(), currentVersion: "0.8.0") { updater in
            let beta = try await updater.checkForUpdate(channel: .beta)
            let stable = try await updater.checkForUpdate(channel: .stable)
            #expect(beta == nil)
            #expect(stable == nil)
        }
    }

    @Test func aNewerInstallIsNotOfferedADowngrade() async throws {
        try await withStubbedGitHub(list: currentReleaseList(), currentVersion: "0.9.0-beta.1") { updater in
            let release = try await updater.checkForUpdate(channel: .beta)
            #expect(release == nil)
        }
    }

    @Test func theOfferedReleaseCarriesItsMacOSArchive() async throws {
        try await withStubbedGitHub(list: currentReleaseList()) { updater in
            let release = try #require(await updater.checkForUpdate(channel: .beta))
            #expect(release.assetName == "OpenNOW-0.8.0-macOS.zip")
            #expect(release.assetDownloadURL == "https://example.invalid/OpenNOW-0.8.0-macOS.zip")
            #expect(release.assetByteCount == 1234)
            #expect(release.tagName == "v0.8.0")
        }
    }
}

private let gitHubAPIHost = "api.github.com"

/// The repository's real tag order at the time the two channel bugs were reported.
private func currentReleaseList() -> [[String: Any]] {
    [
        releaseJSON(tag: "v0.8.0"),
        releaseJSON(tag: "v0.8.0-beta.4", prerelease: true),
        releaseJSON(tag: "v0.8.0-beta.3", prerelease: true),
        releaseJSON(tag: "v0.8.0-beta.2", prerelease: true),
        releaseJSON(tag: "v0.8.0-beta.1", prerelease: true),
        releaseJSON(tag: "v0.7.1"),
        releaseJSON(tag: "v0.7.0"),
    ]
}

/// `assetName: nil` models a release record published before its archive finished building.
private func releaseJSON(tag: String, prerelease: Bool = false, draft: Bool = false, assetName: String? = "", assetState: String = "uploaded") -> [String: Any] {
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    let resolvedName = assetName.map { $0.isEmpty ? "OpenNOW-\(version)-macOS.zip" : $0 }
    let assets: [[String: Any]] = resolvedName.map { name in
        [["name": name, "browser_download_url": "https://example.invalid/\(name)", "size": 1234, "state": assetState]]
    } ?? []
    return [
        "tag_name": tag,
        "prerelease": prerelease,
        "draft": draft,
        "html_url": "https://github.com/OpenCloudGaming/openNOW-Mac/releases/tag/\(tag)",
        "body": "Release notes for \(tag).",
        "published_at": "2026-09-10T12:00:00Z",
        "assets": assets,
    ]
}

/// Serves the requested `per_page` window of the list, and its newest non-prerelease, non-draft
/// entry to `releases/latest`, which is the selection GitHub makes server side. Honouring the page
/// size is what makes a window too small to reach an installable release fail the suite.
private func withStubbedGitHub(list: [[String: Any]], currentVersion: String = "0.8.0-beta.2", _ body: @escaping @Sendable (OpenNOWGitHubUpdater) async throws -> Void) async throws {
    let latest = list.first { ($0["prerelease"] as? Bool) != true && ($0["draft"] as? Bool) != true } ?? [:]
    let pages = (0...list.count).map { jsonData(Array(list.prefix($0))) }
    let latestData = jsonData(latest)
    try await networkTestIsolationLock.withLock {
        SessionManagerURLProtocol.install(host: gitHubAPIHost) { request in
            guard let url = request.url, !url.path.hasSuffix("/releases/latest") else { return (200, latestData) }
            let pageSize = pageSizeQueryValue(url) ?? pages.count - 1
            return (200, pages[min(max(pageSize, 0), pages.count - 1)])
        }
        defer { SessionManagerURLProtocol.uninstall(host: gitHubAPIHost) }

        let updater = OpenNOWGitHubUpdater(owner: "OpenCloudGaming", repository: "openNOW-Mac", currentVersion: currentVersion, session: stubbedGitHubSession())
        try await body(updater)
    }
}

private func jsonData(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private func pageSizeQueryValue(_ url: URL) -> Int? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == "per_page" }
        .flatMap { $0.value.flatMap(Int.init) }
}

/// The updater builds its own session, which never consults the globally registered protocol class.
private func stubbedGitHubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionManagerURLProtocol.self]
    return URLSession(configuration: configuration)
}
