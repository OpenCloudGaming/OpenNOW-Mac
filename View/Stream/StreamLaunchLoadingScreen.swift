import SwiftUI

extension StreamLaunchConfiguration {
    var loadingArtworkURL: URL? {
        let urls = (metadata["loadingScreenshotUrls"] ?? "")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { return nil }
        let seed = id.uuidString.utf8.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1) }
        return URL(string: urls[Int(seed % UInt(urls.count))])
    }
}

/// Pure stage-word lookup. Queue and ad phrasing are the eyebrow's job now (`StreamLaunchLoadingScreen.eyebrowText`),
/// so this only ever answers "what step is this" - no caller does its own `stage` string assembly any more.
enum StreamLaunchLoadingStage {
    static func stageWord(stepIndex: Int) -> String {
        switch stepIndex {
        case StreamLaunchStep.checkNetworkRoute.rawValue: "Checking connection"
        case StreamLaunchStep.allocateCloudSession.rawValue: "Finding a server"
        case StreamLaunchStep.receiveStreamOffer.rawValue: "Preparing stream"
        case StreamLaunchStep.negotiateWebRTC.rawValue: "Connecting"
        case StreamLaunchStep.connected.rawValue: "Ready"
        default: "Starting"
        }
    }
}

/// Full-cover screen shown between the user clicking Play and the first video frame, on all three
/// transports (native NVST, WebRTC, and the catalog's ad-gated free-tier launch). Queueing and the
/// ad only ever change the eyebrow's trailing phrase and the hero region's content, never the
/// reserved layout around them - which is what keeps the screen from jumping as states arrive.
struct StreamLaunchLoadingScreen<Accessory: View>: View {
    let title: String
    let stepIndex: Int
    let artworkURL: URL?
    let queuePosition: Int?
    let accessoryPresented: Bool
    let stageOverride: String?
    let cancelAction: (() -> Void)?
    private let accessory: Accessory

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String,
         stepIndex: Int,
         artworkURL: URL?,
         queuePosition: Int? = nil,
         accessoryPresented: Bool = false,
         stageOverride: String? = nil,
         cancelAction: (() -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title.isEmpty ? "GeForce NOW" : title
        self.stepIndex = stepIndex
        self.artworkURL = artworkURL
        self.queuePosition = queuePosition
        self.accessoryPresented = accessoryPresented
        self.stageOverride = stageOverride
        self.cancelAction = cancelAction
        self.accessory = accessory()
    }

    private func hPad(compact: Bool) -> CGFloat { compact ? 22 : OpenNOWDesign.Spacing.pageHorizontal }

