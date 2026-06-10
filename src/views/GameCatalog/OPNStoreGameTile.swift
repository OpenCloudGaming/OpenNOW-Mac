import AppKit
import QuartzCore

@objc(OPNStoreGameTile)
@objcMembers
final class OPNStoreGameTile: NSView {
    let gameObject: OPNCatalogGameObject
    let prominent: Bool
    var selectedVariantIndex: Int32 {
        didSet {
            if !gameObject.variants.isEmpty {
                selectedVariantIndex = Int32(max(0, min(gameObject.variants.count - 1, Int(selectedVariantIndex))))
            }
            availabilityLabel.stringValue = Self.availabilityTitle(gameObject: gameObject, variantIndex: Int(selectedVariantIndex))
            playButton.title = Self.primaryActionTitle(gameObject: gameObject, variantIndex: Int(selectedVariantIndex), prominent: prominent)
            updateStoreIconSelection()
        }
    }
    var imageRevealDelay: TimeInterval = 0
    var onSelect: (() -> Void)?
    var onBuy: ((String) -> Void)?
    var onMarkUnowned: (() -> Void)?
    var onHover: (() -> Void)?

    private let imageView = NSImageView(frame: .zero)
    private let gradientOverlay = NSView(frame: .zero)
    private let gradientLayer = CAGradientLayer()
    private let accentLayer = CALayer()
    private let shineLayer = CALayer()
    private let storeBadgeView = NSView(frame: .zero)
    private let storeIconView = NSImageView(frame: .zero)
    private var storeIconViews: [NSImageView] = []
    private var storeIconVariantIndexes: [Int] = []
    private let titleLabel: NSTextField
    private let metaLabel: NSTextField
    private let featureLabel: NSTextField
    private let availabilityLabel: NSTextField
    private let playButton = NSButton(frame: .zero)
    private var trackingAreaReference: NSTrackingArea?
    private var storeFocused = false
    private var pendingMouseSelection = false
    private var draggingRail = false
    private var lastDragLocationInWindow = NSPoint.zero
    private var imageLoadRequested = false
    private var imageLoadGeneration = 0
    private var imageLoadToken: OpnImageLoadToken?

