import AppKit

public typealias OPNGameLaunchWindowCompletion = @MainActor @Sendable (_ success: Bool, _ message: String) -> Void

@MainActor
public final class OPNGameLaunchBridge: NSObject, NSWindowDelegate {
    public static let shared = OPNGameLaunchBridge()

    private var windows: [ObjectIdentifier: NSWindow] = [:]

    public func launch(game: OPNCatalogGameObject, accessToken: String, idToken: String, userId: String, variantIndex: Int, completion: OPNGameLaunchWindowCompletion? = nil) {
        let token = idToken.isEmpty ? accessToken : idToken
        guard !token.isEmpty else {
            completion?(false, "Sign in again before launching a game.")
            return
        }

        let selectedVariantIndex = resolvedVariantIndex(for: game, requestedIndex: variantIndex)
        let selectedVariant = selectedVariantIndex >= 0 && selectedVariantIndex < game.variants.count ? game.variants[selectedVariantIndex] : nil
        let appId = resolvedAppId(game: game, variant: selectedVariant)
        guard !appId.isEmpty else {
            completion?(false, "This game does not include a launchable GeForce NOW app id.")
            return
        }

        OPNGameService.shared.setAccessToken(token)
        OPNGameService.shared.setAccountLinkingToken(token)
        OPNGameService.shared.setUserId(userId)
        OPNGameService.shared.setVpcId("GFN-PC")

        let title = game.title.isEmpty ? "GeForce NOW" : game.title
        let accountLinked = game.isInLibrary || selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true
        let controller = OPNStreamViewController(
            gameTitle: title,
            appId: appId,
            apiToken: token,
            accountLinked: accountLinked,
            selectedStore: selectedVariant?.appStore ?? ""
        )
        let windowFrame = streamWindowFrame()
        controller.setInitialViewFrame(NSRect(origin: .zero, size: windowFrame.size))

        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.delegate = self

        let identifier = ObjectIdentifier(window)
        windows[identifier] = window
        controller.onStreamEnd = { [weak self, weak window] success, error, _ in
            Task { @MainActor in
                completion?(success, error)
                guard let self, let window else { return }
                self.windows.removeValue(forKey: ObjectIdentifier(window))
                if window.isVisible { window.close() }
            }
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        completion?(true, "Launching \(title)...")
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let controller = window.contentViewController as? OPNStreamViewController {
            controller.shutdownForApplicationTermination()
        }
        windows.removeValue(forKey: ObjectIdentifier(window))
    }

    private func resolvedVariantIndex(for game: OPNCatalogGameObject, requestedIndex: Int) -> Int {
        if requestedIndex >= 0, requestedIndex < game.variants.count { return requestedIndex }
        if let index = game.variants.firstIndex(where: { $0.librarySelected }) { return index }
        if let index = game.variants.firstIndex(where: { $0.inLibrary }) { return index }
        return game.variants.isEmpty ? -1 : 0
    }

    private func resolvedAppId(game: OPNCatalogGameObject, variant: OPNCatalogGameVariantObject?) -> String {
        if let variant, !variant.id.isEmpty { return variant.id }
        if !game.launchAppId.isEmpty { return game.launchAppId }
        return game.id
    }

    private func streamWindowFrame() -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(visibleFrame.width * 0.86, 1180), visibleFrame.width)
        let height = min(max(visibleFrame.height * 0.86, 720), visibleFrame.height)
        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }
}
