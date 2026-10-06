import SwiftUI

extension StreamLaunchConfiguration {
    /// The launch's own screenshots, shipped to the vendor as metadata, one of which the loading
    /// screen draws behind its scrim.
    var loadingArtworkURL: URL? {
        let urls = (metadata["loadingScreenshotUrls"] ?? "")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return StreamLaunchArtwork.url(candidates: urls, seed: id)
    }
}

/// The launch artwork is the most expensive image on the stream-start path, and it used to be the
/// only one drawn outside `CatalogImageCache`: a full-resolution screenshot, fetched and decoded,
/// then blurred to near-invisibility. An 18pt blur leaves nothing but a low-frequency wash behind,
/// so the rung - not the source - is what the screen actually shows, and the rung is small.
///
/// The CDN width and the decode rung are the same number, and they have to be. The URL keys the
/// cache entry while the rung is part of the load key, so a view decoding at any other rung misses
/// the entry the launch warmed and fetches the artwork a second time - the bug the marquee hero
/// carries a comment about.
enum StreamLaunchArtwork {
    /// 256 resolves at the blur's own scale rather than below it: on a 5120pt-wide window at 2x a
    /// source pixel covers 40 device pixels - 20pt of frame, against the 18pt blur radius. Half this
    /// rung would put a source pixel at 40pt, twice the blur, and the screen would show the rung's
    /// soft blocks instead of the wash. The blur is a fixed 18pt that does not scale with Interface
    /// Scale, so this rung does not either: it is the ratio between the two that the eye reads, and
    /// that ratio is the same at every scale.
    static let requestWidth = 256
    static let decodePixelSize = CGFloat(requestWidth)

    /// One screenshot per launch, picked by the session's own id so two launches of the same game do
    /// not open on the same frame.
    static func url(candidates: [String], seed: UUID) -> URL? {
        guard !candidates.isEmpty else { return nil }
        let hashed = seed.uuidString.utf8.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1) }
        return url(from: candidates[Int(hashed % UInt(candidates.count))])
    }

    /// Rewrites the vendor's full-resolution screenshot down to the rung above before it is ever
    /// fetched, so the download is a thumbnail too. A host the CDN does not resize is left alone.
    static func url(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: OPNGameService.optimizeImageURL(trimmed, width: requestWidth))
    }

    /// Warms the artwork on the reserved first-frame lane, so the screen's own read joins this
    /// decode instead of queueing a second one behind the launch's other work.
    static func prewarm(_ url: URL?, cache: any CatalogImageServing = CatalogImageCache.shared) {
        guard let url else { return }
        cache.prefetchPriority([url], maxPixelSize: decodePixelSize, retainingSourceData: false)
    }
}

/// Pure stage-word lookup. Queue and ad phrasing are the eyebrow's job now (`StreamLaunchLoadingScreen.eyebrowText`),
/// so this only ever answers "what step is this" - no caller does its own `stage` string assembly any more.
enum StreamLaunchLoadingStage {
    static func stageWord(stepIndex: Int) -> String {
        switch stepIndex {
        case StreamLaunchStep.checkNetworkRoute.rawValue: "Checking connection"
        case StreamLaunchStep.allocateCloudSession.rawValue: "Finding a server"
        case StreamLaunchStep.prepareTransport.rawValue: "Preparing stream"
        case StreamLaunchStep.connectTransport.rawValue: "Connecting"
        case StreamLaunchStep.connected.rawValue: "Ready"
        default: "Starting"
        }
    }
}

/// Shared loading screen for NVST connection setup and the catalog's ad-gated free-tier launch.
struct StreamLaunchLoadingScreen<Accessory: View>: View {
    let title: String
    let stepIndex: Int
    let artworkURL: URL?
    let queuePosition: Int?
    let accessoryPresented: Bool
    let stageOverride: String?
    let cancelAction: (() -> Void)?
    /// Measured window title-bar height (`WindowTopInsetReader`). The screen bleeds under the bar,
    /// so the title's top padding grows by this much or the bar swallows the padding entirely.
    let windowTopInset: CGFloat
    private let accessory: Accessory

    @Environment(\.accessibilityReduceMotion) private var isSystemReduceMotionEnabled
    @AppStorage(OPNThemePreferences.isMotionReducedKey) private var isReduceMotionPreferenceEnabled = false

