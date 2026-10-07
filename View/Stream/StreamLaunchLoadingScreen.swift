import SwiftUI

extension StreamLaunchConfiguration {
    var loadingArtworkURL: URL? {
        let candidates = (metadata["loadingScreenshotUrls"] ?? "").split(separator: "\n").map(String.init)
        return StreamLaunchArtwork.selectedURL(candidates: candidates, seed: id)
    }
}

/// The launch artwork is a full-bleed screenshot blurred by 18pt, so the rung - not the source - is
/// what the screen shows. The vendor URL keeps its own shape; only its CDN rung is replaced.
enum StreamLaunchArtwork {
    /// 256 resolves at the blur's own scale: on a 5120pt-wide window at 2x a source pixel covers
    /// 20pt of frame against the 18pt blur radius, where 128 would put it at 40pt.
    static let decodePixelSize: CGFloat = 256

    /// One screenshot per launch, picked by the session's own id so two launches of the same game do
    /// not open on the same frame. A candidate the cache cannot fetch is skipped, not chosen.
    static func selectedURL(candidates: [String], seed: UUID) -> URL? {
        let usableCandidates = candidates.compactMap { fetchableURL(from: $0) }
        guard !usableCandidates.isEmpty else { return nil }
        let hashedSeed = seed.uuidString.utf8.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1) }
        return urlAtDecodeRung(usableCandidates[Int(hashedSeed % UInt(usableCandidates.count))])
    }

    /// Warms the artwork on the reserved first-frame lane, so the screen's read joins this decode
    /// instead of queueing a second one behind the launch's other work.
    static func prewarm(_ url: URL?) {
        guard let url else { return }
        CatalogImageCache.shared.prefetchPriority([url], maxPixelSize: decodePixelSize, retainingSourceData: false)
    }

    /// The cache fetches this URL, so a relative or non-HTTP candidate fails its download and leaves
    /// the screen black while another candidate was fetchable.
    private static func fetchableURL(from candidate: String) -> URL? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.host?.isEmpty == false else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Replaces the `;f=webp;w=` rung `OPNGameService+Parsing` put on the vendor URL, so the download
    /// is the same size as the decode. A URL without that exact suffix is used as it stands: appending
    /// a rung produced a URL the CDN does not serve.
    private static func urlAtDecodeRung(_ url: URL) -> URL {
        let value = url.absoluteString
        guard let rungStart = value.range(of: ";f=webp;w=", options: .backwards) else { return url }
        let rungValue = value[rungStart.upperBound...]
        guard !rungValue.isEmpty, rungValue.allSatisfy(\.isNumber) else { return url }
        let rewritten = value.replacingCharacters(in: rungStart.upperBound..., with: String(Int(decodePixelSize)))
        return URL(string: rewritten) ?? url
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

    /// `Color.clear`, not `EmptyView`: an empty placeholder leaves the container sizeless while the
    /// artwork loads, and the oversized frame below then lays the image out at zero size.
    private func artworkLayer(proxy: GeometryProxy) -> some View {
        Group {
            if let artworkURL {
                CatalogCachedImageView(
                    url: artworkURL,
                    contentMode: .fill,
                    maxPixelSize: StreamLaunchArtwork.decodePixelSize,
                    placeholder: Color.clear,
                    failure: Color.clear
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
