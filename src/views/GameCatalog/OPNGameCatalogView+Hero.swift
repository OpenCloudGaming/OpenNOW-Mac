import AppKit
import QuartzCore

extension OPNGameCatalogView {
    @objc func heroCandidateCount() -> Int {
        min(6, heroFeaturedGameObjects.count)
    }

    @objc func currentHeroGameObject() -> OPNCatalogGameObject? {
        let candidateCount = heroCandidateCount()
        if candidateCount > 0 {
            let target = ((currentHeroIndex % candidateCount) + candidateCount) % candidateCount
            return heroFeaturedGameObjects[target]
        }
        return fallbackHeroGameObject()
    }

    @objc func fallbackHeroGameObject() -> OPNCatalogGameObject? {
        var firstGame: OPNCatalogGameObject?
        func inspect(_ game: OPNCatalogGameObject) -> OPNCatalogGameObject? {
            if firstGame == nil { firstGame = game }
            return Self.heroImageCandidates(for: game).isEmpty ? nil : game
        }
        for panel in heroPanelObjects {
            for section in panel.sections {
                for game in section.games {
                    if let candidate = inspect(game) { return candidate }
                }
            }
        }
        for game in heroOwnedLibraryGameObjects {
            if let candidate = inspect(game) { return candidate }
        }
        for game in heroLibraryGameObjects {
            if let candidate = inspect(game) { return candidate }
        }
        return firstGame
    }

