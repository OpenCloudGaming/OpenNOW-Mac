import Combine
import Foundation

/// Session cache for the release history behind Settings → About → What's New.
///
/// Fetched once per app run rather than on every visit to the page: the update check already spends
/// one call an hour against the unauthenticated GitHub rate limit, and release history does not
/// change while the app is open.
@MainActor
final class OpenNOWReleaseHistoryStore: ObservableObject {
    static let shared = OpenNOWReleaseHistoryStore()

    struct Entry: Identifiable, Equatable {
        let summary: OpenNOWReleaseSummary
        let notes: OpenNOWReleaseNotes

        var id: String { summary.id }
        var version: String { summary.version }
        var publishedAt: Date? { summary.publishedAt }
        var releaseURL: String { summary.releaseURL }
    }

    enum State: Equatable {
        case idle
        case loading
        case loaded([Entry])
        case failed(String)
    }

    @Published private(set) var state = State.idle

    private var updater: OpenNOWGitHubUpdater?
    private var loadTask: Task<Void, Never>?

    private init() {}

    func attach(_ updater: OpenNOWGitHubUpdater) {
        self.updater = updater
    }

    func loadIfNeeded() {
        switch state {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        reload()
    }

    func reload() {
        guard let updater else {
            state = .failed("Release history is unavailable until OpenNOW finishes launching.")
            return
        }
        loadTask?.cancel()
        state = .loading
        loadTask = Task { [weak self] in
            do {
                let summaries = try await updater.recentReleases()
                guard !Task.isCancelled else { return }
                self?.state = .loaded(summaries.map { Entry(summary: $0, notes: OpenNOWReleaseNotesFormatter.parse($0.releaseNotes)) })
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
    }
}
