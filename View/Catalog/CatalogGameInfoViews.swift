//  The full-screen game info page behind MORE INFO in the detail panel. Everything the panel has
//  to truncate lives here at full length: the description, the screenshots, the NVIDIA technology
//  rows, the content rating and the spec table.
//
//  Screenshots open a lightbox rather than swapping the hero: the strip sits well below the fold,
//  so a hero swap changed something the reader could not see.
//
//  The window's titlebar is transparent and the content runs under it, so every control anchored to
//  the top of the page - the close button, the logo, the lightbox chrome - is offset by the measured
//  window top inset. Artwork is free to bleed under the titlebar; controls are not.
//
//  Escape and the arrow keys come off a local event monitor rather than `onExitCommand`: that
//  modifier only fires for the focused view, and this page is a full-screen overlay that never
//  takes focus, so the key press went to whatever was focused behind it.
//
//  Both scroll views hide their indicators with `.never`, not `.hidden`: `.hidden` still yields to
//  "Show scroll bars: Always" in System Settings, and the rounded system scroller that appears then
//  is exactly the chrome DESIGN.md rules out. The strip carries square edge arrows instead, so it
//  stays navigable without one.
//
//  Two deliberate performance choices, because this page opens over a live catalog:
//  - the hero reuses the same URLs and pixel budget the detail panel already decoded, so opening
//    the page is a cache hit rather than a second decode of the same artwork;
//  - the screenshot strip is lazy and asks for thumbnail-sized pixels, so a game with a dozen
//    screenshots decodes the two or three that are actually on screen.
//

import AppKit
import SwiftUI

struct CatalogGameInfoOverlay: View {
    let viewModel: CatalogViewModel
    /// Height of the transparent titlebar the window content runs under.
    var topInset: CGFloat = 0
    @Environment(\.opnUIScale) private var uiScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lightboxIndex: Int?
    @State private var stripAnchor = 0
    @State private var hasEntered = false
    @State private var isCloseHovering = false

