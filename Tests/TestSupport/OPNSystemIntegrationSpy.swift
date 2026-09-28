import Foundation
@testable import OpenNOW

/// Records what the library view models ask of the desktop without touching the live pasteboard,
/// the share sheet or Finder.
@MainActor
final class OPNSystemIntegrationSpy: SystemIntegrationServing {
    private(set) var openedURLs: [URL] = []
    private(set) var revealedURLs: [URL] = []
    private(set) var copiedTexts: [String] = []
    private(set) var copiedImageURLs: [URL] = []
    private(set) var copiedFileURLs: [URL] = []
    private(set) var sharedURLs: [URL] = []
    var copyImageSucceeds = true
    var copyFileSucceeds = true
    var shareSucceeds = true

    func open(_ url: URL) { openedURLs.append(url) }

    func applicationURL(forBundleIdentifier identifier: String) -> URL? { nil }

    func openApplication(at url: URL) {}

    func copyToPasteboard(_ text: String) { copiedTexts.append(text) }

    func copyImageToPasteboard(_ imageURL: URL) -> Bool {
        copiedImageURLs.append(imageURL)
        return copyImageSucceeds
    }

    func copyFileURLToPasteboard(_ fileURL: URL) -> Bool {
        copiedFileURLs.append(fileURL)
        return copyFileSucceeds
    }

    func share(_ url: URL) -> Bool {
        sharedURLs.append(url)
        return shareSucceeds
    }

    func revealInFinder(_ url: URL) { revealedURLs.append(url) }

    func chooseDirectory(prompt: String, startingAt url: URL) -> URL? { nil }

    func applyAppIcon(toFileAt url: URL) {}
}