    private var isMotionReduced: Bool {
        OPNDesign.Motion.isMotionReduced(system: isSystemReduceMotionEnabled, preference: isReduceMotionPreferenceEnabled)
    }

    init(title: String,
         stepIndex: Int,
         artworkURL: URL?,
         queuePosition: Int? = nil,
         accessoryPresented: Bool = false,
         stageOverride: String? = nil,
         cancelAction: (() -> Void)? = nil,
         windowTopInset: CGFloat = 0,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title.isEmpty ? "GeForce NOW" : title
        self.stepIndex = stepIndex
        self.artworkURL = artworkURL
        self.queuePosition = queuePosition
        self.accessoryPresented = accessoryPresented
        self.stageOverride = stageOverride
        self.cancelAction = cancelAction
        self.windowTopInset = windowTopInset
        self.accessory = accessory()
    }

    private func hPad(compact: Bool) -> CGFloat { compact ? 22 : OPNDesign.Spacing.pageHorizontal }

    var body: some View {
        GeometryReader { proxy in
            let compact = min(proxy.size.width, proxy.size.height) < 620
            let hPad = hPad(compact: compact)

            ZStack {
                artworkLayer(proxy: proxy)
                scrimLayer

                VStack(spacing: 0) {
                    titleRow(compact: compact)
                        .padding(.top, (compact ? OPNDesign.Spacing.large : OPNDesign.Spacing.xLarge) + windowTopInset)
                        .padding(.leading, hPad)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)

                    heroRegion(proxy: proxy, compact: compact)
                        .frame(maxWidth: .infinity, alignment: .center)

                    if let cancelAction {
                        Button("Cancel", action: cancelAction)
                            .buttonStyle(OPNModalSecondaryButtonStyle())
                            .accessibilityLabel("Cancel stream launch")
                            .padding(.top, OPNDesign.Spacing.small)
                    }

                    Spacer(minLength: 0)

                    footerBand(compact: compact)
                        .padding(.horizontal, hPad)
                        .padding(.bottom, compact ? OPNDesign.Spacing.large : OPNDesign.Spacing.xLarge)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            // Black, not `Surface.app`: this sits directly in front of the (also black-backed) video
            // surface it hands off to, so a shared black keeps the two surfaces seamless.
            .background(Color.black)
            .overlay(alignment: .top) {
                Rectangle().fill(OPNDesign.accent).frame(height: 2)
            }
        }
    }

    private func titleRow(compact: Bool) -> some View {
        Text(title)
            .font(.catalogText(size: compact ? 24 : 32, weight: .bold))
            .foregroundStyle(OPNDesign.Text.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    // MARK: - Artwork

    /// Cached, and cached at `StreamLaunchArtwork.decodePixelSize` - the rung the launch already
    /// warmed. `EmptyView` on both branches on purpose: the screen sits on black and fades the art in
    /// behind its scrim, so a skeleton or a failure icon here would be a flash of chrome the surface
    /// never had. Artwork that is missing or fails to fetch simply leaves the black background.
    private func artworkLayer(proxy: GeometryProxy) -> some View {
        Group {
            if let artworkURL {
                CatalogCachedImageView(
                    url: artworkURL,
                    contentMode: .fill,
                    maxPixelSize: StreamLaunchArtwork.decodePixelSize,
                    placeholder: EmptyView(),
                    failure: EmptyView()
                )
                .frame(width: proxy.size.width + 14, height: proxy.size.height + 14)
                .blur(radius: 18)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
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
                    .init(color: StreamHUDTheme.scrim, location: 0),
                    .init(color: StreamHUDTheme.scrim.opacity(0), location: 0.22)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                stops: [
                    .init(color: StreamHUDTheme.scrim.opacity(0), location: 0.66),
                    .init(color: StreamHUDTheme.scrim, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Hero region

    private func heroRegion(proxy: GeometryProxy, compact: Bool) -> some View {
        let horizontalLimit = proxy.size.width - 2 * hPad(compact: compact)
        // Windowed sizes can leave less height than the 16:9 hero wants. Cap the hero to what is
        // left once the title, footer, and cancel row are reserved, so the centered column never
        // overflows and clips the title's top padding. No floor: a tiny window gets a tiny hero
        // rather than a clipped title.
        let reservedHeight: CGFloat = (compact ? 200 : 280) + windowTopInset
        let verticalBudget = max(58, proxy.size.height - reservedHeight)
        let plateWidth = min(compact ? 380 : 640, horizontalLimit)
        let adWidth = min(plateWidth, ((verticalBudget - 58) * 16 / 9).rounded())
        let videoHeight = (adWidth * 9 / 16).rounded()
        // VendorEmbeddedSessionAdPlayer's info bar is two text lines (title + subtitle), not one -
        // 24pt vertical padding plus that stack runs ~58pt, not the single-line ~44pt estimate.
        let heroHeight = videoHeight + 58
        // The plate is one line, so the region collapses to the plate's own height and the cancel
        // button sits right beneath it instead of floating in the reserved ad space.
        let regionSize = accessoryPresented ? CGSize(width: adWidth, height: heroHeight)
                                            : CGSize(width: plateWidth, height: compact ? 64 : 84)

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
                    width: plateWidth,
                    height: compact ? 64 : 84,
                    reduceMotion: isMotionReduced
                )
            }
        }
        .frame(width: regionSize.width, height: regionSize.height)
    }

    // MARK: - Footer band

    private func footerBand(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.xSmall) {
            eyebrowText
                .font(.catalogText(size: 11, weight: .bold))
                .tracking(1.4)
                .lineLimit(1)

            HStack(spacing: OPNDesign.Spacing.xxSmall) {
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
        return Text(trailing.isEmpty ? counter : counter + " · ").foregroundStyle(OPNDesign.Text.tertiary)
            + Text(trailing.uppercased()).foregroundStyle(StreamHUDTheme.accentSoft)
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
        return VStack(spacing: OPNDesign.Spacing.xxSmall) {
            Group {
                switch segState {
                case .passed:
                    Rectangle().fill(OPNDesign.accent.opacity(0.72))
                case .current:
                    Rectangle().fill(OPNDesign.accent)
                        .overlay { Rectangle().strokeBorder(OPNDesign.Stroke.strong, lineWidth: 1) }
                case .pending:
                    Rectangle().strokeBorder(OPNDesign.Stroke.subtle, lineWidth: 1)
                }
            }
            .frame(height: compact ? 6 : 8)
            .scaleEffect(y: segState == .current ? 1.0 : (segState == .passed ? 0.78 : 0.42), anchor: .bottom)
            .opnMotion(OPNDesign.Motion.toggle, value: stepIndex)

            if !compact {
                Text(step.title.uppercased())
                    .font(.catalogText(size: 8, weight: .bold))
                    .tracking(0.7)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(segState == .current ? StreamHUDTheme.accentSoft : (segState == .passed ? OPNDesign.Text.tertiary : OPNDesign.Text.muted))
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
            Rectangle().fill(OPNDesign.Surface.chrome.opacity(0.55))
            Rectangle().strokeBorder(OPNDesign.Stroke.regular, lineWidth: 1)
            cornerBrackets
            if !reduceMotion { sweep }
            Text(stageWord.uppercased())
                .font(.catalogText(size: isLarge ? 22 : 16, weight: .bold))
                .tracking(isLarge ? 4 : 2.6)
                .foregroundStyle(StreamHUDTheme.accentSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, OPNDesign.Spacing.xLarge)
        }
        .frame(width: width, height: height)
    }

    private var cornerBrackets: some View {
        ForEach(BracketCorner.allCases, id: \.self) { corner in
            BracketShape(corner: corner, armLength: armLength)
                .stroke(OPNDesign.accent, lineWidth: 2)
        }
    }

    /// One 2.4s pass leading-to-trailing, matching the old signal's cycle length. Travel runs with the
    /// rail's direction so the plate reads as the same progress the footer is measuring.
    private var sweep: some View {
        TimelineView(.animation(minimumInterval: OPNDesign.Motion.heroFrameInterval, paused: false)) { timeline in
            let cycle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            let edgeFade = min(cycle, 1 - cycle) / 0.08
            let travel = cycle * (width + 64) - 32
            ZStack {
                Rectangle()
                    .fill(OPNDesign.accent)
                    .frame(width: 1.5)
                LinearGradient(colors: [.clear, OPNDesign.accent.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
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