    var body: some View {
        if let game = viewModel.selectedGame {
            GeometryReader { proxy in
                let metrics = CatalogGameInfoMetrics(viewport: proxy.size, scale: uiScale)
                let images = game.detailImageURLs
                ZStack(alignment: .topTrailing) {
                    OpenNOWDesign.Surface.app
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            hero(game: game, metrics: metrics, viewport: proxy.size)
                            columns(game: game, images: images, metrics: metrics)
                                .padding(.horizontal, metrics.horizontalPadding)
                                .padding(.top, OpenNOWDesign.Spacing.xxLarge(scale: uiScale))
                                .padding(.bottom, OpenNOWDesign.Spacing.xxxLarge(scale: uiScale) * 1.5)
                        }
                        .frame(width: proxy.size.width, alignment: .topLeading)
                        // Content rises a little as it fades in, so the page reads as arriving over
                        // the catalog rather than cutting to it.
                        .offset(y: hasEntered ? 0 : 18)
                        .opacity(hasEntered ? 1 : 0)
                    }
                    .scrollIndicators(.never)
                    closeButton
                    if let index = lightboxIndex, images.indices.contains(index) {
                        CatalogGameInfoLightbox(
                            viewModel: viewModel,
                            images: images,
                            index: index,
                            uiScale: uiScale,
                            topInset: topInset,
                            move: { delta in moveLightbox(delta: delta, count: images.count) },
                            close: { lightboxIndex = nil }
                        )
                        .transition(.opacity)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background(OpenNOWDesign.Surface.app)
            .background(CatalogGameInfoKeyMonitor { key in
                handleKey(key, imageCount: game.detailImageURLs.count)
            })
            .onAppear {
                guard !reduceMotion else { hasEntered = true; return }
                withAnimation(.easeOut(duration: 0.26)) { hasEntered = true }
            }
            .onChange(of: game.catalogIdentity) { _, _ in lightboxIndex = nil }
        }
    }

    // MARK: - Hero

    private func hero(game: OPNCatalogGameObject, metrics: CatalogGameInfoMetrics, viewport: CGSize) -> some View {
        let imageURL = game.bestDetailImageURL
        return ZStack(alignment: .bottomLeading) {
            CatalogRemoteImage(url: viewModel.optimizedImageURL(imageURL, width: 1600), contentMode: .fill, maxPixelSize: 1600)
                .frame(width: viewport.width, height: metrics.heroHeight)
                .clipped()
            // Two stops, not one: the lower band has to carry white text over whatever the
            // screenshot happens to be, and the very bottom has to land on the page surface.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: .black.opacity(0.34), location: 0.46),
                    .init(color: .black.opacity(0.78), location: 0.78),
                    .init(color: OpenNOWDesign.Surface.app, location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            heroCaption(game: game, metrics: metrics)
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.bottom, OpenNOWDesign.Spacing.xLarge(scale: uiScale))
        }
        .frame(width: viewport.width, height: metrics.heroHeight)
        .overlay(alignment: .topLeading) {
            if !game.bestLogoImageURL.isEmpty, let logoURL = viewModel.optimizedImageURL(game.bestLogoImageURL, width: 300) {
                CatalogCachedImageView(url: logoURL, contentMode: .fit, maxPixelSize: 300, placeholder: EmptyView(), failure: EmptyView())
                    .frame(width: 148 * uiScale, height: 64 * uiScale, alignment: .topLeading)
                    .padding(.leading, metrics.horizontalPadding)
                    .padding(.top, topInset + OpenNOWDesign.Spacing.small(scale: uiScale))
                    .opacity(0.92)
            }
        }
    }

    private func heroCaption(game: OPNCatalogGameObject, metrics: CatalogGameInfoMetrics) -> some View {
        VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
            HStack(alignment: .bottom, spacing: OpenNOWDesign.Spacing.medium(scale: uiScale)) {
                Text(game.title.isEmpty ? "Selected Game" : game.title)
                    .nvidiaFont(size: 40, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.Text.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                favoriteButton(game: game)
                Spacer(minLength: 0)
            }
            metadataLine(game: game)
            FlowLayout(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
                ForEach(GameDetailPresentation.capabilityLabels(game: game), id: \.self) { label in
                    Text(label)
                        .nvidiaFont(size: 12, weight: .bold)
                        .foregroundStyle(OpenNOWDesign.Text.primary)
                        .padding(.horizontal, OpenNOWDesign.Spacing.xSmall(scale: uiScale))
                        .frame(height: 24 * uiScale)
                        .background(Color.white.opacity(0.12))
                        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
                }
            }
            .frame(maxWidth: metrics.mainColumnWidth, alignment: .leading)
            statusLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A labelled control rather than a bare glyph. On the panel the heart sits next to a status
    /// line that reports what a tap did; here it is the only thing on screen that can answer, so it
    /// carries its own state - and the caption below prints whatever the call came back with.
    private func favoriteButton(game: OPNCatalogGameObject) -> some View {
        let favorited = viewModel.isFavorite(game)
        return Button { viewModel.toggleFavoriteSelectedGame() } label: {
            HStack(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
                Image(systemName: favorited ? "heart.fill" : "heart")
                    .nvidiaFont(size: 13, weight: .bold)
                Text(favorited ? "FAVORITED" : "FAVORITE")
                    .nvidiaFont(size: 12, weight: .bold)
                    .tracking(0.8)
            }
            .foregroundStyle(favorited ? .black.opacity(0.88) : OpenNOWDesign.Text.primary)
            .padding(.horizontal, OpenNOWDesign.Spacing.small(scale: uiScale))
            .frame(height: 32 * uiScale)
            .background(favorited ? OpenNOWDesign.accent : Color.white.opacity(0.12))
            .overlay { Rectangle().stroke(favorited ? OpenNOWDesign.accent : OpenNOWDesign.Stroke.regular, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(favorited ? "Remove from favorites" : "Add to favorites")
    }

    /// What the last catalog call said. Without it a favorite that the service refused looks exactly
    /// like a button that does nothing.
    @ViewBuilder
    private var statusLine: some View {
        let error = viewModel.errorMessage
        let action = viewModel.actionMessage
        if !error.isEmpty || !action.isEmpty {
            Text(error.isEmpty ? action : error)
                .nvidiaFont(size: 12, weight: .bold)
                .foregroundStyle(error.isEmpty ? OpenNOWDesign.Text.secondary : OpenNOWDesign.Semantic.destructive)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metadataLine(game: OPNCatalogGameObject) -> some View {
        HStack(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
            if !game.ratingLabel.isEmpty {
                Text(game.ratingLabel.uppercased())
            }
            if game.maxOnlinePlayers > 1 { Image(systemName: "person.3.fill") }
            if game.supportsKeyboard { Image(systemName: "keyboard") }
            if game.supportsGamepad { Image(systemName: "gamecontroller.fill") }
            if !game.genreLine.isEmpty {
                Text(game.genres.prefix(3).joined(separator: ", ").uppercased())
                    .lineLimit(1)
            }
        }
        .nvidiaFont(size: 12, weight: .bold)
        .tracking(0.6)
        .foregroundStyle(OpenNOWDesign.Text.secondary)
    }

    private var closeButton: some View {
        Button { viewModel.closeGameInfo() } label: {
            Image(systemName: "xmark")
                .nvidiaFont(size: 13, weight: .bold)
                .foregroundStyle(OpenNOWDesign.Text.primary)
                .frame(width: 34 * uiScale, height: 34 * uiScale)
                .background(Color.black.opacity(isCloseHovering ? 0.62 : 0.42))
                .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovering = $0 }
        .padding(.trailing, OpenNOWDesign.Spacing.medium(scale: uiScale))
        .padding(.top, topInset + OpenNOWDesign.Spacing.xSmall(scale: uiScale))
        .accessibilityLabel("Close game info")
    }

    // MARK: - Body

    @ViewBuilder
    private func columns(game: OPNCatalogGameObject, images: [String], metrics: CatalogGameInfoMetrics) -> some View {
        if metrics.sideColumnWidth > 0 {
            HStack(alignment: .top, spacing: metrics.columnGap) {
                mainColumn(game: game, images: images, metrics: metrics)
                    .frame(width: metrics.mainColumnWidth, alignment: .leading)
                sideColumn(game: game)
                    .frame(width: metrics.sideColumnWidth, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xxLarge(scale: uiScale)) {
                mainColumn(game: game, images: images, metrics: metrics)
                sideColumn(game: game)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mainColumn(game: OPNCatalogGameObject, images: [String], metrics: CatalogGameInfoMetrics) -> some View {
        let longDescription = GameDetailPresentation.longDescription(game: game)
        let technologies = GameDetailPresentation.supportedTechnologyLabels(game: game)
        return VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xxLarge(scale: uiScale)) {
            CatalogGameInfoSection(label: "ABOUT THIS GAME", uiScale: uiScale) {
                VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.medium(scale: uiScale)) {
                    Text(GameDetailPresentation.shortDescription(game: game))
                        .nvidiaFont(size: 16, weight: .medium)
                        .foregroundStyle(OpenNOWDesign.Text.primary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if !longDescription.isEmpty {
                        Text(longDescription)
                            .nvidiaFont(size: 14, weight: .medium)
                            .foregroundStyle(OpenNOWDesign.Text.secondary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if images.count > 1 {
                CatalogGameInfoSection(label: "SCREENSHOTS", uiScale: uiScale) {
                    screenshotStrip(images: images, metrics: metrics)
                }
            }
            if !technologies.isEmpty {
                CatalogGameInfoSection(label: "NVIDIA TECHNOLOGY", uiScale: uiScale) {
                    VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
                        ForEach(technologies, id: \.self) { technology in
                            CatalogFeatureAvailabilityRow(
                                title: technology,
                                message: GameDetailPresentation.featureMessage(technology),
                                locked: GameDetailPresentation.featureIsLocked(technology)
                            )
                        }
                    }
                }
            }
        }
    }

    private func screenshotStrip(images: [String], metrics: CatalogGameInfoMetrics) -> some View {
        let stripHeight = metrics.thumbnailWidth * 9 / 16
        return ScrollViewReader { proxy in
            // Lazy on purpose: a wide catalog game ships a dozen screenshots and only two or three
            // fit on screen, so the rest never reach the decoder until they scroll in.
            ScrollView(.horizontal) {
                LazyHStack(spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, url in
                        thumbnail(url: url, index: index, width: metrics.thumbnailWidth)
                            .id(index)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.never)
            .frame(height: stripHeight + 2)
            .overlay(alignment: .leading) {
                stripArrow(name: "chevron.left", label: "Previous screenshots", height: stripHeight, enabled: stripAnchor > 0) {
                    scrollStrip(to: stripAnchor - metrics.thumbnailsPerPage, count: images.count, proxy: proxy)
                }
            }
            .overlay(alignment: .trailing) {
                stripArrow(name: "chevron.right", label: "More screenshots", height: stripHeight, enabled: stripAnchor + metrics.thumbnailsPerPage < images.count) {
                    scrollStrip(to: stripAnchor + metrics.thumbnailsPerPage, count: images.count, proxy: proxy)
                }
            }
        }
    }

    private func thumbnail(url: String, index: Int, width: CGFloat) -> some View {
        Button {
            if reduceMotion {
                lightboxIndex = index
            } else {
                withAnimation(.easeOut(duration: 0.18)) { lightboxIndex = index }
            }
        } label: {
            CatalogRemoteImage(url: viewModel.optimizedImageURL(url, width: 640), contentMode: .fill, maxPixelSize: 640)
                .frame(width: width, height: width * 9 / 16)
                .clipped()
                .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .nvidiaFont(size: 10, weight: .bold)
                        .foregroundStyle(OpenNOWDesign.Text.primary)
                        .frame(width: 22 * uiScale, height: 22 * uiScale)
                        .background(Color.black.opacity(0.55))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open screenshot \(index + 1)")
    }

    /// Pages the strip by whole thumbnails and remembers where it left off, so the arrows know when
    /// they have run out of strip and can take themselves off screen.
    private func scrollStrip(to index: Int, count: Int, proxy: ScrollViewProxy) {
        let target = min(max(index, 0), max(0, count - 1))
        stripAnchor = target
        if reduceMotion {
            proxy.scrollTo(target, anchor: .leading)
        } else {
            withAnimation(.easeOut(duration: 0.24)) { proxy.scrollTo(target, anchor: .leading) }
        }
    }

    @ViewBuilder
    private func stripArrow(name: String, label: String, height: CGFloat, enabled: Bool, action: @escaping () -> Void) -> some View {
        if enabled {
            Button(action: action) {
                Image(systemName: name)
                    .nvidiaFont(size: 13, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.Text.primary)
                    .frame(width: 30 * uiScale, height: min(64 * uiScale, height))
                    .background(Color.black.opacity(0.72))
                    .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .transition(.opacity)
        }
    }

    /// Escape unwinds one layer at a time: the lightbox first, then the page. Arrow keys only mean
    /// something while the lightbox is up; anywhere else they belong to the scroll view.
    private func handleKey(_ key: CatalogGameInfoKey, imageCount: Int) -> Bool {
        switch key {
        case .escape:
            if lightboxIndex != nil {
                lightboxIndex = nil
            } else {
                viewModel.closeGameInfo()
            }
            return true
        case .left, .right:
            guard lightboxIndex != nil else { return false }
            moveLightbox(delta: key == .left ? -1 : 1, count: imageCount)
            return true
        }
    }

    private func moveLightbox(delta: Int, count: Int) {
        guard count > 1, let index = lightboxIndex else { return }
        lightboxIndex = (index + delta + count) % count
    }

    private func sideColumn(game: OPNCatalogGameObject) -> some View {
        let descriptors = GameDetailPresentation.ratingDescriptors(game: game)
        return VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xxLarge(scale: uiScale)) {
            CatalogGameInfoSection(label: "DETAILS", uiScale: uiScale) {
                VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
                    CatalogGameInfoSpecRow(label: "Publisher", value: game.publisherName, uiScale: uiScale)
                    CatalogGameInfoSpecRow(label: "Developer", value: game.developerName, uiScale: uiScale)
                    CatalogGameInfoSpecRow(label: "Release Date", value: GameDetailPresentation.releaseDateLine(game: game), uiScale: uiScale)
                    CatalogGameInfoSpecRow(label: "Input", value: GameDetailPresentation.inputLine(game: game, selectedVariant: viewModel.selectedVariant(in: game)), uiScale: uiScale)
                    CatalogGameInfoSpecRow(label: "Players", value: GameDetailPresentation.playerLine(game: game), uiScale: uiScale)
                    CatalogGameInfoSpecRow(label: "Stores", value: game.storeLine, uiScale: uiScale)
                    CatalogGameInfoSpecRow(label: "Genres", value: game.genreLine, uiScale: uiScale)
                }
            }
            CatalogGameInfoSection(label: "CONTENT RATING", uiScale: uiScale) {
                HStack(alignment: .top, spacing: OpenNOWDesign.Spacing.medium(scale: uiScale)) {
                    if !game.ratingLabel.isEmpty {
                        CatalogRatingBadge(game: game, shortRating: GameDetailPresentation.esrbShortRating(game.ratingLabel))
                    }
                    VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
                        Text(game.ratingLabel.isEmpty ? "CLOUD GAMING" : game.ratingLabel.uppercased())
                            .nvidiaFont(size: 13, weight: .bold)
                            .foregroundStyle(OpenNOWDesign.Text.primary)
                        ForEach(descriptors, id: \.self) { descriptor in
                            Text(descriptor)
                                .nvidiaFont(size: 12, weight: .medium)
                                .foregroundStyle(OpenNOWDesign.Text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// Viewport-derived geometry for the info page. Width decides whether the spec column sits beside
/// the description or under it: below roughly 900pt the two-column split leaves the description too
/// narrow to read.
private struct CatalogGameInfoMetrics {
    let horizontalPadding: CGFloat
    let heroHeight: CGFloat
    let columnGap: CGFloat
    let sideColumnWidth: CGFloat
    let mainColumnWidth: CGFloat
    let thumbnailWidth: CGFloat
    /// How far one arrow press moves the strip: whole thumbnails, never a partial one.
    let thumbnailsPerPage: Int

    init(viewport: CGSize, scale: CGFloat) {
        let padding = OpenNOWDesign.clamped(viewport.width * 0.06, minimum: 28, maximum: 96) * scale
        horizontalPadding = min(padding, viewport.width * 0.14)
        heroHeight = OpenNOWDesign.clamped(viewport.height * 0.44, minimum: 220, maximum: 560)
        columnGap = OpenNOWDesign.clamped(viewport.width * 0.035, minimum: 24, maximum: 64) * scale
        let available = max(280, viewport.width - horizontalPadding * 2)
        let side = OpenNOWDesign.clamped(available * 0.28, minimum: 240 * scale, maximum: 340 * scale)
        let fitsTwoColumns = available - side - columnGap >= 420 * scale
        sideColumnWidth = fitsTwoColumns ? side : 0
        mainColumnWidth = fitsTwoColumns ? available - side - columnGap : available
        thumbnailWidth = OpenNOWDesign.clamped(mainColumnWidth * 0.28, minimum: 168, maximum: 280)
        thumbnailsPerPage = max(1, Int(mainColumnWidth / (thumbnailWidth + OpenNOWDesign.Spacing.small(scale: scale))))
    }
}

private struct CatalogGameInfoSection<Content: View>: View {
    let label: String
    let uiScale: CGFloat
    private let content: Content

    init(label: String, uiScale: CGFloat, @ViewBuilder content: () -> Content) {
        self.label = label
        self.uiScale = uiScale
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
            VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
                Text(label)
                    .nvidiaFont(size: 11, weight: .bold)
                    .tracking(1.1)
                    .foregroundStyle(OpenNOWDesign.Text.tertiary)
                Rectangle()
                    .fill(OpenNOWDesign.Stroke.subtle)
                    .frame(height: 1)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CatalogGameInfoSpecRow: View {
    let label: String
    let value: String
    let uiScale: CGFloat

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
                Text(label.uppercased())
                    .nvidiaFont(size: 10, weight: .bold)
                    .tracking(0.6)
                    .foregroundStyle(OpenNOWDesign.Text.muted)
                    .frame(width: 92 * uiScale, alignment: .leading)
                Text(value)
                    .nvidiaFont(size: 12, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Full-bleed screenshot viewer. It sits above the page rather than replacing the hero: the strip
/// that opens it is far enough down the page that a hero swap would be a change off screen.
private struct CatalogGameInfoLightbox: View {
    let viewModel: CatalogViewModel
    let images: [String]
    let index: Int
    let uiScale: CGFloat
    let topInset: CGFloat
    let move: (Int) -> Void
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            CatalogRemoteImage(url: viewModel.optimizedImageURL(images[index], width: 1920), contentMode: .fit, maxPixelSize: 1920)
                .padding(.horizontal, 72 * uiScale)
                .padding(.top, topInset + 24 * uiScale)
                .padding(.bottom, 56 * uiScale)
                .id(images[index])
                .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            if images.count > 1 {
                HStack {
                    arrow(name: "chevron.left", delta: -1, label: "Previous screenshot")
                    Spacer(minLength: 0)
                    arrow(name: "chevron.right", delta: 1, label: "Next screenshot")
                }
                .padding(.horizontal, OpenNOWDesign.Spacing.large(scale: uiScale))
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .nvidiaFont(size: 13, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.Text.primary)
                    .frame(width: 34 * uiScale, height: 34 * uiScale)
                    .background(Color.white.opacity(0.10))
                    .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .padding(.trailing, OpenNOWDesign.Spacing.medium(scale: uiScale))
            .padding(.top, topInset + OpenNOWDesign.Spacing.xSmall(scale: uiScale))
            .accessibilityLabel("Close screenshot")
        }
        .overlay(alignment: .bottom) {
            if images.count > 1 {
                Text("\(index + 1) / \(images.count)")
                    .nvidiaFont(size: 12, weight: .bold)
                    .tracking(0.8)
                    .foregroundStyle(OpenNOWDesign.Text.secondary)
                    .padding(.horizontal, OpenNOWDesign.Spacing.small(scale: uiScale))
                    .frame(height: 26 * uiScale)
                    .background(Color.white.opacity(0.08))
                    .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
                    .padding(.bottom, OpenNOWDesign.Spacing.large(scale: uiScale))
            }
        }
    }

    private func arrow(name: String, delta: Int, label: String) -> some View {
        Button { move(delta) } label: {
            Image(systemName: name)
                .nvidiaFont(size: 16, weight: .bold)
                .foregroundStyle(OpenNOWDesign.Text.primary)
                .frame(width: 44 * uiScale, height: 64 * uiScale)
                .background(Color.white.opacity(0.10))
                .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private enum CatalogGameInfoKey {
    case escape
    case left
    case right
}

/// Holds the page's key handler for the event monitor. The monitor closure has to be Sendable, and
/// the handler it calls is main-actor state, so the box - not the coordinator - is what the closure
/// captures. Local key monitors are delivered on the main thread, which is what makes the hop safe.
private final class CatalogGameInfoKeyHandlerBox: @unchecked Sendable {
    var handle: @MainActor @Sendable (CatalogGameInfoKey) -> Bool = { _ in false }
}

/// Local key monitor for the info page. `handle` returns whether it consumed the press; anything it
/// does not consume is passed on untouched, so the scroll view keeps its own arrow handling.
private struct CatalogGameInfoKeyMonitor: NSViewRepresentable {
    let handle: @MainActor @Sendable (CatalogGameInfoKey) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.box.handle = handle
        context.coordinator.installMonitor()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.box.handle = handle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        let box = CatalogGameInfoKeyHandlerBox()
        private var monitor: Any?

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [box] event in
                guard let key = Self.key(for: event.keyCode) else { return event }
                return MainActor.assumeIsolated { box.handle(key) } ? nil : event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private static func key(for keyCode: UInt16) -> CatalogGameInfoKey? {
            switch keyCode {
            case 53: return .escape
            case 123: return .left
            case 124: return .right
            default: return nil
            }
        }
    }
}
