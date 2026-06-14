import AVKit
import Backend
import Combine
import SwiftUI

@MainActor
private final class OPNLoadingViewModel: ObservableObject {
    @Published var message: String
    @Published var steps: [String] = []
    @Published var currentStepIndex = -1
    @Published var queuePosition = 0
    @Published var adVisible = false
    @Published var adChipText = "Sponsored Break"
    @Published var adTitle = "Watch to continue"
    @Published var adMessage = "Your launch will resume automatically after the ad."
    @Published var adPlayer: AVPlayer?
    @Published var isAnimating = false

    init(message: String) {
        self.message = message.isEmpty ? "Loading..." : message
    }
}

@objc(OPNLoadingView)
@MainActor
final class OPNLoadingView: NSView {
    @objc var message: String {
        didSet {
            if message.isEmpty { message = "Loading..." }
            model.message = message
            messageLabel.stringValue = message
            updateQueueBadge()
        }
    }

    @objc var steps: [String] = [] {
        didSet { model.steps = steps }
    }

    @objc var currentStepIndex: Int = -1 {
        didSet { model.currentStepIndex = currentStepIndex }
    }

    @objc var queuePosition: Int = 0 {
        didSet {
            queuePosition = max(0, queuePosition)
            model.queuePosition = shouldShowQueueBadge() ? queuePosition : 0
        }
    }

    @objc private(set) var messageLabel = NSTextField(labelWithString: "")
    @objc var adPlaybackEventHandler: ((String, String, Int, Int, String) -> Void)?

    private let model: OPNLoadingViewModel
    private var hostingView: NSHostingView<OPNLoadingSwiftUIView>?
    private var adPlayer: AVPlayer?
    private var adTimeObserver: Any?
    private var adFallbackTimer: Timer?
    private var activeAdId: String?
    private var adStartedAt: Date?
    private var adStartReported = false
    private var adFinishReported = false
    private var adCancelReported = false

    @objc(initWithFrame:message:)
    init(frame frameRect: NSRect, message rawMessage: String?) {
        let normalizedMessage = rawMessage?.isEmpty == false ? rawMessage! : "Loading..."
        message = normalizedMessage
        model = OPNLoadingViewModel(message: normalizedMessage)
        super.init(frame: frameRect)
        buildViewHierarchy()
    }

    override init(frame frameRect: NSRect) {
        message = "Loading..."
        model = OPNLoadingViewModel(message: "Loading...")
        super.init(frame: frameRect)
        buildViewHierarchy()
    }

