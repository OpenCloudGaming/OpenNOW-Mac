import AppKit
import Testing
@testable import OpenNOW

@Test @MainActor func streamWindowConstrainsTitlebarExclusiveContentToVideoAspect() async throws {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1000, height: 625),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    let coordinator = StreamWindowAspectCoordinator()
    let originalTopEdge = window.frame.maxY
    defer {
        coordinator.detach()
        window.close()
    }

    coordinator.attach(window)
    coordinator.update(aspectRatio: 1.6, isLocked: true, usesTitlebarExclusiveContent: true)
    #expect(window.styleMask.contains(.fullSizeContentView))
    await applyPendingWindowChanges()

    let contentView = try #require(window.contentView)
    #expect(!window.styleMask.contains(.fullSizeContentView))
    #expect(abs(contentView.bounds.width / contentView.bounds.height - 1.6) < 0.001)
    #expect(abs(window.contentLayoutRect.width - contentView.bounds.width) < 0.001)
    #expect(abs(window.contentLayoutRect.height - contentView.bounds.height) < 0.001)
    #expect(window.aspectRatio == .zero)
    #expect(window.contentAspectRatio == NSSize(width: 1.6, height: 1))
    #expect(abs(window.frame.maxY - originalTopEdge) < 0.001)

    coordinator.update(aspectRatio: 1.6, isLocked: true, usesTitlebarExclusiveContent: false)
    await applyPendingWindowChanges()

    #expect(window.styleMask.contains(.fullSizeContentView))
    #expect(window.contentAspectRatio == .zero)
    #expect(window.aspectRatio == NSSize(width: 1.6, height: 1))
    #expect(abs(window.frame.maxY - originalTopEdge) < 0.001)
}

@Test @MainActor func unlockingStreamWindowRestoresOriginalFullSizeContentStyle() async {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 1000, height: 625),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    let coordinator = StreamWindowAspectCoordinator()
    defer {
        coordinator.detach()
        window.close()
    }

    coordinator.attach(window)
    coordinator.update(aspectRatio: 1.6, isLocked: true, usesTitlebarExclusiveContent: true)
    await applyPendingWindowChanges()
    coordinator.update(aspectRatio: 1.6, isLocked: false, usesTitlebarExclusiveContent: true)
    await applyPendingWindowChanges()

    #expect(window.styleMask.contains(.fullSizeContentView))
    #expect(window.contentAspectRatio == .zero)
    #expect(window.aspectRatio == .zero)
}

@Test @MainActor func streamWindowPreservesAspectWhenMinimumContentHeightRequiresMoreWidth() async throws {
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.contentMinSize = NSSize(width: 800, height: 600)
    let coordinator = StreamWindowAspectCoordinator()
    defer {
        coordinator.detach()
        window.close()
    }

    coordinator.attach(window)
    coordinator.update(aspectRatio: 1.6, isLocked: true, usesTitlebarExclusiveContent: true)
    await applyPendingWindowChanges()

    let contentView = try #require(window.contentView)
    #expect(contentView.bounds.width >= 960)
    #expect(contentView.bounds.height >= 600)
    #expect(abs(contentView.bounds.width / contentView.bounds.height - 1.6) < 0.001)
}

@MainActor private func applyPendingWindowChanges() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}
