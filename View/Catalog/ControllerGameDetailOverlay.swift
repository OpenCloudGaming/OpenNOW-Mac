//  Controller mode's game page: the hero, the play/more action row, the paged About and Details
//  panels, and the secondary-action menu behind More.
//

import AppKit
import SwiftUI

/// Mirrors the desktop `CatalogGameInfoOverlay` full-info page — banner hero with title/favorite/
/// metadata, then ABOUT THIS GAME and DETAILS/CONTENT RATING — rather than the compact
/// `GameDetailPanel` card, since controller mode has no separate "read more" destination to send
/// input focus to. The hero and action row stay pinned; the body below is two LB/RB-paged panels
/// (not a side-by-side column split) so the layout never depends on window width to decide
/// whether something fits, and a gamepad has an explicit way to reach content past the fold.
struct ControllerGameDetailOverlay: View {
    let viewModel: CatalogViewModel
    let game: OPNCatalogGameObject
    let selectedActionIndex: Int
    let actions: [ControllerDetailAction]
    let page: ControllerGameDetailPage
    let pages: [ControllerGameDetailPage]
    let focusRow: ControllerGameDetailFocusRow
    let screenshots: [String]
    let selectedScreenshotIndex: Int
    let isLightboxVisible: Bool
    let topInset: CGFloat
    let moreActions: [ControllerDetailAction]
    let selectedMoreActionIndex: Int
    let isMoreMenuVisible: Bool
    let glyphs: ControllerInputGlyphSet
    let layout: ControllerLayoutMetrics
    let perform: (ControllerDetailAction) -> Void
    let performMoreAction: (ControllerDetailAction) -> Void
    let selectPage: (ControllerGameDetailPage) -> Void
    let selectScreenshot: (Int) -> Void
    let openLightbox: () -> Void
    let closeLightbox: () -> Void
    let closeMoreMenu: () -> Void
    let close: () -> Void

    var selectedVariant: OPNCatalogGameVariantObject? { viewModel.selectedVariant(in: game) }

    @Environment(\.opnUIScale) private var uiScale
    @Environment(\.displayScale) private var displayScale

