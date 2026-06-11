import AVKit
import QuartzCore

@objc(OPNLoadingView)
final class OPNLoadingView: NSView {
    @objc var message: String {
        didSet {
            if message.isEmpty { message = "Loading..." }
            messageLabel.stringValue = message
            updateQueueBadge()
            needsLayout = true
        }
    }

    @objc var steps: [String] = [] {
        didSet { rebuildStepIndicators() }
    }

    @objc var currentStepIndex: Int = -1 {
        didSet { restyleStepIndicators() }
    }

    @objc var queuePosition: Int = 0 {
        didSet {
            queuePosition = max(0, queuePosition)
            updateQueueBadge()
            needsLayout = true
        }
    }

    @objc private(set) var messageLabel = NSTextField(labelWithString: "")
    @objc var adPlaybackEventHandler: ((String, String, Int, Int, String) -> Void)?

    private let panelLayer = CALayer()
    private let sweepLayer = CAGradientLayer()
    private let orbitLayer = CAShapeLayer()
    private let innerOrbitLayer = CAShapeLayer()
    private let coreLayer = CALayer()
    private let sparkLayer = CALayer()
    private var barLayers: [CALayer] = []
    private var dotLayers: [CALayer] = []
    private var stepIndicatorLayers: [CALayer] = []
    private let queuePositionLabel = NSTextField(labelWithString: "")
    private let adContainerView = NSView()
    private let adChipLabel = NSTextField(labelWithString: "Sponsored Break")
    private let adTitleLabel = NSTextField(labelWithString: "Watch to continue")
    private let adMessageLabel = NSTextField(labelWithString: "Your launch will resume automatically after the ad.")
    private let adPlayerView = AVPlayerView()
    private var adPlayer: AVPlayer?
    private var adTimeObserver: Any?
    private var adFallbackTimer: Timer?
    private var activeAdId: String?
    private var adStartedAt: Date?
    private var adVisible = false
    private var adStartReported = false
    private var adFinishReported = false
    private var adCancelReported = false

    @objc(initWithFrame:message:)
    init(frame frameRect: NSRect, message rawMessage: String?) {
        message = rawMessage?.isEmpty == false ? rawMessage! : "Loading..."
        super.init(frame: frameRect)
        buildViewHierarchy()
    }

    override init(frame frameRect: NSRect) {
        message = "Loading..."
        super.init(frame: frameRect)
        buildViewHierarchy()
    }