    required init?(coder: NSCoder) {
        message = "Loading..."
        model = OPNLoadingViewModel(message: "Loading...")
        super.init(coder: coder)
        buildViewHierarchy()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
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

        model.adVisible = true
        model.adChipText = chipText.isEmpty ? "Sponsored Break" : chipText
        model.adTitle = title.isEmpty ? "Watch to continue" : title
        model.adMessage = message.isEmpty ? "Your launch will resume automatically after the ad." : message
        stopAnimating()

        guard !adId.isEmpty || !mediaUrl.isEmpty else {
            resetAdPlayback()
            activeAdId = nil
            return
        }

        let normalizedAdId = adId.isEmpty ? "ad" : adId
        if activeAdId == normalizedAdId { return }

        resetAdPlayback()
        activeAdId = normalizedAdId
        adStartedAt = Date()
        adStartReported = false
        adFinishReported = false
        adCancelReported = false

        if let url = URL(string: mediaUrl), !mediaUrl.isEmpty {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.volume = 0.5
            adPlayer = player
            model.adPlayer = player
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
            model.adPlayer = nil
            reportAdAction("start", cancelReason: "")
            let seconds = max(5.0, Double(max(durationMs, 1)) / 1000.0)
            adFallbackTimer = Timer.scheduledTimer(timeInterval: seconds, target: self, selector: #selector(handleFallbackAdTimer(_:)), userInfo: nil, repeats: false)
        }
    }

    @objc func clearAdPresentation() {
        guard model.adVisible else { return }
        resetAdPlayback()
        activeAdId = nil
        model.adVisible = false
        if window != nil { startAnimating() }
    }

    @objc func startAnimating() {
        model.isAnimating = true
    }

    @objc func stopAnimating() {
        model.isAnimating = false
    }

    @objc(updateAdState:)
    func updateAdState(_ adState: NSDictionary) {
        let isRequired = bool(adState["isAdsRequired"]) || bool(adState["sessionAdsRequired"]) || bool(adState["isQueuePaused"])
        guard isRequired else {
            clearAdPresentation()
            return
        }
        let ads = adState["sessionAds"] as? [NSDictionary] ?? []
        if let ad = ads.first {
            updateAdPresentation(
                visible: true,
                chipText: bool(adState["isQueuePaused"]) ? "Queue Paused" : "Sponsored Break",
                title: string(ad["title"], fallback: "Watch to continue"),
                message: string(adState["message"], fallback: "Your launch will resume automatically after the ad."),
                adId: string(ad["adId"], fallback: "ad"),
                mediaUrl: string(ad["mediaUrl"]),
                durationMs: int(ad["durationMs"], fallback: max(1, int(ad["adLengthInSeconds"])) * 1000)
            )
            return
        }

        if bool(adState["isQueuePaused"]) {
            updateAdPresentation(
                visible: true,
                chipText: "Queue Paused",
                title: "Paused for ads",
                message: queuePausedAdMessage(adState),
                adId: "",
                mediaUrl: "",
                durationMs: 0
            )
            return
        }

        updateAdPresentation(
            visible: true,
            chipText: "Ad Pending",
            title: "Waiting for an ad",
            message: waitingForAdMessage(adState),
            adId: "",
            mediaUrl: "",
            durationMs: 0
        )
    }

    private func buildViewHierarchy() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        messageLabel.stringValue = message
        messageLabel.isHidden = true
        addSubview(messageLabel)
        let hosting = NSHostingView(rootView: OPNLoadingSwiftUIView(model: model))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
        updateQueueBadge()
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
        model.queuePosition = shouldShowQueueBadge() ? queuePosition : 0
    }

    private func resetAdPlayback() {
        adFallbackTimer?.invalidate()
        adFallbackTimer = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        removeAdTimeObserver()
        adPlayer?.pause()
        adPlayer = nil
        model.adPlayer = nil
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

    private func queuePausedAdMessage(_ adState: NSDictionary) -> String {
        let message = string(adState["message"])
        if !message.isEmpty { return message }
        return int(adState["gracePeriodSeconds"]) > 0 ? "Resume before the grace period ends." : "Resume ads to continue."
    }

    private func waitingForAdMessage(_ adState: NSDictionary) -> String {
        let message = string(adState["message"])
        if !message.isEmpty { return message }
        return bool(adState["serverSentEmptyAds"])
            ? "GeForce NOW has not returned one yet. OpenNOW will keep checking."
            : "GeForce NOW requires an ad before launch can continue."
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
}

private struct OPNLoadingSwiftUIView: View {
    @ObservedObject var model: OPNLoadingViewModel

    var body: some View {
        ZStack {
            Color(nsColor: OPNUIHelpers.color(rgb: 0x020304, alpha: 0.98))
                .ignoresSafeArea()

            if model.adVisible {
                adPanel
            } else {
                loadingPanel
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.adVisible)
        .animation(.easeOut(duration: 0.18), value: model.queuePosition)
        .animation(.easeOut(duration: 0.18), value: model.steps)
    }

    private var loadingPanel: some View {
        VStack(spacing: 22) {
            loadingMark
                .frame(width: 108, height: 108)
                .padding(.top, 10)

            VStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.54)))
                        .frame(width: max(70, 148 - CGFloat(index) * 24), height: 4)
                        .opacity(model.isAnimating ? 0.92 : 0.44)
                        .scaleEffect(x: model.isAnimating ? 1.0 : 0.42, y: 1.0, anchor: .center)
                        .animation(.easeInOut(duration: 0.92).repeatForever(autoreverses: true).delay(Double(index) * 0.12), value: model.isAnimating)
                }
            }

