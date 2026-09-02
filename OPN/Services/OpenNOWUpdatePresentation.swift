import Combine
import Foundation

/// Shared state behind every update surface: the modal the app delegate raises, and the What's New
/// card in Settings → About. Both read the same pending release, so a dismissed prompt still leaves
/// About showing that an update is waiting, and the install action behaves identically on both.
@MainActor
final class OpenNOWUpdatePresentation: ObservableObject {
    static let shared = OpenNOWUpdatePresentation()

    enum Request: Equatable {
        case available(OpenNOWGitHubRelease)
        case upToDate(version: String)
        case checkFailed(message: String)
        case installFailed(message: String)
    }

    enum InstallState: Equatable {
        case idle
        case downloading(OpenNOWUpdateDownloadProgress)
        case staging

        var isWorking: Bool { self != .idle }
    }

    @Published private(set) var request: Request?
    @Published private(set) var notes = OpenNOWReleaseNotes.empty
    @Published private(set) var installState = InstallState.idle
    /// Outlives `request`: the modal can be dismissed, the update is still pending.
    @Published private(set) var availableRelease: OpenNOWGitHubRelease?

    var installHandler: ((OpenNOWGitHubRelease) -> Void)?
    var remindHandler: (() -> Void)?

    #if DEBUG
    /// Set only by the debug preview command. Keeps the sample release from downloading and
    /// replacing the running app when the install button is pressed.
    private(set) var isPreviewingSample = false
    private var simulatedInstallTask: Task<Void, Never>?
    #endif

    private init() {}

    func present(_ request: Request) {
        #if DEBUG
        isPreviewingSample = false
        simulatedInstallTask?.cancel()
        simulatedInstallTask = nil
        #endif
        presentRequest(request)
    }

    private func presentRequest(_ request: Request) {
        if case .available(let release) = request {
            availableRelease = release
            notes = OpenNOWReleaseNotesFormatter.parse(release.releaseNotes)
        } else {
            notes = .empty
        }
        installState = .idle
        self.request = request
    }

    func presentAvailableRelease() {
        guard let availableRelease else { return }
        present(.available(availableRelease))
    }

    func dismiss() {
        guard !installState.isWorking else { return }
        request = nil
    }

    func clearAvailableRelease() {
        availableRelease = nil
        if case .available = request { request = nil }
    }

    func install() {
        guard case .available(let release) = request, !installState.isWorking else { return }
        installState = .downloading(OpenNOWUpdateDownloadProgress(receivedBytes: 0, expectedBytes: release.assetByteCount))
        #if DEBUG
        if isPreviewingSample {
            runSimulatedInstall(release)
            return
        }
        #endif
        installHandler?(release)
    }

    func remindTomorrow() {
        remindHandler?()
        installState = .idle
        request = nil
    }

    func reportDownloadProgress(_ progress: OpenNOWUpdateDownloadProgress) {
        guard case .downloading = installState else { return }
        // Signature verification, extraction, and the installer handoff all run after the last byte
        // lands, and they are not instant — the bar would otherwise sit at 100 % looking stalled.
        installState = progress.fraction == 1 ? .staging : .downloading(progress)
    }

    func reportStaging() {
        guard installState.isWorking else { return }
        installState = .staging
    }

    func reportInstallFailure(_ message: String) {
        installState = .idle
        present(.installFailed(message: message))
    }
}

#if DEBUG
extension OpenNOWUpdatePresentation {
    /// A body in the exact shape release-please publishes, with enough entries to exercise
    /// scrolling, both chip kinds, a bold scope prefix, and more than one section.
    static let sampleReleaseNotesBody = """
    ## [0.3.0](https://github.com/OpenCloudGaming/OpenNOW-Mac/compare/v0.2.0...v0.3.0) (2026-09-02)


    ### Features

    * add remote co-op guest client ([7d16669](https://github.com/OpenCloudGaming/OpenNOW-Mac/commit/7d16669882a77583d96cbe51a7f24c4352232ef9))
    * add native NVST AV1 decode ([#60](https://github.com/OpenCloudGaming/OpenNOW-Mac/issues/60)) ([25cd0c1](https://github.com/OpenCloudGaming/OpenNOW-Mac/commit/25cd0c1eda698bffaad676cad7ed1bf3607cd697))
    * add on screen keyboard ([bcbad7b](https://github.com/OpenCloudGaming/OpenNOW-Mac/commit/bcbad7b2ddb946a1e16e6387696b2dbf7c3aa209))
    * add live clock to stream HUD footer ([87539f7](https://github.com/OpenCloudGaming/OpenNOW-Mac/commit/87539f7b7f0cf21a4068db1958c765b461763ea3))
    * surface release notes in a formatted update dialog instead of raw GitHub markdown ([5436546](https://github.com/OpenCloudGaming/OpenNOW-Mac/commit/5436546ad81b9a97ef2c98729948f821149a8339))

    ### Bug Fixes

    * **ci:** install dmgbuild and sign release with real entitlements ([055e530](https://github.com/OpenCloudGaming/OpenNOW-Mac/commit/055e5309a9e2d1a2b6a2ee4d47a6a1a4a0b2c3d4))
    * resolve Swift 6 actor isolation errors in tile equality and resize gate ([74fb53c](https://github.com/OpenCloudGaming/OpenNOW-Mac/commit/74fb53c2b1a0d3e4f5a6b7c8d9e0f1a2b3c4d5e6))
    * beta tag position ([#9](https://github.com/OpenCloudGaming/OpenNOW-Mac/issues/9)) ([622d967](https://github.com/OpenCloudGaming/OpenNOW-Mac/commit/622d9671f2e3d4c5b6a7988990a1b2c3d4e5f607))

    ### Performance Improvements

    * decode SRTP 31x faster by batching GHASH blocks ([bf34a18](https://github.com/OpenCloudGaming/OpenNOW-Mac/commit/bf34a18af423b3fb91d505ea0eb1a79903e2a003))
    """

    static func sampleRelease(version: String = "0.3.0") -> OpenNOWGitHubRelease {
        OpenNOWGitHubRelease(
            summary: OpenNOWReleaseSummary(
                version: version,
                tagName: "v\(version)",
                releaseNotes: sampleReleaseNotesBody,
                releaseURL: "https://github.com/OpenCloudGaming/OpenNOW-Mac/releases/tag/v\(version)",
                publishedAt: Date()
            ),
            assetName: "OpenNOW-\(version)-macOS.zip",
            assetDownloadURL: "https://github.com/OpenCloudGaming/OpenNOW-Mac/releases/download/v\(version)/OpenNOW-\(version)-macOS.zip",
            assetByteCount: 44_182_016
        )
    }

    /// Raises the real modal over the running app with sample data. Debug builds only, reached from
    /// the OpenNOW menu; the install button runs a simulated download rather than the real one.
    func presentSampleUpdate() {
        presentRequest(.available(Self.sampleRelease()))
        isPreviewingSample = true
    }

    func presentSampleStatus(_ request: Request) {
        presentRequest(request)
        isPreviewingSample = true
    }

    private func runSimulatedInstall(_ release: OpenNOWGitHubRelease) {
        simulatedInstallTask?.cancel()
        simulatedInstallTask = Task { [weak self] in
            let steps = 40
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, let self else { return }
                let received = Int64(Double(release.assetByteCount) * Double(step) / Double(steps))
                reportDownloadProgress(OpenNOWUpdateDownloadProgress(receivedBytes: received, expectedBytes: release.assetByteCount))
            }
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            reportInstallFailure("Simulated install finished. A real install would have relaunched OpenNOW here.")
            isPreviewingSample = true
        }
    }
}
#endif