    required init?(coder: NSCoder) {
        message = "Loading..."
        super.init(coder: coder)
        buildViewHierarchy()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let hasSteps = !stepIndicatorLayers.isEmpty
        let panelWidth = min(hasSteps ? 540.0 : 460.0, max(320.0, width - 48.0))
        let showQueueBadge = !queuePositionLabel.isHidden
        var panelHeight = adVisible ? 460.0 : (hasSteps ? 338.0 : 296.0)
        panelHeight = min(panelHeight, max(252.0, height - 48.0))
        let panelX = floor((width - panelWidth) * 0.5)
        let panelY = floor((height - panelHeight) * 0.5)
        let panelRect = NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
        let centerX = panelRect.midX
        let orbitSize = min(108.0, max(80.0, panelWidth * 0.22))
        let orbitY = panelY + 34.0
        let orbitRect = NSRect(x: centerX - orbitSize * 0.5, y: orbitY, width: orbitSize, height: orbitSize)

        panelLayer.frame = panelRect
        panelLayer.shadowPath = CGPath(roundedRect: NSRect(x: 0.0, y: 0.0, width: panelWidth, height: panelHeight), cornerWidth: 28.0, cornerHeight: 28.0, transform: nil)
        sweepLayer.frame = NSRect(x: -width * 0.8, y: 0.0, width: width * 0.72, height: height)
        orbitLayer.frame = orbitRect
        orbitLayer.path = CGPath(ellipseIn: NSRect(x: 0.0, y: 0.0, width: orbitSize, height: orbitSize), transform: nil)
        innerOrbitLayer.frame = orbitRect.insetBy(dx: 13.0, dy: 13.0)
        innerOrbitLayer.path = CGPath(ellipseIn: NSRect(x: 0.0, y: 0.0, width: orbitSize - 26.0, height: orbitSize - 26.0), transform: nil)
        coreLayer.frame = NSRect(x: centerX - 7.0, y: orbitY + orbitSize * 0.5 - 7.0, width: 14.0, height: 14.0)
        coreLayer.cornerRadius = 7.0
        sparkLayer.frame = NSRect(x: orbitRect.maxX - 8.0, y: orbitY + orbitSize * 0.5 - 4.0, width: 8.0, height: 8.0)
        sparkLayer.cornerRadius = 4.0

        let barWidth = min(148.0, panelWidth - 96.0)
        let barY = orbitY + orbitSize + 26.0
        for (index, bar) in barLayers.enumerated() {
            let fraction = 1.0 - CGFloat(index) * 0.16
            let x = centerX - (barWidth * fraction) * 0.5
            bar.frame = NSRect(x: x, y: barY + CGFloat(index) * 8.0, width: barWidth * fraction, height: 4.0)
        }

        let dotStart = centerX - 29.0
        for (index, dot) in dotLayers.enumerated() {
            dot.frame = NSRect(x: dotStart + CGFloat(index) * 13.0, y: barY + 45.0, width: 5.0, height: 5.0)
        }

        messageLabel.frame = NSRect(x: panelX + 36.0, y: barY + 66.0, width: max(80.0, panelWidth - 72.0), height: 42.0)
        if showQueueBadge {
            queuePositionLabel.frame = NSRect(x: centerX - 54.0, y: barY + 114.0, width: 108.0, height: 28.0)
        }

        if adVisible {
            let adInset = 28.0
            let queueRowHeight = showQueueBadge ? 38.0 : 0.0
            let adHeight = panelHeight - 106.0 - queueRowHeight
            adContainerView.frame = NSRect(x: panelX + adInset, y: panelY + 34.0, width: panelWidth - adInset * 2.0, height: adHeight)
            let adWidth = adContainerView.bounds.width
            let mediaHeight = min(190.0, max(120.0, adHeight * 0.54))
            adPlayerView.frame = NSRect(x: 18.0, y: 18.0, width: adWidth - 36.0, height: mediaHeight)
            adChipLabel.frame = NSRect(x: 20.0, y: mediaHeight + 32.0, width: adWidth - 40.0, height: 18.0)
            adTitleLabel.frame = NSRect(x: 20.0, y: mediaHeight + 54.0, width: adWidth - 40.0 - (showQueueBadge ? 206.0 : 0.0), height: 54.0)
            adMessageLabel.frame = NSRect(x: 20.0, y: mediaHeight + 112.0, width: adWidth - 40.0, height: 56.0)
            messageLabel.frame = NSRect(x: panelX + 36.0, y: panelRect.maxY - 52.0, width: max(80.0, panelWidth - 72.0), height: 24.0)
            if showQueueBadge {
                queuePositionLabel.frame = NSRect(x: centerX - 54.0, y: adContainerView.frame.maxY + 10.0, width: 108.0, height: 28.0)
            }
        }

        let stepCount = stepIndicatorLayers.count
        if stepCount > 0 {
            let gap = 7.0
            let railWidth = min(240.0, panelWidth - 112.0)
            let segmentWidth = floor((railWidth - gap * CGFloat(stepCount - 1)) / CGFloat(stepCount))
            let segmentX = centerX - railWidth * 0.5
            let segmentY = showQueueBadge ? barY + 154.0 : barY + 126.0
            for index in stepIndicatorLayers.indices {
                stepIndicatorLayers[index].frame = NSRect(x: segmentX + (segmentWidth + gap) * CGFloat(index), y: segmentY, width: segmentWidth, height: 3.0)
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stopAnimating() : startAnimating()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            adFallbackTimer?.invalidate()
            adFallbackTimer = nil
            removeAdTimeObserver()
            NotificationCenter.default.removeObserver(self)
        }
    }

    @objc(setSteps:currentStepIndex:)
    func setSteps(_ steps: [String], currentStepIndex: Int) {
        self.steps = steps
        self.currentStepIndex = currentStepIndex
        rebuildStepIndicators()
    }

    @objc(advanceToStep:message:)
    func advance(toStep stepIndex: Int, message: String?) {
        currentStepIndex = stepIndex
        self.message = message?.isEmpty == false ? message! : "Loading..."
    }

    @objc(updateQueuePosition:)
    func updateQueuePosition(_ queuePosition: Int) {
        self.queuePosition = queuePosition
    }

    @objc(updateAdPresentationWithVisible:chipText:title:message:adId:mediaUrl:durationMs:)
    func updateAdPresentation(visible: Bool, chipText: String, title: String, message: String, adId: String, mediaUrl: String, durationMs: Int) {
        guard visible else {
            clearAdPresentation()
            return
        }

        adVisible = true
        adContainerView.isHidden = false
        adChipLabel.stringValue = chipText.isEmpty ? "Sponsored Break" : chipText
        adTitleLabel.stringValue = title.isEmpty ? "Watch to continue" : title
        adMessageLabel.stringValue = message.isEmpty ? "Your launch will resume automatically after the ad." : message
        setLoadingChrome(hidden: true)
        stopAnimating()

        guard !adId.isEmpty || !mediaUrl.isEmpty else {
            resetAdPlayback()
            activeAdId = nil
            needsLayout = true
            return
        }

        let normalizedAdId = adId.isEmpty ? "ad" : adId
        if activeAdId == normalizedAdId {
            needsLayout = true
            return
        }

        resetAdPlayback()
        activeAdId = normalizedAdId
        adStartedAt = Date()
        adStartReported = false
        adFinishReported = false
        adCancelReported = false

        if let url = URL(string: mediaUrl), !mediaUrl.isEmpty {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            adPlayer = player
            adPlayerView.player = player
            adPlayerView.isHidden = false
            NotificationCenter.default.addObserver(self, selector: #selector(handleAdFinished(_:)), name: .AVPlayerItemDidPlayToEndTime, object: item)
            NotificationCenter.default.addObserver(self, selector: #selector(handleAdPlaybackFailed(_:)), name: .AVPlayerItemFailedToPlayToEndTime, object: item)
            adTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC)), queue: .main) { [weak self] time in
                Task { @MainActor [weak self] in
                    guard let self, !self.adStartReported, time.isNumeric, time.seconds > 0.0 else { return }
                    self.reportAdAction("start", cancelReason: "")
                }
            }
            player.play()
        } else {
            adPlayerView.player = nil
            adPlayerView.isHidden = true
            reportAdAction("start", cancelReason: "")
            let seconds = max(5.0, Double(max(durationMs, 1)) / 1000.0)
            adFallbackTimer = Timer.scheduledTimer(timeInterval: seconds, target: self, selector: #selector(handleFallbackAdTimer(_:)), userInfo: nil, repeats: false)
        }
        needsLayout = true
    }

    @objc func clearAdPresentation() {
        guard adVisible else { return }
        resetAdPlayback()
        adContainerView.isHidden = true
        activeAdId = nil
        adVisible = false
        setLoadingChrome(hidden: false)
        if window != nil { startAnimating() }
        needsLayout = true
    }

    @objc func startAnimating() {
        guard orbitLayer.animation(forKey: "opn.orbit.rotate") == nil else { return }
        addRotationAnimation(to: orbitLayer, key: "opn.orbit.rotate", from: 0.0, to: .pi * 2.0, duration: 1.65)
        addRotationAnimation(to: innerOrbitLayer, key: "opn.inner.rotate", from: .pi * 2.0, to: 0.0, duration: 4.2)
        addRotationAnimation(to: sparkLayer, key: "opn.spark.rotate", from: 0.0, to: .pi * 2.0, duration: 1.65)

        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.82
        pulse.toValue = 1.24
        pulse.duration = 0.82
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coreLayer.add(pulse, forKey: "opn.core.pulse")

        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = 0.0
        sweep.toValue = bounds.width * 2.1
        sweep.duration = 2.65
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweepLayer.add(sweep, forKey: "opn.sweep")

        for (index, bar) in barLayers.enumerated() {
            let scale = CABasicAnimation(keyPath: "transform.scale.x")
            scale.fromValue = 0.28
            scale.toValue = 1.0
            scale.duration = 0.92
            scale.autoreverses = true
            scale.repeatCount = .infinity
            scale.beginTime = CACurrentMediaTime() + CFTimeInterval(index) * 0.12
            scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(scale, forKey: "opn.bar.scale")
        }

        for (index, dot) in dotLayers.enumerated() {
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.22
            opacity.toValue = 1.0
            opacity.duration = 0.72
            opacity.autoreverses = true
            opacity.repeatCount = .infinity
            opacity.beginTime = CACurrentMediaTime() + CFTimeInterval(index) * 0.10
            dot.add(opacity, forKey: "opn.dot.opacity")
        }
    }

    @objc(updateAdState:)
    func updateAdState(_ adState: NSDictionary) {
        let isRequired = bool(adState["isAdsRequired"]) || bool(adState["sessionAdsRequired"]) || bool(adState["isQueuePaused"])
        guard isRequired else {
            clearAdPresentation()
            return
        }
        let ads = adState["sessionAds"] as? [NSDictionary] ?? []
        let ad = ads.first ?? [:]
        updateAdPresentation(
            visible: true,
            chipText: bool(adState["isQueuePaused"]) ? "Queue Paused" : "Sponsored Break",
            title: string(ad["title"], fallback: "Watch to continue"),
            message: string(adState["message"], fallback: "Your launch will resume automatically after the ad."),
            adId: string(ad["adId"], fallback: "ad"),
            mediaUrl: string(ad["mediaUrl"]),
            durationMs: int(ad["durationMs"], fallback: max(1, int(ad["adLengthInSeconds"])) * 1000)
        )
    }

    @objc func stopAnimating() {
        sweepLayer.removeAllAnimations()
        orbitLayer.removeAllAnimations()
        innerOrbitLayer.removeAllAnimations()
        coreLayer.removeAllAnimations()
        sparkLayer.removeAllAnimations()
        barLayers.forEach { $0.removeAllAnimations() }
        dotLayers.forEach { $0.removeAllAnimations() }
    }

    private func buildViewHierarchy() {
        wantsLayer = true
        layer?.backgroundColor = opnColor(0x020304, 0.98).cgColor
        layer?.masksToBounds = true

        panelLayer.backgroundColor = opnColor(0x0A0C0F, 0.96).cgColor
        panelLayer.cornerRadius = 28.0
        panelLayer.borderWidth = 1.0
        panelLayer.borderColor = opnColor(0xFFFFFF, 0.11).cgColor
        panelLayer.shadowColor = NSColor.black.cgColor
        panelLayer.shadowOpacity = 0.32
        panelLayer.shadowRadius = 32.0
        panelLayer.shadowOffset = CGSize(width: 0.0, height: 18.0)
        layer?.addSublayer(panelLayer)

        sweepLayer.locations = [0.0, 0.42, 0.50, 1.0]
        sweepLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        sweepLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        layer?.addSublayer(sweepLayer)

        orbitLayer.fillColor = NSColor.clear.cgColor
        orbitLayer.lineWidth = 2.0
        orbitLayer.lineCap = .round
        orbitLayer.strokeStart = 0.04
        orbitLayer.strokeEnd = 0.72
        layer?.addSublayer(orbitLayer)

        innerOrbitLayer.fillColor = NSColor.clear.cgColor
        innerOrbitLayer.strokeColor = opnColor(0xFFFFFF, 0.26).cgColor
        innerOrbitLayer.lineWidth = 1.0
        innerOrbitLayer.lineDashPattern = [3, 7]
        layer?.addSublayer(innerOrbitLayer)

        coreLayer.shadowOpacity = 0.86
        coreLayer.shadowRadius = 14.0
        coreLayer.shadowOffset = .zero
        layer?.addSublayer(coreLayer)

        sparkLayer.shadowOpacity = 0.9
        sparkLayer.shadowRadius = 10.0
        sparkLayer.shadowOffset = .zero
        layer?.addSublayer(sparkLayer)

        for _ in 0..<4 {
            let bar = CALayer()
            bar.cornerRadius = 2.0
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }

        for _ in 0..<5 {
            let dot = CALayer()
            dot.cornerRadius = 2.5
            dot.shadowOpacity = 0.36
            dot.shadowRadius = 5.0
            dot.shadowOffset = .zero
            layer?.addSublayer(dot)
            dotLayers.append(dot)
        }

        messageLabel = opnLabel(message, .zero, 15.0, opnColor(OPNViewColor.textPrimary), .semibold, .center)
        messageLabel.maximumNumberOfLines = 2
        addSubview(messageLabel)

        queuePositionLabel.font = NSFont.systemFont(ofSize: 12.0, weight: .bold)
        queuePositionLabel.textColor = opnColor(OPNViewColor.brandGreen)
        queuePositionLabel.alignment = .center
        queuePositionLabel.isHidden = true
        queuePositionLabel.wantsLayer = true
        queuePositionLabel.layer?.backgroundColor = opnColor(0x07140F, 0.92).cgColor
        queuePositionLabel.layer?.cornerRadius = 14.0
        queuePositionLabel.layer?.borderWidth = 1.0
        queuePositionLabel.layer?.borderColor = opnColor(OPNViewColor.brandGreen, 0.36).cgColor
        addSubview(queuePositionLabel)

        configureAdViews()
        applyAccentColors()
        NotificationCenter.default.addObserver(self, selector: #selector(interfacePreferencesChanged(_:)), name: Notification.Name("OpenNOW.InterfacePreferencesDidChange"), object: nil)
    }

    private func configureAdViews() {
        adContainerView.wantsLayer = true
        adContainerView.layer?.backgroundColor = opnColor(0x05070A, 0.48).cgColor
        adContainerView.layer?.cornerRadius = 22.0
        adContainerView.layer?.borderWidth = 1.0
        adContainerView.layer?.borderColor = opnColor(0xFFFFFF, 0.12).cgColor
        adContainerView.isHidden = true
        addSubview(adContainerView)

        adChipLabel.font = NSFont.systemFont(ofSize: 12.0, weight: .semibold)
        adChipLabel.textColor = opnColor(OPNViewColor.brandGreen)
        adContainerView.addSubview(adChipLabel)
        adTitleLabel.font = NSFont.systemFont(ofSize: 20.0, weight: .bold)
        adTitleLabel.textColor = opnColor(OPNViewColor.textPrimary)
        adTitleLabel.maximumNumberOfLines = 2
        adContainerView.addSubview(adTitleLabel)
        adMessageLabel.font = NSFont.systemFont(ofSize: 13.0)
        adMessageLabel.textColor = opnColor(OPNViewColor.textSecondary)
        adMessageLabel.maximumNumberOfLines = 3
        adContainerView.addSubview(adMessageLabel)
        adPlayerView.controlsStyle = .none
        adPlayerView.videoGravity = .resizeAspect
        adPlayerView.isHidden = true
        adContainerView.addSubview(adPlayerView)
    }

    @objc private func interfacePreferencesChanged(_ notification: Notification) {
        applyAccentColors()
    }

    private func applyAccentColors() {
        sweepLayer.colors = [
            opnColor(OPNViewColor.brandGreen, 0.0).cgColor,
            opnColor(OPNViewColor.brandGreen, 0.28).cgColor,
            opnColor(0x49D56B, 0.42).cgColor,
            opnColor(OPNViewColor.brandGreen, 0.0).cgColor,
        ]
        orbitLayer.strokeColor = opnColor(OPNViewColor.brandGreen, 0.78).cgColor
        coreLayer.backgroundColor = opnColor(0x49D56B, 0.92).cgColor
        coreLayer.shadowColor = opnColor(OPNViewColor.brandGreen).cgColor
        sparkLayer.backgroundColor = opnColor(OPNViewColor.brandGreen, 0.92).cgColor
        sparkLayer.shadowColor = opnColor(OPNViewColor.brandGreen).cgColor
        barLayers.forEach { $0.backgroundColor = opnColor(OPNViewColor.brandGreen, 0.54).cgColor }
        dotLayers.forEach {
            $0.backgroundColor = opnColor(0x49D56B, 0.74).cgColor
            $0.shadowColor = opnColor(OPNViewColor.brandGreen).cgColor
        }
        restyleStepIndicators()
    }

    private func shouldShowQueueBadge() -> Bool {
        guard queuePosition > 0 else { return false }
        let lowerMessage = message.lowercased()
        return !lowerMessage.contains("previous session")
            && !lowerMessage.contains("cleanup")
            && !lowerMessage.contains("storage")
            && !lowerMessage.contains("setting up")
            && !lowerMessage.contains("cloud rig")
    }

    private func updateQueueBadge() {
        if shouldShowQueueBadge() {
            queuePositionLabel.stringValue = "QUEUE  #\(queuePosition)"
            queuePositionLabel.isHidden = false
        } else {
            queuePositionLabel.stringValue = ""
            queuePositionLabel.isHidden = true
        }
    }

    private func rebuildStepIndicators() {
        stepIndicatorLayers.forEach { $0.removeFromSuperlayer() }
        stepIndicatorLayers.removeAll()
        for _ in steps {
            let indicator = CALayer()
            indicator.cornerRadius = 1.5
            layer?.addSublayer(indicator)
            stepIndicatorLayers.append(indicator)
        }
        restyleStepIndicators()
        needsLayout = true
    }

    private func restyleStepIndicators() {
        for index in stepIndicatorLayers.indices {
            let completed = index < currentStepIndex
            let current = index == currentStepIndex
            stepIndicatorLayers[index].backgroundColor = current
                ? opnColor(0x49D56B, 0.96).cgColor
                : (completed ? opnColor(OPNViewColor.brandGreen, 0.54).cgColor : opnColor(0xFFFFFF, 0.16).cgColor)
        }
    }

    private func setLoadingChrome(hidden: Bool) {
        sweepLayer.isHidden = hidden
        orbitLayer.isHidden = hidden
        innerOrbitLayer.isHidden = hidden
        coreLayer.isHidden = hidden
        sparkLayer.isHidden = hidden
        barLayers.forEach { $0.isHidden = hidden }
        dotLayers.forEach { $0.isHidden = hidden }
    }

    private func resetAdPlayback() {
        adFallbackTimer?.invalidate()
        adFallbackTimer = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        removeAdTimeObserver()
        adPlayer?.pause()
        adPlayer = nil
        adPlayerView.player = nil
        adPlayerView.isHidden = true
    }

    private func removeAdTimeObserver() {
        guard let adPlayer, let adTimeObserver else { return }
        adPlayer.removeTimeObserver(adTimeObserver)
        self.adTimeObserver = nil
    }

    private func currentAdWatchedTimeInMs() -> Int {
        if let current = adPlayer?.currentItem?.currentTime(), current.isNumeric {
            return Int((current.seconds * 1000.0).rounded())
        }
        guard let adStartedAt else { return 0 }
        return max(0, Int((-adStartedAt.timeIntervalSinceNow * 1000.0).rounded()))
    }

    private func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    private func int(_ value: Any?, fallback: Int = 0) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? fallback }
        return fallback
    }

