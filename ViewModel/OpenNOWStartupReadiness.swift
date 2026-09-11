//  Lets the launch splash hold its last frame until the page behind it has something real to draw.
//
//  Dismissal used to be a plain timer. A slow session restore pushed the catalog's first layout past
//  the fade, so the splash uncovered a page that then settled - the top bar took its full height, the
//  marquee skeleton swapped for the hero - in full view.
//

import Foundation

@MainActor
final class OpenNOWStartupReadiness {
    static let shared = OpenNOWStartupReadiness()

    private(set) var isContentReady = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markContentReady() {
        guard !isContentReady else { return }
        isContentReady = true
        resumeWaiters()
    }

    /// Returns as soon as the page reports content, or when `timeout` elapses - a page that will
    /// never load (no network, an expired session, a failed fetch) must not pin the splash open.
    func waitForContent(timeout: Duration) async {
        guard !isContentReady else { return }
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            resumeWaiters()
        }
        await withCheckedContinuation { waiters.append($0) }
        timeoutTask.cancel()
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }
}