    init(frame frameRect: NSRect, gameObject: OPNCatalogGameObject, prominent: Bool) {
        self.gameObject = gameObject
        self.prominent = prominent
        selectedVariantIndex = gameObject.variants.isEmpty ? -1 : 0
        titleLabel = OPNUIHelpers.label(text: gameObject.title.isEmpty ? "Untitled" : gameObject.title, frame: .zero, size: prominent ? 31 : 15, color: Self.color(0xF5F5F7), weight: .bold, alignment: .left)
        metaLabel = OPNUIHelpers.label(text: Self.primaryGenre(gameObject), frame: .zero, size: prominent ? 13 : 11.5, color: Self.color(0xDBDEE5, alpha: 0.86), weight: .semibold, alignment: .left)
        featureLabel = OPNUIHelpers.label(text: Self.featureSummary(gameObject), frame: .zero, size: prominent ? 13 : 11, color: Self.color(0xB9BDC7, alpha: 0.82), weight: .medium, alignment: .left)
        availabilityLabel = OPNUIHelpers.label(text: "Cloud ready", frame: .zero, size: prominent ? 12 : 10.5, color: Self.color(0x34C759, alpha: 0.96), weight: .bold, alignment: .right)
        super.init(frame: frameRect)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit { imageLoadToken?.cancel() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitView = super.hitTest(point) else { return nil }
        if hitView == playButton || hitView.isDescendant(of: playButton) { return hitView }
        return self
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        imageView.frame = bounds
        gradientOverlay.frame = bounds
        gradientLayer.frame = gradientOverlay.bounds
        shineLayer.frame = NSRect(x: width * 0.10, y: height - 5, width: width * 0.80, height: 5)
        shineLayer.cornerRadius = 2.5
        accentLayer.frame = prominent ? NSRect(x: 0, y: 0, width: 5, height: height) : NSRect(x: 0, y: 0, width: width, height: 3)
        if prominent { layoutProminent(width: width, height: height) } else { layoutCompact(width: width, height: height) }
        titleLabel.isHidden = !prominent
        metaLabel.isHidden = !prominent
        featureLabel.isHidden = !prominent
        availabilityLabel.isHidden = !prominent
    }

    func setStoreFocused(_ focused: Bool) {
        storeFocused = focused
        alphaValue = 1
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        layer?.borderWidth = focused ? 2.5 : 1.25
        layer?.borderColor = (focused ? Self.color(0x34C759, alpha: 0.98) : Self.color(0xFFFFFF, alpha: prominent ? 0.18 : 0.12)).cgColor
        updateStoreIconSelection()
        shineLayer.opacity = Float(focused ? 1 : (prominent ? 0.88 : 0.52))
        layer?.shadowColor = Self.color(0x34C759).cgColor
        layer?.shadowOpacity = focused ? 0.38 : 0
        layer?.shadowRadius = focused ? 26 : 0
        layer?.shadowOffset = .zero
        layer?.zPosition = focused ? 10 : 0
        layer?.transform = CATransform3DIdentity
        CATransaction.commit()
        playButton.isHidden = !(prominent || focused)
    }

    func cycleSelectedVariant() {
        guard gameObject.variants.count > 1, !storeIconVariantIndexes.isEmpty else { return }
        let currentIconIndex = storeIconVariantIndexes.firstIndex(of: Int(selectedVariantIndex))
        let nextIconIndex = currentIconIndex.map { ($0 + 1) % storeIconVariantIndexes.count } ?? 0
        selectedVariantIndex = Int32(storeIconVariantIndexes[nextIconIndex])
    }

    func activate() { selectPressed() }

    func imageCandidates() -> [String] { Self.imageCandidates(gameObject: gameObject, prominent: prominent) }

    func ensureImageLoaded() {
        guard !imageLoadRequested else { return }
        imageLoadRequested = true
        loadImage()
    }

    func cancelImageLoad() {
        guard let imageLoadToken else { return }
        imageLoadToken.cancel()
        self.imageLoadToken = nil
        imageLoadRequested = imageView.image != nil && imageView.image !== OPNGameCatalogArtworkSupport.fallbackArtworkImage()
        imageLoadGeneration += 1
    }

    func resetMouseTrackingIfOutside() {
        guard !prominent, !storeFocused, let window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        if !bounds.contains(convert(windowPoint, from: nil)) {
            playButton.isHidden = true
            layer?.borderColor = Self.color(0xFFFFFF, alpha: 0.12).cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference, trackingAreas.contains(trackingAreaReference) { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        trackingAreaReference = area
        addTrackingArea(area)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let appId = Self.gameProfileAppId(gameObject: gameObject, variantIndex: Int(selectedVariantIndex))
        let hasAppId = !appId.isEmpty
        let hasProfile = hasAppId && OPNStreamPreferences.profileExists(forGame: appId)
        let profileEnabled = hasAppId && OPNStreamPreferences.profileEnabled(forGame: appId)
        let menu = NSMenu(title: "Game Actions")
        let saveProfileItem = NSMenuItem(title: "Save Current Stream Settings as Game Profile", action: #selector(saveCurrentStreamSettingsAsProfilePressed(_:)), keyEquivalent: "")
        saveProfileItem.target = self
        saveProfileItem.isEnabled = hasAppId
        menu.addItem(saveProfileItem)
        let toggleProfileItem = NSMenuItem(title: "Use Game Stream Profile", action: #selector(togglePerGameStreamProfilePressed(_:)), keyEquivalent: "")
        toggleProfileItem.target = self
        toggleProfileItem.isEnabled = hasProfile
        toggleProfileItem.state = profileEnabled ? .on : .off
        menu.addItem(toggleProfileItem)
        let deleteProfileItem = NSMenuItem(title: "Delete Game Stream Profile", action: #selector(deletePerGameStreamProfilePressed(_:)), keyEquivalent: "")
        deleteProfileItem.target = self
        deleteProfileItem.isEnabled = hasProfile
        menu.addItem(deleteProfileItem)
        guard Self.variantCanBeMarkedUnowned(gameObject: gameObject, variantIndex: Int(selectedVariantIndex)) else { return menu }
        menu.addItem(.separator())
        let markUnownedItem = NSMenuItem(title: "Mark Selected Store as Unowned", action: #selector(markUnownedPressed(_:)), keyEquivalent: "")
        markUnownedItem.target = self
        menu.addItem(markUnownedItem)
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let badgePoint = storeBadgeView.convert(localPoint, from: self)
        pendingMouseSelection = false
        draggingRail = false
        for (index, iconView) in storeIconViews.enumerated() {
            if !iconView.bounds.contains(iconView.convert(badgePoint, from: storeBadgeView)) { continue }
            if index < storeIconVariantIndexes.count {
                let variantIndex = storeIconVariantIndexes[index]
                if variantIndex >= 0 && variantIndex < gameObject.variants.count { selectedVariantIndex = Int32(variantIndex) }
            }
            return
        }
        pendingMouseSelection = true
        lastDragLocationInWindow = event.locationInWindow
        if let scrollView = enclosingScrollView, scrollView.responds(to: Selector(("beginDragScrollingAtTime:"))) {
            scrollView.perform(Selector(("beginDragScrollingAtTime:")), with: event.timestamp as NSNumber)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if !pendingMouseSelection && !draggingRail {
            super.mouseDragged(with: event)
            return
        }
        let location = event.locationInWindow
        let deltaX = lastDragLocationInWindow.x - location.x
        let deltaY = lastDragLocationInWindow.y - location.y
        let dragThresholdReached = draggingRail || hypot(deltaX, deltaY) >= 4
        lastDragLocationInWindow = location
        guard dragThresholdReached else { return }
        pendingMouseSelection = false
        draggingRail = true
        if let scrollView = enclosingScrollView, scrollView.responds(to: Selector(("dragScrollHorizontallyByDelta:timestamp:"))) {
            scrollView.perform(Selector(("dragScrollHorizontallyByDelta:timestamp:")), with: deltaX as NSNumber, with: event.timestamp as NSNumber)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let shouldSelect = pendingMouseSelection && !draggingRail
        let shouldContinueScroll = draggingRail
        pendingMouseSelection = false
        draggingRail = false
        if shouldContinueScroll, let scrollView = enclosingScrollView, scrollView.responds(to: Selector(("endDragScrollingWithInertia"))) {
            scrollView.perform(Selector(("endDragScrollingWithInertia")))
        }
        if shouldSelect { selectPressed() }
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
        if !prominent { playButton.isHidden = false }
        if !storeFocused { layer?.borderColor = Self.color(0x34C759, alpha: 0.42).cgColor }
    }

    override func mouseExited(with event: NSEvent) {
        if !prominent && !storeFocused { playButton.isHidden = true }
        if !storeFocused { layer?.borderColor = Self.color(0xFFFFFF, alpha: prominent ? 0.18 : 0.12).cgColor }
    }

    private func configureView() {
        wantsLayer = true
        layer?.cornerRadius = prominent ? 28 : 18
        layer?.masksToBounds = true
        layer?.backgroundColor = Self.color(0x070A0C, alpha: 0.92).cgColor
        layer?.borderWidth = 1.25
        layer?.borderColor = Self.color(0xFFFFFF, alpha: prominent ? 0.18 : 0.12).cgColor
        imageView.frame = bounds
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = Self.color(0x11161A).cgColor
        addSubview(imageView)
        gradientOverlay.frame = bounds
        gradientOverlay.wantsLayer = true
        gradientLayer.colors = [Self.color(0x000000, alpha: prominent ? 0.08 : 0.02).cgColor, Self.color(0x000000, alpha: prominent ? 0.18 : 0.12).cgColor, Self.color(0x000000, alpha: prominent ? 0.88 : 0.82).cgColor]
        gradientLayer.locations = [0, 0.52, 1]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        gradientOverlay.layer = gradientLayer
        addSubview(gradientOverlay)
        shineLayer.backgroundColor = Self.color(0x34C759, alpha: prominent ? 0.16 : 0.10).cgColor
        shineLayer.opacity = Float(prominent ? 0.88 : 0.52)
        layer?.addSublayer(shineLayer)
        accentLayer.backgroundColor = Self.color(0x34C759, alpha: 0.96).cgColor
        layer?.addSublayer(accentLayer)
        storeBadgeView.wantsLayer = true
        storeBadgeView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(storeBadgeView)
        configureStoreIcons()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = prominent ? 2 : 1
        addSubview(titleLabel)
        metaLabel.lineBreakMode = .byTruncatingTail
        addSubview(metaLabel)
        featureLabel.lineBreakMode = .byTruncatingTail
        featureLabel.maximumNumberOfLines = prominent ? 2 : 1
        addSubview(featureLabel)
        availabilityLabel.lineBreakMode = .byTruncatingTail
        addSubview(availabilityLabel)
        playButton.title = Self.primaryActionTitle(gameObject: gameObject, variantIndex: Int(selectedVariantIndex), prominent: prominent)
        playButton.isBordered = false
        playButton.font = NSFont.systemFont(ofSize: prominent ? 14 : 11, weight: .black)
        playButton.contentTintColor = Self.color(0x06140A)
        playButton.wantsLayer = true
        playButton.layer?.backgroundColor = Self.color(0x34C759, alpha: 0.98).cgColor
        playButton.layer?.shadowColor = Self.color(0x34C759).cgColor
        playButton.layer?.shadowOpacity = prominent ? 0.42 : 0
        playButton.layer?.shadowRadius = prominent ? 24 : 0
        playButton.layer?.shadowOffset = .zero
        playButton.isHidden = !prominent
        playButton.target = self
        playButton.action = #selector(selectPressed)
        addSubview(playButton)
        refreshSelectedVariantPresentation()
        imageView.image = OPNGameCatalogArtworkSupport.fallbackArtworkImage()
        updateTrackingAreas()
    }

    private func configureStoreIcons() {
        let variantStores = Self.variantStoreNames(gameObject)
        let firstStore = Self.storeName(forVariantIndex: 0, variantStores: variantStores, gameObject: gameObject)
        configure(iconView: storeIconView, store: firstStore)
        storeBadgeView.addSubview(storeIconView)
        storeIconViews.append(storeIconView)
        storeIconVariantIndexes.append(0)
        loadStoreIcon(firstStore, into: storeIconView)
        let variantIconCount = gameObject.variants.isEmpty ? variantStores.count : gameObject.variants.count
        guard variantIconCount > 1 else { return }
        for index in 1..<min(4, variantIconCount) {
            let store = Self.storeName(forVariantIndex: index, variantStores: variantStores, gameObject: gameObject)
            let iconView = NSImageView(frame: .zero)
            configure(iconView: iconView, store: store)
            storeBadgeView.addSubview(iconView)
            storeIconViews.append(iconView)
            storeIconVariantIndexes.append(index)
            loadStoreIcon(store, into: iconView)
        }
    }

    private func configure(iconView: NSImageView, store: String) {
        iconView.imageScaling = .scaleProportionallyDown
        iconView.image = OPNGameCatalogArtworkSupport.greyscaleIconImage(OPNGameCatalogArtworkSupport.cachedStoreIconImage(store) ?? OPNGameCatalogArtworkSupport.iconPlaceholderImage(store))
        iconView.toolTip = OPNGameCatalogArtworkSupport.displayLabel(store)
        iconView.contentTintColor = Self.color(0xD7D8DC, alpha: 0.50)
        iconView.wantsLayer = true
        iconView.layer?.backgroundColor = Self.color(0x030506, alpha: 0.72).cgColor
        iconView.layer?.borderWidth = 1
        iconView.layer?.borderColor = Self.color(0xFFFFFF, alpha: 0.18).cgColor
    }

    private func loadStoreIcon(_ store: String, into iconView: NSImageView) {
        OPNGameCatalogArtworkSupport.loadStoreIconImage(store) { [weak iconView] image in
            guard let image, let iconView else { return }
            MainActor.assumeIsolated {
                iconView.image = OPNGameCatalogArtworkSupport.greyscaleIconImage(image)
            }
        }
    }

    private func layoutProminent(width: CGFloat, height: CGFloat) {
        let iconSize: CGFloat = 34
        let iconGap: CGFloat = 8
        let badgeWidth = CGFloat(storeIconViews.count) * iconSize + CGFloat(max(0, storeIconViews.count - 1)) * iconGap
        storeBadgeView.frame = NSRect(x: 30, y: 28, width: badgeWidth, height: 34)
        layoutIconViews(iconSize: iconSize, iconGap: iconGap)
        availabilityLabel.frame = NSRect(x: width - 188, y: 34, width: 150, height: 20)
        metaLabel.frame = NSRect(x: 30, y: height - 150, width: width - 220, height: 20)
        titleLabel.frame = NSRect(x: 30, y: height - 126, width: width - 220, height: 74)
        featureLabel.frame = NSRect(x: 30, y: height - 49, width: width - 210, height: 21)
        playButton.frame = NSRect(x: width - 152, y: height - 70, width: 112, height: 42)
        playButton.layer?.cornerRadius = 21
    }

    private func layoutCompact(width: CGFloat, height: CGFloat) {
        let iconSize: CGFloat = 28
        let iconGap: CGFloat = 6
        let badgeWidth = CGFloat(storeIconViews.count) * iconSize + CGFloat(max(0, storeIconViews.count - 1)) * iconGap
        storeBadgeView.frame = NSRect(x: 12, y: 12, width: badgeWidth, height: 28)
        layoutIconViews(iconSize: iconSize, iconGap: iconGap)
        availabilityLabel.frame = .zero
        metaLabel.frame = .zero
        titleLabel.frame = .zero
        featureLabel.frame = .zero
        playButton.frame = NSRect(x: width - 64, y: height - 48, width: 50, height: 28)
        playButton.layer?.cornerRadius = 14
    }

    private func layoutIconViews(iconSize: CGFloat, iconGap: CGFloat) {
        for (index, iconView) in storeIconViews.enumerated() {
            iconView.frame = NSRect(x: CGFloat(index) * (iconSize + iconGap), y: 0, width: iconSize, height: iconSize)
            iconView.layer?.cornerRadius = iconSize * 0.5
        }
    }

    private func updateStoreIconSelection() {
        for (index, iconView) in storeIconViews.enumerated() {
            let variantIndex = index < storeIconVariantIndexes.count ? storeIconVariantIndexes[index] : -1
            let selected = variantIndex == Int(selectedVariantIndex) && !gameObject.variants.isEmpty
            iconView.layer?.borderWidth = 1
            iconView.layer?.borderColor = (selected ? Self.color(0x34C759, alpha: 0.96) : (storeFocused ? Self.color(0x34C759, alpha: 0.42) : Self.color(0xFFFFFF, alpha: 0.18))).cgColor
            iconView.layer?.backgroundColor = selected ? Self.color(0x34C759, alpha: 0.24).cgColor : Self.color(0x030506, alpha: 0.72).cgColor
        }
    }

    @objc private func selectPressed() { onSelect?() }
    @objc private func markUnownedPressed(_ sender: Any?) { onMarkUnowned?() }

    @objc private func saveCurrentStreamSettingsAsProfilePressed(_ sender: Any?) {
        let appId = Self.gameProfileAppId(gameObject: gameObject, variantIndex: Int(selectedVariantIndex))
        guard !appId.isEmpty else { return }
        OPNStreamPreferences.saveProfile(forGame: appId, profile: OPNStreamPreferences.loadProfile())
        refreshSelectedVariantPresentation()
    }

    @objc private func togglePerGameStreamProfilePressed(_ sender: Any?) {
        let appId = Self.gameProfileAppId(gameObject: gameObject, variantIndex: Int(selectedVariantIndex))
        guard !appId.isEmpty, OPNStreamPreferences.profileExists(forGame: appId) else { return }
        OPNStreamPreferences.setProfileEnabled(forGame: appId, enabled: !OPNStreamPreferences.profileEnabled(forGame: appId))
        refreshSelectedVariantPresentation()
    }

    @objc private func deletePerGameStreamProfilePressed(_ sender: Any?) {
        let appId = Self.gameProfileAppId(gameObject: gameObject, variantIndex: Int(selectedVariantIndex))
        guard !appId.isEmpty else { return }
        OPNStreamPreferences.deleteProfile(forGame: appId)
        refreshSelectedVariantPresentation()
    }

    private func refreshSelectedVariantPresentation() {
        if !gameObject.variants.isEmpty {
            selectedVariantIndex = Int32(max(0, min(gameObject.variants.count - 1, Int(selectedVariantIndex))))
        }
        availabilityLabel.stringValue = Self.availabilityTitle(gameObject: gameObject, variantIndex: Int(selectedVariantIndex))
        playButton.title = Self.primaryActionTitle(gameObject: gameObject, variantIndex: Int(selectedVariantIndex), prominent: prominent)
        updateStoreIconSelection()
    }

    private func loadImage() {
        imageLoadGeneration += 1
        let candidates = imageCandidates()
        guard !candidates.isEmpty else {
            imageView.image = OPNGameCatalogArtworkSupport.fallbackArtworkImage()
            return
        }
        loadImage(from: candidates, index: 0)
    }

    private func loadImage(from urlStrings: [String], index: Int) {
        let generation = imageLoadGeneration
        guard index < urlStrings.count else {
            if imageView.image == nil { imageView.image = OPNGameCatalogArtworkSupport.fallbackArtworkImage() }
            return
        }
        let urlString = urlStrings[index]
        guard !urlString.isEmpty else {
            loadImage(from: urlStrings, index: index + 1)
            return
        }
        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let maxPixelDimension = max(bounds.width, bounds.height) * max(1, scale) * (prominent ? 1.6 : 1.25)
        imageLoadToken = OPNUIHelpers.loadImageForURLCancellable(urlString: urlString, maxPixelDimension: maxPixelDimension) { [weak self] image, _, _ in
            guard let self, generation == self.imageLoadGeneration else { return }
            self.imageLoadToken = nil
            guard let image else {
                self.loadImage(from: urlStrings, index: index + 1)
                return
            }
            let revealDelay = self.imageView.image == nil ? self.imageRevealDelay : 0
            self.imageView.alphaValue = 0
            self.imageView.image = image
            DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay) { [weak self] in
                guard let self, generation == self.imageLoadGeneration else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.imageView.animator().alphaValue = 1
                }
            }
        }
    }

    private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor { OPNUIHelpers.color(rgb: rgb, alpha: alpha) }
    private static func displayString(_ value: String, fallback: String) -> String { OPNGameCatalogMetadataSupport.displayString(value, fallback: fallback) }

    private static func primaryStoreName(_ gameObject: OPNCatalogGameObject) -> String {
        let raw = gameObject.variants.first?.appStore.isEmpty == false ? gameObject.variants[0].appStore : (gameObject.availableStores.first ?? "")
        let name = raw.isEmpty ? "Cloud" : raw
        let upper = name.uppercased()
        if upper.contains("STEAM") { return "Steam" }
        if upper.contains("BATTLE") { return "Battle.net" }
        if upper.contains("UBISOFT") || upper.contains("UPLAY") { return "Ubisoft" }
        if upper.contains("XBOX") { return "Xbox" }
        if upper.contains("EPIC") { return "Epic" }
        if upper.contains("EA") { return "EA" }
        return name.capitalized
    }

    private static func variantStoreNames(_ gameObject: OPNCatalogGameObject) -> [String] {
        var stores: [String] = []
        var seen = Set<String>()
        func appendStore(_ rawStore: String) {
            let store = OPNGameCatalogArtworkSupport.displayLabel(rawStore)
            guard !store.isEmpty else { return }
            let key = store.uppercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            stores.append(store)
        }
        gameObject.variants.forEach { appendStore($0.appStore) }
        gameObject.availableStores.forEach { appendStore($0) }
        if stores.isEmpty { stores.append(primaryStoreName(gameObject)) }
        return stores
    }

    private static func storeName(forVariantIndex index: Int, variantStores: [String], gameObject: OPNCatalogGameObject) -> String {
        var store = !gameObject.variants.isEmpty && index < gameObject.variants.count ? gameObject.variants[index].appStore : (index < variantStores.count ? variantStores[index] : "")
        if store.isEmpty { store = index < variantStores.count ? variantStores[index] : primaryStoreName(gameObject) }
        return store
    }

    private static func primaryGenre(_ gameObject: OPNCatalogGameObject) -> String {
        if let genre = gameObject.genres.first { return displayString(genre, fallback: "Cloud Game") }
        if !gameObject.playType.isEmpty { return displayString(gameObject.playType, fallback: "Cloud Game") }
        return "Cloud Game"
    }

    private static func featureSummary(_ gameObject: OPNCatalogGameObject) -> String {
        var parts: [String] = []
        if gameObject.maxOnlinePlayers > 1 { parts.append("\(gameObject.maxOnlinePlayers) online") }
        if gameObject.maxLocalPlayers > 1 { parts.append("\(gameObject.maxLocalPlayers) local") }
        for feature in gameObject.featureLabels {
            let label = displayString(feature, fallback: "")
            if !label.isEmpty { parts.append(label) }
            if parts.count >= 2 { break }
        }
        if parts.isEmpty, let control = gameObject.supportedControls.first {
            let label = displayString(control, fallback: "")
            if !label.isEmpty { parts.append(label) }
        }
        return parts.isEmpty ? "Ready to stream" : parts.joined(separator: " · ")
    }

    private static func appendUniqueURL(_ urls: inout [String], _ urlString: String?) {
        let trimmed = (urlString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !urls.contains(trimmed) else { return }
        urls.append(trimmed)
    }

    private static func appendImageType(_ urls: inout [String], gameObject: OPNCatalogGameObject, type: String) {
        guard let typedURLs = gameObject.imageUrlsByType[type] else { return }
        typedURLs.forEach { appendUniqueURL(&urls, $0) }
    }

    private static func steamArtworkURL(gameObject: OPNCatalogGameObject) -> String? {
        var appId = ""
        for variant in gameObject.variants where isNumericString(variant.id) && variant.appStore.uppercased().contains("STEAM") {
            appId = variant.id
            break
        }
        if appId.isEmpty, isNumericString(gameObject.launchAppId) { appId = gameObject.launchAppId }
        return appId.isEmpty ? nil : "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/header.jpg"
    }

    private static func imageCandidates(gameObject: OPNCatalogGameObject, prominent: Bool) -> [String] {
        var urls: [String] = []
        let preferredTypes = prominent ? ["MARQUEE_HERO_IMAGE", "HERO_IMAGE", "TV_BANNER", "FEATURE_IMAGE", "KEY_ART", "KEY_IMAGE", "GAME_BOX_ART"] : ["TV_BANNER", "HERO_IMAGE", "KEY_IMAGE", "KEY_ART", "GAME_BOX_ART", "FEATURE_IMAGE"]
        preferredTypes.forEach { appendImageType(&urls, gameObject: gameObject, type: $0) }
        appendUniqueURL(&urls, gameObject.heroImageUrl)
        appendUniqueURL(&urls, gameObject.imageUrl)
        for screenshot in gameObject.screenshotUrls {
            appendUniqueURL(&urls, screenshot)
            if !prominent { break }
        }
        appendUniqueURL(&urls, steamArtworkURL(gameObject: gameObject))
        return urls
    }

    private static func isNumericString(_ value: String) -> Bool { !value.isEmpty && value.allSatisfy(\.isNumber) }

    private static func variant(at index: Int, gameObject: OPNCatalogGameObject) -> OPNCatalogGameVariantObject? {
        guard index >= 0, index < gameObject.variants.count else { return nil }
        return gameObject.variants[index]
    }

    private static func variantIsOwned(_ variant: OPNCatalogGameVariantObject) -> Bool {
        OPNGameCatalogMetadataSupport.variantIsOwned(inLibrary: variant.inLibrary, librarySelected: variant.librarySelected, serviceStatus: variant.serviceStatus)
    }

    private static func variantCanBeMarkedUnowned(gameObject: OPNCatalogGameObject, variantIndex: Int) -> Bool {
        guard let variant = variant(at: variantIndex, gameObject: gameObject), !variant.id.isEmpty else { return false }
        return variantIsOwned(variant)
    }

    private static func gameNeedsPurchase(gameObject: OPNCatalogGameObject, variantIndex: Int) -> Bool {
        if let selectedVariant = variant(at: variantIndex, gameObject: gameObject) { return !variantIsOwned(selectedVariant) }
        return gameObject.variants.contains { !variantIsOwned($0) }
    }

    private static func primaryActionTitle(gameObject: OPNCatalogGameObject, variantIndex: Int, prominent: Bool) -> String {
        OPNGameCatalogMetadataSupport.primaryActionTitle(needsPurchase: gameNeedsPurchase(gameObject: gameObject, variantIndex: variantIndex), prominent: prominent)
    }

    private static func gameProfileAppId(gameObject: OPNCatalogGameObject, variantIndex: Int) -> String {
        if let variant = variant(at: variantIndex, gameObject: gameObject), !variant.id.isEmpty { return variant.id }
        if !gameObject.launchAppId.isEmpty { return gameObject.launchAppId }
        return gameObject.id
    }

    private static func availabilityTitle(gameObject: OPNCatalogGameObject, variantIndex: Int) -> String {
        let appId = gameProfileAppId(gameObject: gameObject, variantIndex: variantIndex)
        let profileEnabled = !appId.isEmpty && OPNStreamPreferences.profileEnabled(forGame: appId)
        let storeCount = max(gameObject.availableStores.count, gameObject.variants.count)
        return OPNGameCatalogMetadataSupport.availabilityTitle(needsPurchase: gameNeedsPurchase(gameObject: gameObject, variantIndex: variantIndex), profileEnabled: profileEnabled, storeCount: storeCount)
    }
}

@objc(OPNStoreRowLayout)
@objcMembers
final class OPNStoreRowLayout: NSObject {
    var glowView: NSView?
    var indexLabel: NSTextField?
    var titleLabel: NSTextField?
    var hintLabel: NSTextField?
    var scrollView: NSScrollView?
    var documentView: NSView?
    var cards: [OPNStoreGameTile] = []
    var y: CGFloat = 0
    var mounted = false
}