    var body: some View {
        GeometryReader { proxy in
            let compact = min(proxy.size.width, proxy.size.height) < 620
            let hPad = hPad(compact: compact)

            ZStack {
                artworkLayer(proxy: proxy)
                scrimLayer

                VStack(spacing: 0) {
                    titleRow(compact: compact)
                        .padding(.top, compact ? OpenNOWDesign.Spacing.large : OpenNOWDesign.Spacing.xLarge)
                        .padding(.leading, hPad)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: OpenNOWDesign.Spacing.xLarge)

                    heroRegion(proxy: proxy, compact: compact)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Spacer(minLength: OpenNOWDesign.Spacing.xLarge)

                    footerBand(compact: compact)
                        .padding(.horizontal, hPad)
                        .padding(.bottom, compact ? OpenNOWDesign.Spacing.large : OpenNOWDesign.Spacing.xLarge)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            // Black, not `Surface.app`: this sits directly in front of the (also black-backed) video
            // surface it hands off to, so a shared black keeps the two surfaces seamless.
            .background(Color.black)
            .overlay(alignment: .top) {
                Rectangle().fill(OpenNOWDesign.accent).frame(height: 2)
            }
        }
    }

    private func titleRow(compact: Bool) -> some View {
        Text(title)
            .font(.catalogText(size: compact ? 24 : 32, weight: .bold))
            .foregroundStyle(OpenNOWDesign.Text.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    // MARK: - Artwork

    private func artworkLayer(proxy: GeometryProxy) -> some View {
        Group {
            if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width + 14, height: proxy.size.height + 14)
                            .blur(radius: 10)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// Two capped strips, not one three-stop gradient: full strength only behind the title and the
    /// footer, clear through the middle so the hero region - and the art behind it - reads unobstructed.
    private var scrimLayer: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: WebRTCMediaStreamTheme.scrim, location: 0),
                    .init(color: WebRTCMediaStreamTheme.scrim.opacity(0), location: 0.22)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                stops: [
                    .init(color: WebRTCMediaStreamTheme.scrim.opacity(0), location: 0.66),
                    .init(color: WebRTCMediaStreamTheme.scrim, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Hero region

    private func heroRegion(proxy: GeometryProxy, compact: Bool) -> some View {
        let adWidth = min(compact ? 380 : 640, proxy.size.width - 2 * hPad(compact: compact))
        let videoHeight = (adWidth * 9 / 16).rounded()
        // VendorEmbeddedSessionAdPlayer's info bar is two text lines (title + subtitle), not one -
        // 24pt vertical padding plus that stack runs ~58pt, not the single-line ~44pt estimate.
        let heroHeight = videoHeight + 58

        return ZStack {
            if accessoryPresented {
                // Sized to the accessory's actual composition (video area + its own info-bar gutter),
                // not wrapped in `.aspectRatio` - that only knows the video's own ratio and fights the
                // info bar's real height underneath it.
                accessory
                    .frame(width: adWidth, height: heroHeight, alignment: .top)
            } else {
                StreamLaunchStagePlate(
                    stageWord: plateWord,
                    width: adWidth,
                    height: compact ? 64 : 84,
                    reduceMotion: reduceMotion
                )
            }
        }
        .frame(width: adWidth, height: heroHeight)
    }

    // MARK: - Footer band

    private func footerBand(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xSmall) {
            HStack(alignment: .center, spacing: OpenNOWDesign.Spacing.medium) {
                eyebrowText
                    .font(.catalogText(size: 11, weight: .bold))
                    .tracking(1.4)
                    .lineLimit(1)
                Spacer(minLength: OpenNOWDesign.Spacing.medium)
                if let cancelAction {
                    Button("Cancel", action: cancelAction)
                        .buttonStyle(OpenNOWModalSecondaryButtonStyle())
                        .accessibilityLabel("Cancel stream launch")
                }
            }
            // Reserved whether or not Cancel is offered, so its appearance never shoves the rail.
            .frame(minHeight: 36)

            HStack(spacing: OpenNOWDesign.Spacing.xxSmall) {
                ForEach(StreamLaunchStep.allCases, id: \.rawValue) { step in
                    railSegment(step: step, compact: compact)
                }
            }
        }
    }

    private var queued: Int? { queuePosition.flatMap { $0 > 0 ? $0 : nil } }

    /// The plate is the headline, so it takes the stage word and the eyebrow below it does not repeat
    /// it - queueing renames the headline rather than adding a second line about it.
    private var plateWord: String {
        queued != nil ? "Waiting in queue" : StreamLaunchLoadingStage.stageWord(stepIndex: stepIndex)
    }

    private var eyebrowText: Text {
        let total = StreamLaunchStep.allCases.count
        let clamped = min(max(stepIndex, 0), total - 1)
        let counter = stepIndex >= 0 ? "STEP \(clamped + 1) OF \(total)" : "STEP — OF \(total)"
        var phrases: [String] = []
        // The ad replaces the plate, so with no plate on screen the eyebrow has to carry the headline.
        if let stageOverride { phrases.append(stageOverride) } else if accessoryPresented { phrases.append(plateWord) }
        if let queued { phrases.append("Position \(queued)") }
        let trailing = phrases.joined(separator: " · ")
        return Text(trailing.isEmpty ? counter : counter + " · ").foregroundStyle(OpenNOWDesign.Text.tertiary)
            + Text(trailing.uppercased()).foregroundStyle(WebRTCMediaStreamTheme.accentSoft)
    }

    // MARK: - Step rail

    private enum RailSegmentState { case passed, current, pending }

    private func state(for index: Int) -> RailSegmentState {
        guard stepIndex >= 0 else { return .pending }
        // Terminal: everything reads done rather than leaving a "current" cell lit while the surface
        // is about to hand off to the real stream.
        if stepIndex == StreamLaunchStep.connected.rawValue { return .passed }
        let clamped = min(max(stepIndex, 0), StreamLaunchStep.allCases.count - 1)
        if index < clamped { return .passed }
        if index == clamped { return .current }
        return .pending
    }

    private func railSegment(step: StreamLaunchStep, compact: Bool) -> some View {
        let segState = state(for: step.rawValue)
        return VStack(spacing: OpenNOWDesign.Spacing.xxSmall) {
            Group {
                switch segState {
                case .passed:
                    Rectangle().fill(OpenNOWDesign.accent.opacity(0.72))
                case .current:
                    Rectangle().fill(OpenNOWDesign.accent)
                        .overlay { Rectangle().strokeBorder(OpenNOWDesign.Stroke.strong, lineWidth: 1) }
                case .pending:
                    Rectangle().strokeBorder(OpenNOWDesign.Stroke.subtle, lineWidth: 1)
                }
            }
            .frame(height: compact ? 6 : 8)
            .scaleEffect(y: segState == .current ? 1.0 : (segState == .passed ? 0.78 : 0.42), anchor: .bottom)
            .opnMotion(OpenNOWDesign.Motion.toggle, value: stepIndex)

            if !compact {
                Text(step.title.uppercased())
                    .font(.catalogText(size: 8, weight: .bold))
                    .tracking(0.7)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(segState == .current ? WebRTCMediaStreamTheme.accentSoft : (segState == .passed ? OpenNOWDesign.Text.tertiary : OpenNOWDesign.Text.muted))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Squared replacement for the old rotating-arc `StreamLaunchSignal`: a wide letterbox plate built
/// from `Rectangle` alone, carrying the stage word and a travelling sweep. It deliberately shows no
/// step count - the eyebrow and rail below it already say where in the sequence this is.
private struct StreamLaunchStagePlate: View {
    let stageWord: String
    let width: CGFloat
    let height: CGFloat
    let reduceMotion: Bool

    private var isLarge: Bool { height >= 84 }
    private var armLength: CGFloat { isLarge ? 18 : 12 }

    var body: some View {
        ZStack {
            Rectangle().fill(OpenNOWDesign.Surface.chrome.opacity(0.55))
            Rectangle().strokeBorder(OpenNOWDesign.Stroke.regular, lineWidth: 1)
            cornerBrackets
            if !reduceMotion { sweep }
            Text(stageWord.uppercased())
                .font(.catalogText(size: isLarge ? 22 : 16, weight: .bold))
                .tracking(isLarge ? 4 : 2.6)
                .foregroundStyle(WebRTCMediaStreamTheme.accentSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, OpenNOWDesign.Spacing.xLarge)
        }
        .frame(width: width, height: height)
    }

    private var cornerBrackets: some View {
        ForEach(BracketCorner.allCases, id: \.self) { corner in
            BracketShape(corner: corner, armLength: armLength)
                .stroke(OpenNOWDesign.accent, lineWidth: 2)
        }
    }

    /// One 2.4s pass leading-to-trailing, matching the old signal's cycle length. Travel runs with the
    /// rail's direction so the plate reads as the same progress the footer is measuring.
    private var sweep: some View {
        TimelineView(.animation(minimumInterval: OpenNOWDesign.Motion.heroFrameInterval, paused: false)) { timeline in
            let cycle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            let edgeFade = min(cycle, 1 - cycle) / 0.08
            let travel = cycle * (width + 64) - 32
            ZStack {
                Rectangle()
                    .fill(OpenNOWDesign.accent)
                    .frame(width: 1.5)
                LinearGradient(colors: [.clear, OpenNOWDesign.accent.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: isLarge ? 72 : 48)
            }
            .opacity(min(1, edgeFade))
            .position(x: travel, y: height / 2)
            .blendMode(.screen)
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private enum BracketCorner: CaseIterable, Hashable { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    private struct BracketShape: Shape {
        let corner: BracketCorner
        let armLength: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let (origin, horizontal, vertical): (CGPoint, CGVector, CGVector)
            switch corner {
            case .topLeading:
                origin = CGPoint(x: rect.minX, y: rect.minY)
                horizontal = CGVector(dx: armLength, dy: 0)
                vertical = CGVector(dx: 0, dy: armLength)
            case .topTrailing:
                origin = CGPoint(x: rect.maxX, y: rect.minY)
                horizontal = CGVector(dx: -armLength, dy: 0)
                vertical = CGVector(dx: 0, dy: armLength)
            case .bottomLeading:
                origin = CGPoint(x: rect.minX, y: rect.maxY)
                horizontal = CGVector(dx: armLength, dy: 0)
                vertical = CGVector(dx: 0, dy: -armLength)
            case .bottomTrailing:
                origin = CGPoint(x: rect.maxX, y: rect.maxY)
                horizontal = CGVector(dx: -armLength, dy: 0)
                vertical = CGVector(dx: 0, dy: -armLength)
            }
            path.move(to: CGPoint(x: origin.x + horizontal.dx, y: origin.y + horizontal.dy))
            path.addLine(to: origin)
            path.addLine(to: CGPoint(x: origin.x + vertical.dx, y: origin.y + vertical.dy))
            return path
        }
    }
}