            VStack(spacing: 14) {
                Text(model.message)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textPrimary, alpha: 1)))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                if model.queuePosition > 0 {
                    queueBadge
                }

                if !model.steps.isEmpty {
                    stepRail
                        .padding(.top, 4)
                }
            }
        }
        .frame(minWidth: 320, idealWidth: model.steps.isEmpty ? 460 : 540, maxWidth: model.steps.isEmpty ? 460 : 540, minHeight: 252, idealHeight: model.steps.isEmpty ? 296 : 338, maxHeight: model.steps.isEmpty ? 296 : 338)
        .padding(.horizontal, 24)
        .background(panelBackground)
        .padding(24)
    }

    private var loadingMark: some View {
        ZStack {
            Circle()
                .trim(from: 0.04, to: 0.72)
                .stroke(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.78)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(model.isAnimating ? .degrees(360) : .degrees(0))
                .animation(.linear(duration: 1.65).repeatForever(autoreverses: false), value: model.isAnimating)

            Circle()
                .stroke(Color.white.opacity(0.26), style: StrokeStyle(lineWidth: 1, dash: [3, 7]))
                .padding(13)
                .rotationEffect(model.isAnimating ? .degrees(-360) : .degrees(0))
                .animation(.linear(duration: 4.2).repeatForever(autoreverses: false), value: model.isAnimating)

            Circle()
                .fill(Color(nsColor: OPNUIHelpers.color(rgb: 0x49D56B, alpha: 0.92)))
                .frame(width: 14, height: 14)
                .shadow(color: Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.84)), radius: 14)
                .scaleEffect(model.isAnimating ? 1.24 : 0.82)
                .animation(.easeInOut(duration: 0.82).repeatForever(autoreverses: true), value: model.isAnimating)

            Circle()
                .fill(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.92)))
                .frame(width: 8, height: 8)
                .offset(x: 54)
                .shadow(color: Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.90)), radius: 10)
                .rotationEffect(model.isAnimating ? .degrees(360) : .degrees(0))
                .animation(.linear(duration: 1.65).repeatForever(autoreverses: false), value: model.isAnimating)
        }
    }

    private var queueBadge: some View {
        Text("QUEUE  #\(model.queuePosition)")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 1)))
            .frame(width: 108, height: 28)
            .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x07140F, alpha: 0.92)), in: Capsule())
            .overlay(Capsule().stroke(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.36)), lineWidth: 1))
    }

    private var stepRail: some View {
        HStack(spacing: 7) {
            ForEach(model.steps.indices, id: \.self) { index in
                Capsule()
                    .fill(stepColor(index))
                    .frame(height: 3)
            }
        }
        .frame(maxWidth: 240)
    }

    private var adPanel: some View {
        VStack(spacing: 14) {
            ZStack {
                if let player = model.adPlayer {
                    OPNAdPlayerSwiftUIView(player: player)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.32))
                        .overlay(
                            VStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(model.adTitle)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        )
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.adChipText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 1)))
                    Text(model.adTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textPrimary, alpha: 1)))
                        .lineLimit(1)
                    Text(model.adMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textSecondary, alpha: 1)))
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                if model.queuePosition > 0 { queueBadge }
            }
        }
        .padding(22)
        .frame(minWidth: 360, idealWidth: 920, maxWidth: 920, minHeight: 420)
        .background(panelBackground)
        .padding(48)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(Color(nsColor: OPNUIHelpers.color(rgb: 0x0A0C0F, alpha: 0.96)))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.11), lineWidth: 1))
            .shadow(color: .black.opacity(0.32), radius: 32, y: 18)
    }

    private func stepColor(_ index: Int) -> Color {
        if index == model.currentStepIndex { return Color(nsColor: OPNUIHelpers.color(rgb: 0x49D56B, alpha: 0.96)) }
        if index < model.currentStepIndex { return Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.54)) }
        return .white.opacity(0.16)
    }
}

private struct OPNAdPlayerSwiftUIView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