    @objc func configureHeroRotationTimer() {
        heroRotationTimer?.invalidate()
        heroRotationTimer = nil
        guard heroCandidateCount() >= 2 else { return }
        heroRotationTimer = Timer.scheduledTimer(timeInterval: 7.0, target: self, selector: #selector(heroRotationTimerFired(_:)), userInfo: nil, repeats: true)
    }

    @objc func heroRotationTimerFired(_ timer: Timer) {
        let candidateCount = heroCandidateCount()
        guard candidateCount >= 2 else { return }
        currentHeroIndex = (currentHeroIndex + 1) % candidateCount
        updateHeroTileOnly()
    }

    @objc func renderStoreWhenInitialHeroReady() {
        guard currentHeroGameObject() != nil, !initialHeroReady else {
            renderStore()
            return
        }
        preloadInitialHeroThenRender()
    }

    @objc func preloadInitialHeroThenRender() {
        guard !initialHeroPreloadInFlight else { return }
        guard let heroGame = currentHeroGameObject() else {
            initialHeroReady = true
            renderStore()
            return
        }
        let gameIdentity = Self.gameIdentity(for: heroGame)
        let candidates = Self.heroImageCandidates(for: heroGame)
        if let cachedImage = OPNUIHelpers.cachedMemoryImage(candidates: candidates, maxPixelDimension: 1600.0, resolvedURL: nil), OPNGameCatalogArtworkSupport.heroImageHasVisibleContent(cachedImage) {
            initialHeroImage = cachedImage
            initialHeroIdentity = gameIdentity
            initialHeroReady = true
            renderStore()
            return
        }
        if candidates.isEmpty {
            initialHeroImage = OPNUIHelpers.fallbackHeroArtworkImage()
            initialHeroIdentity = gameIdentity
            initialHeroReady = true
            renderStore()
            return
        }
        initialHeroPreloadInFlight = true
        let preloadGeneration = initialHeroPreloadGeneration
        var completed = false
        var remainingLoads = min(2, candidates.count)
        for candidateURL in candidates.prefix(2) {
            let token = OPNUIHelpers.loadImageForURLCancellable(urlString: candidateURL, maxPixelDimension: 1600.0) { [weak self] image, _, _ in
                guard let self, !completed, preloadGeneration == self.initialHeroPreloadGeneration else { return }
                if let image, OPNGameCatalogArtworkSupport.heroImageHasVisibleContent(image) {
                    completed = true
                    self.initialHeroImage = image
                } else {
                    remainingLoads -= 1
                    guard remainingLoads <= 0 else { return }
                    completed = true
                    self.initialHeroImage = OPNUIHelpers.fallbackHeroArtworkImage()
                }
                self.initialHeroIdentity = gameIdentity
                self.initialHeroReady = true
                self.initialHeroPreloadInFlight = false
                self.renderStore()
            }
            trackHeroImageLoadToken(token)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !completed, preloadGeneration == self.initialHeroPreloadGeneration else { return }
            completed = true
            self.initialHeroImage = OPNUIHelpers.fallbackHeroArtworkImage()
            self.initialHeroIdentity = gameIdentity
            self.initialHeroReady = true
            self.initialHeroPreloadInFlight = false
            self.renderStore()
        }
    }

    @objc func cancelHeroImageLoads() {
        for token in heroImageLoadTokens.compactMap({ $0 as? OpnImageLoadToken }) { token.cancel() }
        heroImageLoadTokens.removeAllObjects()
    }

    @objc func trackHeroImageLoadToken(_ token: OpnImageLoadToken?) {
        guard let token else { return }
        heroImageLoadTokens.add(token)
        if heroImageLoadTokens.count > 12 {
            heroImageLoadTokens.removeObjects(in: NSRange(location: 0, length: heroImageLoadTokens.count - 8))
        }
    }

    @objc func cancelPrefetchImageLoads() {
        for token in prefetchImageLoadTokens.compactMap({ $0 as? OpnImageLoadToken }) { token.cancel() }
        prefetchImageLoadTokens.removeAllObjects()
    }

    @objc func trackPrefetchImageLoadToken(_ token: OpnImageLoadToken?) {
        guard let token else { return }
        prefetchImageLoadTokens.add(token)
        if prefetchImageLoadTokens.count > 36 {
            let removeCount = prefetchImageLoadTokens.count - 24
            for index in 0..<removeCount {
                if let token = prefetchImageLoadTokens[index] as? OpnImageLoadToken { token.cancel() }
            }
            prefetchImageLoadTokens.removeObjects(in: NSRange(location: 0, length: removeCount))
        }
    }

    @objc func prefetchHeroArtworkCandidates() {
        cancelPrefetchImageLoads()
        let candidateCount = heroCandidateCount()
        guard candidateCount > 0 else { return }
        for game in heroFeaturedGameObjects.prefix(candidateCount) {
            let candidates = Self.heroImageCandidates(for: game)
            if !candidates.isEmpty {
                trackPrefetchImageLoadToken(OPNUIHelpers.prefetchImage(candidates: candidates, maxPixelDimension: 1600.0))
            }
            let logoCandidates = Self.logoCandidates(for: game)
            if !logoCandidates.isEmpty {
                trackPrefetchImageLoadToken(OPNUIHelpers.prefetchImage(candidates: logoCandidates, maxPixelDimension: 720.0))
            }
        }
    }

    @objc func addDesktopHeroStageForGameObject(_ game: OPNCatalogGameObject, y: CGFloat, contentX: CGFloat, width: CGFloat, height: CGFloat) {
        desktopFeaturedHeroFrame = NSRect(x: contentX, y: y, width: width, height: height)
        let container = NSView(frame: desktopFeaturedHeroFrame)
        container.autoresizingMask = [.width]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.masksToBounds = true
        documentView.addSubview(container)
        desktopHeroContainer = container

        let artwork = OPNHeroArtworkView(frame: container.bounds)
        artwork.autoresizingMask = [.width, .height]
        artwork.image = OPNUIHelpers.fallbackHeroArtworkImage()
        container.addSubview(artwork, positioned: .below, relativeTo: nil)
        desktopHeroArtworkView = artwork

        addDesktopHeroLogoForGameObject(game, to: container)
        updateDesktopHeroElements(for: game, animated: false)
        desktopFeaturedHeroViews.add(container)
    }

    @objc func addDesktopHeroLogoForGameObject(_ game: OPNCatalogGameObject, to container: NSView?) {
        guard let container else { return }
        let textShadow = NSShadow()
        textShadow.shadowBlurRadius = 18.0
        textShadow.shadowOffset = NSSize(width: 0.0, height: -2.0)
        textShadow.shadowColor = OPNUIHelpers.color(rgb: 0x000000, alpha: 0.82)

        let titleFallback = OPNUIHelpers.label(text: "", frame: OPNGameCatalogArtworkSupport.heroLogoFallbackFrame(container.bounds, artworkImage: OPNUIHelpers.fallbackHeroArtworkImage()), size: 42.0, color: OPNUIHelpers.color(rgb: 0xF5F5F7, alpha: 1.0), weight: .black, alignment: .left)
        titleFallback.maximumNumberOfLines = 2
        titleFallback.lineBreakMode = .byWordWrapping
        titleFallback.shadow = textShadow
        titleFallback.wantsLayer = true
        titleFallback.layer?.zPosition = 1000.0
        container.addSubview(titleFallback, positioned: .above, relativeTo: nil)
        desktopHeroTitleFallback = titleFallback

        let logoView = NSImageView(frame: OPNGameCatalogArtworkSupport.heroLogoFallbackFrame(container.bounds, artworkImage: OPNUIHelpers.fallbackHeroArtworkImage()))
        logoView.isHidden = true
        OPNGameCatalogArtworkSupport.configureHeroLogoImageView(logoView, zPosition: 1001.0)
        container.addSubview(logoView, positioned: .above, relativeTo: nil)
        desktopHeroLogoView = logoView
    }

    @objc func setDesktopHeroArtworkImage(_ image: NSImage?, animated: Bool) {
        guard let image, let container = desktopHeroContainer, let artworkView = desktopHeroArtworkView else { return }
        if !animated || artworkView.image == nil || artworkView.superview == nil {
            desktopHeroArtworkTransitionView?.removeFromSuperview()
            desktopHeroArtworkTransitionView = nil
            artworkView.image = image
            artworkView.alphaValue = 1.0
            updateDesktopHeroLogoFrame()
            return
        }
        if artworkView.image === image && desktopHeroArtworkTransitionView == nil {
            updateDesktopHeroLogoFrame()
            return
        }
        if desktopHeroArtworkTransitionView?.image === image { return }
        desktopHeroArtworkTransitionView?.removeFromSuperview()
        let transitionView = OPNHeroArtworkView(frame: artworkView.frame)
        transitionView.autoresizingMask = [.width, .height]
        transitionView.image = image
        transitionView.alphaValue = 0.0
        container.addSubview(transitionView, positioned: .above, relativeTo: artworkView)
        desktopHeroArtworkTransitionView = transitionView
        if let titleFallback = desktopHeroTitleFallback, let logoView = desktopHeroLogoView {
            OPNGameCatalogArtworkSupport.bringHeroLogoToFront(container: container, titleFallback: titleFallback, logoView: logoView)
        }
        if desktopHeroLogoTransitionView?.superview == container, let logoTransition = desktopHeroLogoTransitionView {
            container.addSubview(logoTransition, positioned: .above, relativeTo: nil)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = OPNGameCatalogLayoutSupport.storeHeroBackgroundFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            transitionView.animator().alphaValue = 1.0
        } completionHandler: { [weak self, weak transitionView] in
            MainActor.assumeIsolated {
                guard let self, let transitionView, self.desktopHeroArtworkTransitionView === transitionView else { return }
                self.desktopHeroArtworkView?.image = image
                self.desktopHeroArtworkView?.alphaValue = 1.0
                transitionView.removeFromSuperview()
                self.desktopHeroArtworkTransitionView = nil
                self.updateDesktopHeroLogoFrame()
            }
        }
    }

    @objc func newDesktopHeroLogoTransitionView(with image: NSImage?, frame: NSRect) -> NSImageView {
        let transitionView = NSImageView(frame: frame)
        transitionView.image = image
        transitionView.alphaValue = 0.0
        transitionView.isHidden = false
        OPNGameCatalogArtworkSupport.configureHeroLogoImageView(transitionView, zPosition: 1002.0)
        return transitionView
    }

    @objc func setDesktopHeroLogoImage(_ image: NSImage?, animated: Bool) {
        guard let container = desktopHeroContainer, let logoView = desktopHeroLogoView, let titleFallback = desktopHeroTitleFallback else { return }
        desktopHeroLogoTransitionView?.removeFromSuperview()
        desktopHeroLogoTransitionView = nil
        if !animated {
            logoView.image = image
            logoView.frame = image.map { OPNGameCatalogArtworkSupport.heroLogoFrame(for: $0, bounds: container.bounds, artworkImage: desktopHeroArtworkView?.image) } ?? OPNGameCatalogArtworkSupport.heroLogoFallbackFrame(container.bounds, artworkImage: desktopHeroArtworkView?.image)
            logoView.alphaValue = 1.0
            logoView.isHidden = image == nil
            titleFallback.isHidden = image != nil
            titleFallback.alphaValue = 1.0
            OPNGameCatalogArtworkSupport.bringHeroLogoToFront(container: container, titleFallback: titleFallback, logoView: logoView)
            return
        }
        guard let image else {
            let generation = desktopHeroGeneration
            titleFallback.alphaValue = 0.0
            titleFallback.isHidden = false
            DispatchQueue.main.asyncAfter(deadline: .now() + OPNGameCatalogLayoutSupport.storeHeroLogoFadeDelay) { [weak self] in
                guard let self, self.desktopHeroContainer != nil, self.desktopHeroGeneration == generation else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = OPNGameCatalogLayoutSupport.storeHeroLogoFadeDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.desktopHeroLogoView?.animator().alphaValue = 0.0
                    self.desktopHeroTitleFallback?.animator().alphaValue = 1.0
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.desktopHeroGeneration == generation else { return }
                        self.desktopHeroLogoView?.image = nil
                        self.desktopHeroLogoView?.isHidden = true
                        self.desktopHeroLogoView?.alphaValue = 1.0
                    }
                }
            }
            return
        }
        let logoFrame = OPNGameCatalogArtworkSupport.heroLogoFrame(for: image, bounds: container.bounds, artworkImage: desktopHeroArtworkView?.image)
        let transitionView = newDesktopHeroLogoTransitionView(with: image, frame: logoFrame)
        container.addSubview(transitionView, positioned: .above, relativeTo: nil)
        desktopHeroLogoTransitionView = transitionView
        OPNGameCatalogArtworkSupport.bringHeroLogoToFront(container: container, titleFallback: titleFallback, logoView: logoView)
        container.addSubview(transitionView, positioned: .above, relativeTo: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + OPNGameCatalogLayoutSupport.storeHeroLogoFadeDelay) { [weak self, weak transitionView] in
            guard let self, let transitionView, self.desktopHeroLogoTransitionView === transitionView else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = OPNGameCatalogLayoutSupport.storeHeroLogoFadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                transitionView.animator().alphaValue = 1.0
                self.desktopHeroLogoView?.animator().alphaValue = 0.0
                self.desktopHeroTitleFallback?.animator().alphaValue = 0.0
            } completionHandler: { [weak self, weak transitionView] in
                MainActor.assumeIsolated {
                    guard let self, let transitionView, self.desktopHeroLogoTransitionView === transitionView else { return }
                    self.desktopHeroLogoView?.frame = logoFrame
                    self.desktopHeroLogoView?.image = image
                    self.desktopHeroLogoView?.isHidden = false
                    self.desktopHeroLogoView?.alphaValue = 1.0
                    self.desktopHeroTitleFallback?.isHidden = true
                    self.desktopHeroTitleFallback?.alphaValue = 1.0
                    transitionView.removeFromSuperview()
                    self.desktopHeroLogoTransitionView = nil
                    if let container = self.desktopHeroContainer, let titleFallback = self.desktopHeroTitleFallback, let logoView = self.desktopHeroLogoView {
                        OPNGameCatalogArtworkSupport.bringHeroLogoToFront(container: container, titleFallback: titleFallback, logoView: logoView)
                    }
                }
            }
        }
    }

    @objc(updateDesktopHeroElementsForGameObject:animated:)
    func updateDesktopHeroElements(for game: OPNCatalogGameObject, animated: Bool) {
        guard let container = desktopHeroContainer, desktopHeroArtworkView != nil, let titleFallback = desktopHeroTitleFallback, let logoView = desktopHeroLogoView else { return }
        desktopHeroGeneration += 1
        let generation = desktopHeroGeneration
        let gameIdentity = Self.gameIdentity(for: game)
        desktopHeroIdentity = gameIdentity
        OPNGameCatalogArtworkSupport.bringHeroLogoToFront(container: container, titleFallback: titleFallback, logoView: logoView)

        titleFallback.stringValue = game.title
        titleFallback.frame = OPNGameCatalogArtworkSupport.heroLogoFallbackFrame(container.bounds, artworkImage: desktopHeroArtworkView?.image)
        if !animated {
            titleFallback.isHidden = false
            titleFallback.alphaValue = 1.0
            setDesktopHeroLogoImage(nil, animated: false)
        }
        let heroCandidates = Self.heroImageCandidates(for: game)
        let cachedImage = initialHeroIdentity == gameIdentity && initialHeroImage.map(OPNGameCatalogArtworkSupport.heroImageHasVisibleContent) == true
            ? initialHeroImage
            : OPNUIHelpers.cachedMemoryImage(candidates: heroCandidates, maxPixelDimension: 1600.0, resolvedURL: nil)
        if let cachedImage, OPNGameCatalogArtworkSupport.heroImageHasVisibleContent(cachedImage) {
            setDesktopHeroArtworkImage(cachedImage, animated: animated)
            updateDesktopHeroLogoFrame()
        } else if !animated {
            setDesktopHeroArtworkImage(OPNUIHelpers.fallbackHeroArtworkImage(), animated: false)
            updateDesktopHeroLogoFrame()
        }
        loadFeaturedHeroImage(for: desktopHeroArtworkView, gameIdentity: gameIdentity, candidates: heroCandidates, index: 0, animated: animated) { [weak self] _ in
            guard let self, generation == self.desktopHeroGeneration else { return }
        }
        loadDesktopHeroLogo(for: game, generation: generation, animated: animated)
    }

    @objc func updateDesktopHeroLogoFrame() {
        guard let container = desktopHeroContainer, let artworkView = desktopHeroArtworkView, let titleFallback = desktopHeroTitleFallback, let logoView = desktopHeroLogoView else { return }
        let artworkImage = artworkView.image
        titleFallback.frame = OPNGameCatalogArtworkSupport.heroLogoFallbackFrame(container.bounds, artworkImage: artworkImage)
        logoView.frame = logoView.image.map { OPNGameCatalogArtworkSupport.heroLogoFrame(for: $0, bounds: container.bounds, artworkImage: artworkImage) } ?? OPNGameCatalogArtworkSupport.heroLogoFallbackFrame(container.bounds, artworkImage: artworkImage)
        if let transitionImage = desktopHeroLogoTransitionView?.image {
            desktopHeroLogoTransitionView?.frame = OPNGameCatalogArtworkSupport.heroLogoFrame(for: transitionImage, bounds: container.bounds, artworkImage: artworkImage)
        }
        OPNGameCatalogArtworkSupport.bringHeroLogoToFront(container: container, titleFallback: titleFallback, logoView: logoView)
        if desktopHeroLogoTransitionView?.superview == container, let transitionView = desktopHeroLogoTransitionView {
            container.addSubview(transitionView, positioned: .above, relativeTo: nil)
        }
    }

    @objc(loadDesktopHeroLogoForGameObject:generation:animated:)
    func loadDesktopHeroLogo(for game: OPNCatalogGameObject, generation: Int, animated: Bool) {
        let candidates = Self.logoCandidates(for: game)
        let applyLogoImage: (NSImage?) -> Void = { image in
            DispatchQueue.global(qos: .utility).async {
                let visibleLogo = image.flatMap(OPNGameCatalogArtworkSupport.visibleLogoImage)
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.desktopHeroGeneration, self.desktopHeroContainer?.superview != nil else { return }
                    self.setDesktopHeroLogoImage(visibleLogo, animated: animated)
                }
            }
        }
        if let cachedLogo = OPNUIHelpers.cachedMemoryImage(candidates: candidates, maxPixelDimension: 720.0, resolvedURL: nil) {
            applyLogoImage(cachedLogo)
            return
        }
        let token = OPNUIHelpers.loadImageFromCandidatesCancellable(candidates: candidates, maxPixelDimension: 720.0) { [weak self] image, _, _ in
            guard let self, generation == self.desktopHeroGeneration, self.desktopHeroContainer?.superview != nil else { return }
            guard let image else {
                self.setDesktopHeroLogoImage(nil, animated: animated)
                return
            }
            applyLogoImage(image)
        }
        trackHeroImageLoadToken(token)
    }

    @objc(loadFeaturedHeroImageForView:gameIdentity:candidates:index:animated:completion:)
    func loadFeaturedHeroImage(for view: OPNHeroArtworkView?, gameIdentity: String, candidates: [String], index: Int, animated: Bool, completion: ((Bool) -> Void)?) {
        guard let view else { return }
        if index >= candidates.count {
            if view === desktopHeroArtworkView {
                if animated {
                    completion?(false)
                    return
                }
                setDesktopHeroArtworkImage(OPNUIHelpers.fallbackHeroArtworkImage(), animated: animated)
            } else {
                view.image = OPNUIHelpers.fallbackHeroArtworkImage()
            }
            view.alphaValue = 1.0
            if view === desktopHeroArtworkView { updateDesktopHeroLogoFrame() }
            completion?(view.image != nil)
            return
        }
        guard !candidates[index].isEmpty else {
            loadFeaturedHeroImage(for: view, gameIdentity: gameIdentity, candidates: candidates, index: index + 1, animated: animated, completion: completion)
            return
        }
        let remainingCandidates = Array(candidates[index...])
        if let cachedImage = OPNUIHelpers.cachedMemoryImage(candidates: remainingCandidates, maxPixelDimension: 1600.0, resolvedURL: nil), OPNGameCatalogArtworkSupport.heroImageHasVisibleContent(cachedImage) {
            applyHeroImage(cachedImage, to: view, animated: animated, completion: completion)
            return
        }
        var completed = false
        let activeCandidates = Array(remainingCandidates.prefix(2))
        var remainingLoads = activeCandidates.count
        for candidateURL in activeCandidates {
            let token = OPNUIHelpers.loadImageForURLCancellable(urlString: candidateURL, maxPixelDimension: 1600.0) { [weak self, weak view] image, _, _ in
                guard let self, let view, view.superview != nil, !completed else { return }
                if view === self.desktopHeroArtworkView, self.desktopHeroIdentity != gameIdentity { return }
                guard let image, OPNGameCatalogArtworkSupport.heroImageHasVisibleContent(image) else {
                    remainingLoads -= 1
                    guard remainingLoads <= 0 else { return }
                    completed = true
                    if view === self.desktopHeroArtworkView {
                        if animated {
                            completion?(false)
                            return
                        }
                        self.setDesktopHeroArtworkImage(OPNUIHelpers.fallbackHeroArtworkImage(), animated: animated)
                    } else {
                        view.image = OPNUIHelpers.fallbackHeroArtworkImage()
                    }
                    view.alphaValue = 1.0
                    if view === self.desktopHeroArtworkView { self.updateDesktopHeroLogoFrame() }
                    completion?(view.image != nil)
                    return
                }
                completed = true
                self.applyHeroImage(image, to: view, animated: animated, completion: completion)
            }
            trackHeroImageLoadToken(token)
        }
    }

    @objc func updateHeroTileOnly() {
        updateDesktopFeaturedHeroOnly()
    }

    @objc func updateDesktopFeaturedHeroOnly() {
        guard let heroGame = currentHeroGameObject(), desktopHeroContainer != nil, desktopHeroArtworkView != nil, !desktopFeaturedHeroFrame.isEmpty else {
            renderStore()
            return
        }
        let expectedHeroHeight = OPNGameCatalogLayoutSupport.heroHeight(forWidth: bounds.width, viewportHeight: bounds.height)
        if abs(expectedHeroHeight - desktopFeaturedHeroFrame.height) > 1.0 {
            renderStore()
            return
        }
        updateDesktopHeroElements(for: heroGame, animated: true)
    }

    private func applyHeroImage(_ image: NSImage, to view: OPNHeroArtworkView, animated: Bool, completion: ((Bool) -> Void)?) {
        if view === desktopHeroArtworkView {
            setDesktopHeroArtworkImage(image, animated: animated)
        } else {
            view.image = image
        }
        view.alphaValue = 1.0
        if view === desktopHeroArtworkView {
            let expectedHeroHeight = OPNGameCatalogLayoutSupport.heroHeight(forWidth: bounds.width, viewportHeight: bounds.height)
            if abs(expectedHeroHeight - desktopFeaturedHeroFrame.height) > 1.0 {
                scheduleRenderStore()
                completion?(true)
                return
            }
            updateDesktopHeroLogoFrame()
        }
        completion?(true)
    }

    private static func gameIdentity(for game: OPNCatalogGameObject) -> String {
        if !game.id.isEmpty { return game.id }
        if !game.uuid.isEmpty { return game.uuid }
        if !game.launchAppId.isEmpty { return game.launchAppId }
        return game.title
    }

    private static func heroImageCandidates(for game: OPNCatalogGameObject) -> [String] {
        var urls: [String] = []
        for type in ["MARQUEE_HERO_IMAGE", "HERO_IMAGE", "TV_BANNER", "FEATURE_IMAGE", "KEY_ART", "KEY_IMAGE", "GAME_BOX_ART"] {
            appendImageType(type, from: game, to: &urls)
        }
        appendUnique(game.heroImageUrl, to: &urls)
        appendUnique(game.imageUrl, to: &urls)
        for screenshot in game.screenshotUrls { appendUnique(screenshot, to: &urls) }
        return urls
    }

    private static func logoCandidates(for game: OPNCatalogGameObject) -> [String] {
        var urls: [String] = []
        for type in ["GAME_LOGO", "LOGO", "TITLE_LOGO"] {
            appendImageType(type, from: game, to: &urls)
        }
        return urls
    }

    private static func appendImageType(_ type: String, from game: OPNCatalogGameObject, to urls: inout [String]) {
        for url in game.imageUrlsByType[type] ?? [] { appendUnique(url, to: &urls) }
    }

    private static func appendUnique(_ value: String, to urls: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !urls.contains(trimmed) else { return }
        urls.append(trimmed)
    }
}