    /// Sized from `layout.size` — the shell's own measurement of the window — rather than from a
    /// `GeometryReader` here or from `maxWidth: .infinity`. Both of those adopt whatever width this
    /// view is offered, and the offer arrives too wide on the pass that inserts the overlay, which
    /// is why the page rendered clipped until a window resize forced a fresh pass. An explicit
    /// width overrides the bad proposal instead of reproducing it.
    var body: some View {
        let metrics = ControllerGameDetailMetrics(viewport: layout.size, scale: uiScale)
        ZStack(alignment: .topLeading) {
            OpenNOWDesign.Surface.app
            VStack(alignment: .leading, spacing: 0) {
                hero(metrics: metrics, width: layout.size.width)
                actionRow
                    .frame(width: contentWidth(metrics), alignment: .leading)
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.top, 18 * uiScale)
                    .padding(.bottom, 14 * uiScale)
                pageTabs
                    .frame(width: contentWidth(metrics), alignment: .leading)
                    .padding(.horizontal, metrics.horizontalPadding)
                ScrollView(.vertical) {
                    panel(for: page)
                        .frame(width: contentWidth(metrics), alignment: .leading)
                        .padding(.horizontal, metrics.horizontalPadding)
                        .padding(.top, 20 * uiScale)
                        .padding(.bottom, 44 * uiScale)
                }
                .id(page)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.18), value: page)
                .scrollIndicators(.never)
            }
            .frame(width: layout.size.width, alignment: .topLeading)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .topTrailing) { closeHeader }
        .overlay {
            if isMoreMenuVisible { moreMenu(metrics: metrics) }
        }
        .overlay {
            if isLightboxVisible { lightbox }
        }
    }

    @ViewBuilder
    private func panel(for page: ControllerGameDetailPage) -> some View {
        switch page {
        case .about: aboutPanel
        case .screenshots: screenshotsPanel
        case .details: detailsPanel
        }
    }

    private func contentWidth(_ metrics: ControllerGameDetailMetrics) -> CGFloat {
        max(layout.size.width - metrics.horizontalPadding * 2, 1)
    }

    private var pageTabs: some View {
        HStack(spacing: 20 * uiScale) {
            ForEach(pages, id: \.self) { tab in
                Button { selectPage(tab) } label: { pageTabLabel(tab) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(tab.title.capitalized)")
            }
            Spacer(minLength: 0)
            HStack(spacing: 6 * uiScale) {
                pageStepButton(glyph: glyphs.pageLeft, offset: -1, label: "Previous panel")
                pageStepButton(glyph: glyphs.pageRight, offset: 1, label: "Next panel")
            }
        }
    }

    private func pageStepButton(glyph: ControllerInputGlyph, offset: Int, label: String) -> some View {
        Button { selectPage(page.stepped(by: offset, in: pages)) } label: {
            ControllerGlyphPill(glyph: glyph, compact: true)
        }
        .buttonStyle(.plain)
        .disabled(page.stepped(by: offset, in: pages) == page)
        .accessibilityLabel(label)
    }

    private func pageTabLabel(_ tab: ControllerGameDetailPage) -> some View {
        let isActive = tab == page
        return Text(tab.title)
            .catalogFont(size: 11, weight: .bold)
            .tracking(1.0)
            .foregroundStyle(isActive ? OpenNOWDesign.Text.primary : OpenNOWDesign.Text.tertiary)
            .padding(.bottom, 8 * uiScale)
            .overlay(alignment: .bottom) {
                if isActive { Rectangle().fill(OpenNOWDesign.accent).frame(height: 2) }
            }
    }

    // MARK: - Hero

    private func hero(metrics: ControllerGameDetailMetrics, width: CGFloat) -> some View {
        let artworkPixels = CatalogArtworkResolution.pixelWidth(renderedWidth: width, displayScale: displayScale)
        return ZStack(alignment: .bottomLeading) {
            CatalogHeroArtwork(
                url: viewModel.optimizedImageURL(game.detailImageURL(forAspectRatio: width / max(metrics.heroHeight, 1)), width: artworkPixels),
                maxPixelSize: CGFloat(artworkPixels)
            )
            .frame(width: width, height: metrics.heroHeight)
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
            heroCaption(metrics: metrics)
                .frame(width: max(width - metrics.horizontalPadding * 2, 1), alignment: .leading)
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.bottom, 22 * uiScale)
        }
        .frame(width: width, height: metrics.heroHeight, alignment: .bottomLeading)
        .clipped()
    }

    private func heroCaption(metrics: ControllerGameDetailMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            CatalogHeroWordmark(
                logoURL: viewModel.optimizedImageURL(game.bestLogoImageURL, width: CatalogLogoArtwork.requestWidth),
                title: game.title.isEmpty ? "Selected Game" : game.title,
                titlePointSize: 40,
                titleLineLimit: 2,
                boxHeight: metrics.wordmarkHeight
            )
            metadataLine
            FlowLayout(spacing: 8 * uiScale) {
                ForEach(GameDetailPresentation.capabilityLabels(game: game), id: \.self) { label in
                    Text(label)
                        .catalogFont(size: 12, weight: .bold)
                        .foregroundStyle(OpenNOWDesign.Text.primary)
                        .padding(.horizontal, 8 * uiScale)
                        .frame(height: 24 * uiScale)
                        .background(Color.white.opacity(0.12))
                        .overlay { Rectangle().strokeBorder(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadataLine: some View {
        HStack(spacing: 8 * uiScale) {
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
        .catalogFont(size: 12, weight: .bold)
        .tracking(0.6)
        .foregroundStyle(OpenNOWDesign.Text.secondary)
    }

    private var closeHeader: some View {
        HStack(spacing: 10 * uiScale) {
            ControllerGlyphPill(glyph: glyphs.back)
            Text("BACK")
                .catalogFont(size: 11, weight: .bold)
                .foregroundStyle(.white.opacity(0.72))
            Button(action: close) {
                Image(systemName: "xmark")
                    .catalogFont(size: 13, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.Text.primary)
                    .frame(width: 34 * uiScale, height: 34 * uiScale)
                    .background(Color.black.opacity(0.55))
                    .overlay { Rectangle().strokeBorder(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18 * uiScale)
        .padding(.top, topInset + 14 * uiScale)
    }

    // MARK: - Actions

    /// Two stops, sized to say which one matters. Play keeps the accent whether or not it holds
    /// focus - it is the page's reason to exist, not merely the currently highlighted thing - so
    /// focus reads from the ring rather than from a colour swap.
    private var actionRow: some View {
        HStack(spacing: 12 * uiScale) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                actionButton(action: action, isFocused: index == selectedActionIndex)
            }
            Spacer(minLength: 0)
        }
    }

    private func actionButton(action: ControllerDetailAction, isFocused: Bool) -> some View {
        let isPrimary = action == .primary
        let isFilled = isPrimary || isFocused
        return Button { perform(action) } label: {
            HStack(spacing: 10 * uiScale) {
                Image(systemName: action.icon)
                    .catalogFont(size: 14, weight: .bold)
                Text(action.title(game: game, selectedVariant: selectedVariant, viewModel: viewModel).uppercased())
                    .catalogFont(size: 13, weight: .bold)
                    .tracking(0.9)
            }
            .foregroundStyle(isFilled ? .black.opacity(0.88) : .white.opacity(0.88))
            .padding(.horizontal, 22 * uiScale)
            // Matched box, not matched emphasis: Play earns its prominence from the accent fill, so
            // sizing it larger as well made the pair read as two unrelated controls.
            .frame(minWidth: 150 * uiScale)
            .frame(height: 44 * uiScale)
            .background(isFilled ? OpenNOWDesign.accent : Color.white.opacity(0.10))
            .overlay { Rectangle().strokeBorder(isFilled ? OpenNOWDesign.accent : OpenNOWDesign.Stroke.regular, lineWidth: 1) }
            .openNowFocusRing(isFocused, onAccentFill: true)
        }
        .buttonStyle(.plain)
    }

    /// The secondary actions, one Y press away. Vertical and centred rather than a wide row: this
    /// is a list to read down, and it inherits the picker overlay's shape so it is the same object
    /// the rest of controller mode already uses for "choose one of these".
    private func moreMenu(metrics: ControllerGameDetailMetrics) -> some View {
        ZStack {
            OpenNOWDesign.Surface.scrim
                .ignoresSafeArea()
                .onTapGesture { closeMoreMenu() }
            VStack(alignment: .leading, spacing: 0) {
                ControllerOverlayHeader(
                    title: game.title.isEmpty ? "More Actions" : game.title,
                    subtitle: "More actions",
                    glyphs: glyphs,
                    close: closeMoreMenu
                )
                .padding(.horizontal, 22 * uiScale)
                .padding(.top, 18 * uiScale)
                .padding(.bottom, 12 * uiScale)

                VStack(spacing: 8 * uiScale) {
                    ForEach(Array(moreActions.enumerated()), id: \.offset) { index, action in
                        let isFocused = index == selectedMoreActionIndex
                        Button { performMoreAction(action) } label: {
                            HStack(spacing: 13 * uiScale) {
                                Image(systemName: action.icon)
                                    .catalogFont(size: 14, weight: .bold)
                                    .foregroundStyle(isFocused ? .black.opacity(0.86) : OpenNOWDesign.accent)
                                    .frame(width: 26 * uiScale)
                                Text(action.title(game: game, selectedVariant: selectedVariant, viewModel: viewModel))
                                    .catalogFont(size: 15, weight: .bold)
                                    .foregroundStyle(isFocused ? .black.opacity(0.88) : .white.opacity(0.88))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14 * uiScale)
                            .frame(height: 48 * uiScale)
                            .background(isFocused ? OpenNOWDesign.accent : Color.white.opacity(0.055))
                            .overlay { Rectangle().strokeBorder(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
                            .openNowFocusRing(isFocused, onAccentFill: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22 * uiScale)
                .padding(.bottom, 22 * uiScale)
            }
            .frame(width: min(560 * uiScale, max(layout.size.width - metrics.horizontalPadding * 2, 1)), alignment: .topLeading)
            .background(OpenNOWDesign.Surface.deep.opacity(0.98))
            .overlay(alignment: .top) { Rectangle().fill(OpenNOWDesign.accent).frame(height: 2) }
            .overlay { Rectangle().strokeBorder(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
        }
    }

    // MARK: - Body panels

    private var aboutPanel: some View {
        let longDescription = GameDetailPresentation.longDescription(game: game)
        return ControllerInfoSection(label: "ABOUT THIS GAME", uiScale: uiScale) {
            VStack(alignment: .leading, spacing: 16 * uiScale) {
                Text(GameDetailPresentation.shortDescription(game: game))
                    .catalogFont(size: 16, weight: .medium)
                    .foregroundStyle(OpenNOWDesign.Text.primary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                if !longDescription.isEmpty {
                    Text(longDescription)
                        .catalogFont(size: 14, weight: .medium)
                        .foregroundStyle(OpenNOWDesign.Text.secondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A strip rather than a grid: the pad walks it left to right, and the selected shot is the one
    /// the lightbox opens, so browsing and enlarging share a single index.
    private var screenshotsPanel: some View {
        let thumbnailWidth = OpenNOWDesign.clamped(layout.size.width * 0.22, minimum: 180, maximum: 300)
        return ControllerInfoSection(label: "SCREENSHOTS", uiScale: uiScale) {
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12 * uiScale) {
                        ForEach(Array(screenshots.enumerated()), id: \.offset) { index, url in
                            screenshotThumbnail(url: url, index: index, width: thumbnailWidth)
                                .id(index)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: selectedScreenshotIndex) { _, index in
                    withAnimation(.easeOut(duration: 0.18)) { scrollProxy.scrollTo(index, anchor: .center) }
                }
            }
        }
    }

    private func screenshotThumbnail(url: String, index: Int, width: CGFloat) -> some View {
        let isSelected = index == selectedScreenshotIndex && focusRow == .content
        return Button {
            selectScreenshot(index)
            openLightbox()
        } label: {
            CatalogRemoteImage(url: viewModel.optimizedImageURL(url, width: 640), contentMode: .fill, maxPixelSize: 640)
                .frame(width: width, height: width * 9 / 16)
                .clipped()
                .overlay { Rectangle().strokeBorder(isSelected ? OpenNOWDesign.accent : OpenNOWDesign.Stroke.regular, lineWidth: 1) }
                .openNowFocusRing(isSelected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open screenshot \(index + 1)")
    }

    private var lightbox: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()
                .onTapGesture { closeLightbox() }
            if screenshots.indices.contains(selectedScreenshotIndex) {
                CatalogRemoteImage(
                    url: viewModel.optimizedImageURL(screenshots[selectedScreenshotIndex], width: 1920),
                    contentMode: .fit,
                    maxPixelSize: 1920
                )
                .padding(.horizontal, 64 * uiScale)
                .padding(.top, topInset + 24 * uiScale)
                .padding(.bottom, 56 * uiScale)
                .id(screenshots[selectedScreenshotIndex])
            }
        }
        .overlay(alignment: .bottom) {
            Text("\(selectedScreenshotIndex + 1) / \(screenshots.count)")
                .catalogFont(size: 12, weight: .bold)
                .tracking(0.8)
                .foregroundStyle(OpenNOWDesign.Text.secondary)
                .padding(.horizontal, 12 * uiScale)
                .frame(height: 26 * uiScale)
                .background(Color.white.opacity(0.08))
                .overlay { Rectangle().strokeBorder(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
                .padding(.bottom, 24 * uiScale)
        }
    }

    private var detailsPanel: some View {
        let descriptors = GameDetailPresentation.ratingDescriptors(game: game)
        return VStack(alignment: .leading, spacing: 32 * uiScale) {
            ControllerInfoSection(label: "DETAILS", uiScale: uiScale) {
                VStack(alignment: .leading, spacing: 12 * uiScale) {
                    ControllerInfoSpecRow(label: "Publisher", value: game.publisherName, uiScale: uiScale)
                    ControllerInfoSpecRow(label: "Developer", value: game.developerName, uiScale: uiScale)
                    ControllerInfoSpecRow(label: "Release Date", value: GameDetailPresentation.releaseDateLine(game: game), uiScale: uiScale)
                    ControllerInfoSpecRow(label: "Input", value: GameDetailPresentation.inputLine(game: game, selectedVariant: selectedVariant), uiScale: uiScale)
                    ControllerInfoSpecRow(label: "Players", value: GameDetailPresentation.playerLine(game: game), uiScale: uiScale)
                    ControllerInfoSpecRow(label: "Stores", value: game.storeLine, uiScale: uiScale)
                    ControllerInfoSpecRow(label: "Genres", value: game.genreLine, uiScale: uiScale)
                }
            }
            ControllerInfoSection(label: "CONTENT RATING", uiScale: uiScale) {
                HStack(alignment: .top, spacing: 16 * uiScale) {
                    if !game.ratingLabel.isEmpty {
                        CatalogRatingBadge(game: game, shortRating: GameDetailPresentation.esrbShortRating(game.ratingLabel))
                    }
                    VStack(alignment: .leading, spacing: 8 * uiScale) {
                        Text(game.ratingLabel.isEmpty ? "CLOUD GAMING" : game.ratingLabel.uppercased())
                            .catalogFont(size: 13, weight: .bold)
                            .foregroundStyle(OpenNOWDesign.Text.primary)
                        ForEach(descriptors, id: \.self) { descriptor in
                            Text(descriptor)
                                .catalogFont(size: 12, weight: .medium)
                                .foregroundStyle(OpenNOWDesign.Text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// Viewport-derived geometry. Both terms follow the window and are clamped, so nothing here can
/// hand the layout a width the window does not actually have.
private struct ControllerGameDetailMetrics {
    let horizontalPadding: CGFloat
    let heroHeight: CGFloat
    let wordmarkHeight: CGFloat

    init(viewport: CGSize, scale: CGFloat) {
        let padding = OpenNOWDesign.clamped(viewport.width * 0.06, minimum: 28, maximum: 96) * scale
        horizontalPadding = min(padding, viewport.width * 0.14)
        heroHeight = OpenNOWDesign.clamped(viewport.height * 0.42, minimum: 220, maximum: 520)
        // Held under half the band: the caption still has to seat its metadata and capability rows.
        wordmarkHeight = min(OpenNOWDesign.clamped(viewport.height * 0.15, minimum: 76, maximum: 150) * scale, heroHeight * 0.44)
    }
}

private struct ControllerInfoSection<Content: View>: View {
    let label: String
    let uiScale: CGFloat
    private let content: Content

    init(label: String, uiScale: CGFloat, @ViewBuilder content: () -> Content) {
        self.label = label
        self.uiScale = uiScale
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                Text(label)
                    .catalogFont(size: 11, weight: .bold)
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

private struct ControllerInfoSpecRow: View {
    let label: String
    let value: String
    let uiScale: CGFloat

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 12 * uiScale) {
                Text(label.uppercased())
                    .catalogFont(size: 10, weight: .bold)
                    .tracking(0.6)
                    .foregroundStyle(OpenNOWDesign.Text.muted)
                    .frame(width: 92 * uiScale, alignment: .leading)
                Text(value)
                    .catalogFont(size: 12, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