    private func string(_ value: Any?, fallback: String = "") -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return fallback
    }

    private func reportAdAction(_ action: String, cancelReason: String) {
        guard let activeAdId, !activeAdId.isEmpty, let adPlaybackEventHandler else { return }
        if action == "start" {
            guard !adStartReported else { return }
            adStartReported = true
        }
        if action == "finish" {
            guard !adFinishReported else { return }
            adFinishReported = true
        }
        if action == "cancel" {
            guard !adCancelReported else { return }
            adCancelReported = true
        }
        adPlaybackEventHandler(activeAdId, action, currentAdWatchedTimeInMs(), 0, cancelReason)
    }

    @objc private func handleAdFinished(_ notification: Notification) {
        guard notification.object as AnyObject? === adPlayer?.currentItem else { return }
        reportAdAction("finish", cancelReason: "")
    }

    @objc private func handleAdPlaybackFailed(_ notification: Notification) {
        guard notification.object as AnyObject? === adPlayer?.currentItem else { return }
        reportAdAction("cancel", cancelReason: "playback-failed")
    }

    @objc private func handleFallbackAdTimer(_ timer: Timer) {
        reportAdAction("finish", cancelReason: "")
    }

    private func addRotationAnimation(to layer: CALayer, key: String, from: Double, to: Double, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: key)
    }
}
