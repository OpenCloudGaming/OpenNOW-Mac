//
//  GameDetailPanel.swift
//  OpenNOW
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

struct GameDetailPanel: View {
    let viewModel: CatalogViewModel
    /// Width the panel will occupy. Needed up front because the panel height is derived from it.
    var availableWidth: CGFloat = 0
    var viewportHeight: CGFloat = 0
    @State private var activeImageIndex = 0
    @State private var isDescriptionExpanded = false
    @State private var isHovering = false
    @State private var showsActionsMenu = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let imageTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        if let game = viewModel.selectedGame {
            let imageURLs = game.detailImageURLs
            let imageIndex = imageURLs.indices.contains(activeImageIndex) ? activeImageIndex : 0
            let imageURL = imageURLs.indices.contains(imageIndex) ? imageURLs[imageIndex] : game.bestDetailImageURL
            let panelHeight = CatalogVendorLayout.detailPanelHeight(for: availableWidth, viewportHeight: viewportHeight, scale: uiScale)
            GeometryReader { proxy in
                let panelWidth = max(1, proxy.size.width)
                // AppKit hosts (Show All grid) size the row themselves; trust the measured height there.
                let resolvedHeight = proxy.size.height > 1 ? proxy.size.height : panelHeight
                let contentWidth = min(panelWidth * 0.43, 820)
                let imageWidth = max(panelWidth * 0.64, panelWidth - contentWidth * 0.52)
                let hiddenImageLeading = max(0, contentWidth + 54 - (panelWidth - imageWidth))
                ZStack(alignment: .topTrailing) {
                    CatalogRemoteImage(
                        url: viewModel.optimizedImageURL(imageURL, width: 1600),
                        contentMode: .fill,
                        fallbackIconOffsetX: hiddenImageLeading / 2,
                        maxPixelSize: 1600
                    )
                        .frame(width: imageWidth, height: resolvedHeight)
                        .clipped()
                        .contentShape(Rectangle())
                        .id(imageURL)
                        .transition(.opacity.animation(.easeInOut(duration: 0.22)))
                    LinearGradient(
                        stops: [
                            .init(color: OpenNOWDesign.Surface.chrome.opacity(0.99), location: 0.00),
                            .init(color: OpenNOWDesign.Surface.chrome.opacity(0.98), location: 0.34),
                            .init(color: OpenNOWDesign.Surface.chrome.opacity(0.84), location: 0.49),
                            .init(color: OpenNOWDesign.Surface.chrome.opacity(0.22), location: 0.67),
                            .init(color: .clear, location: 1.00)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    LinearGradient(colors: [.black.opacity(0.04), .black.opacity(0.02), .black.opacity(0.22)], startPoint: .top, endPoint: .bottom)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            Text(game.title.isEmpty ? "Selected Game" : game.title)
                                .nvidiaFont(size: 30, weight: .bold)
                                .lineLimit(2)
                                .minimumScaleFactor(0.82)
                                .foregroundStyle(.white.opacity(0.96))
                            Spacer(minLength: 20)
                            Button { viewModel.toggleFavoriteSelectedGame() } label: {
                                Image(systemName: viewModel.isFavorite(game) ? "heart.fill" : "heart")
                                    .nvidiaFont(size: 21, weight: .bold)
                                    .foregroundStyle(.white.opacity(0.94))
                                    .frame(width: 36 * uiScale, height: 32 * uiScale)
                            }
                            .buttonStyle(.plain)
                        }

                        detailMetadataLine(game: game)
                        capabilityChips(game: game)
                        variantStatusRow(game: game)
                        detailActions(game: game)
                            .zIndex(1)
                        accessMessage(game: game)
                        detailMetadataScrollArea(game: game, panelHeight: resolvedHeight)
                            .padding(.top, 4)
                        readMoreButton
                            .padding(.top, 2)
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 21 * uiScale)
                    .padding(.leading, 44 * uiScale)
                    .padding(.trailing, 28 * uiScale)

                    Button { viewModel.selectGame(nil) } label: {
                        Image(systemName: "xmark")
                            .nvidiaFont(size: 22, weight: .regular)
                            .foregroundStyle(.white.opacity(0.90))
                            .frame(width: 40 * uiScale, height: 40 * uiScale)
                    }
                    .buttonStyle(.plain)
                    .padding(18 * uiScale)
                }
                .overlay {
                    if imageURLs.count > 1 {
                        HStack {
                            Spacer()
                                .frame(width: min(contentWidth + 42, max(24, panelWidth - 154)))
                            CatalogDetailImageArrow(name: "lt_arrow") {
                                moveImage(delta: -1, count: imageURLs.count)
                            }
                            Spacer()
                            CatalogDetailImageArrow(name: "rt_arrow") {
                                moveImage(delta: 1, count: imageURLs.count)
                            }
                        }
                        .padding(.horizontal, 18 * uiScale)
                    }
                }
                .overlay(alignment: .bottom) {
                    if imageURLs.count > 1 {
                        HStack(spacing: 12) {
                            ForEach(imageURLs.indices, id: \.self) { index in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.18)) { activeImageIndex = index }
                                } label: {
                                    Circle()
                                        .fill(index == imageIndex ? OpenNOWDesign.accent : Color.white.opacity(0.62))
                                        .frame(width: (index == imageIndex ? 12 : 9) * uiScale, height: (index == imageIndex ? 12 : 9) * uiScale)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, contentWidth + 54)
                        .padding(.bottom, 38 * uiScale)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let logoURL = viewModel.optimizedImageURL(game.bestLogoImageURL, width: 300) {
                        CatalogCachedImageView(url: logoURL, contentMode: .fit, placeholder: EmptyView(), failure: EmptyView())
                        .frame(width: 160, height: 70, alignment: .bottomTrailing)
                        .padding(.trailing, 42)
                        .padding(.bottom, 28)
                        .opacity(0.94)
                    }
                }
                .frame(width: panelWidth, height: resolvedHeight)
                .background(OpenNOWDesign.Surface.chrome)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, minHeight: panelHeight, maxHeight: panelHeight)
            .onHover { isHovering = $0 }
            .onReceive(imageTimer) { _ in
                guard !reduceMotion, !isHovering, game.detailImageURLs.count > 1 else { return }
                moveImage(delta: 1, count: game.detailImageURLs.count)
            }
            .onChange(of: game.catalogIdentity) { _, _ in
                activeImageIndex = 0
                isDescriptionExpanded = false
            }
        }
    }

    private func moveImage(delta: Int, count: Int) {
        guard count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            activeImageIndex = (activeImageIndex + delta + count) % count
        }
    }

    private func detailChips(game: OPNCatalogGameObject) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(game.detailChips, id: \.self) { chip in
                Text(chip)
                    .nvidiaFont(size: 11, weight: .bold)
                    .tracking(0.4)
                    .foregroundStyle(chip == "IN LIBRARY" ? .black.opacity(0.88) : .white.opacity(0.82))
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    .background(chip == "IN LIBRARY" ? OpenNOWDesign.accent : Color.white.opacity(0.09))
                    .overlay { Rectangle().stroke(chip == "IN LIBRARY" ? OpenNOWDesign.accent : Color.white.opacity(0.12), lineWidth: 1) }
            }
        }
    }

    private func detailMetadataLine(game: OPNCatalogGameObject) -> some View {
        HStack(spacing: 9) {
            if !game.ratingLabel.isEmpty {
                Text(game.ratingLabel.uppercased())
                    .nvidiaFont(size: 12, weight: .bold)
            }
            metadataSeparator
            if game.maxOnlinePlayers > 1 { Image(systemName: "person.3.fill") }
            if game.supportsKeyboard { Image(systemName: "keyboard") }
            if game.supportsGamepad { Image(systemName: "gamecontroller.fill") }
            metadataSeparator
            Text(game.genres.prefix(2).joined(separator: ", "))
                .lineLimit(1)
        }
        .nvidiaFont(size: 12, weight: .bold)
        .foregroundStyle(.white.opacity(0.86))
    }

    private var metadataSeparator: some View {
        Circle()
            .fill(Color.white.opacity(0.72))
            .frame(width: 3, height: 3)
    }

    private func capabilityChips(game: OPNCatalogGameObject) -> some View {
        FlowLayout(spacing: 5) {
            ForEach(GameDetailPresentation.capabilityLabels(game: game), id: \.self) { chip in
                HStack(spacing: 5) {
                    if chip == "For Premium Members" {
                        Image(systemName: "checkmark.circle.fill")
                            .nvidiaFont(size: 10, weight: .bold)
                    }
                    Text(chip)
                        .nvidiaFont(size: 12, weight: .bold)
                }
                .foregroundStyle(.white.opacity(0.86))
                .padding(.horizontal, 9)
                .frame(height: 23)
                .background(chip == "For Premium Members" ? Color.white.opacity(0.22) : Color.black.opacity(0.18))
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func detailEyebrow(game: OPNCatalogGameObject) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(GameDetailPresentation.detailMetadata(game: game), id: \.self) { item in
                Text(item.uppercased())
                    .nvidiaFont(size: 11, weight: .bold)
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
    }

    private func detailActions(game: OPNCatalogGameObject) -> some View {
        HStack(spacing: 10) {
            Button { primaryAction(game: game) } label: {
                Text(primaryActionTitle(game: game))
            }
            .buttonStyle(VendorGetInButtonStyle(size: .large, uiScale: uiScale, minimumWidth: primaryActionTitle(game: game) == "PLAY" ? 72 : 132))
            .disabled((game.isLaunchPatching || selectedVariant?.isPatching == true) && viewModel.isQueuedForPatching(game))
            .fixedSize()

            Button { showsActionsMenu.toggle() } label: {
                Image(systemName: "ellipsis")
                    .nvidiaFont(size: 15, weight: .bold)
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 40 * uiScale, height: 40 * uiScale)
                    .background(Color.white.opacity(0.08))
                    .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .overlay {
                if showsActionsMenu {
                    Color.black.opacity(0.001)
                        .frame(width: 6000, height: 6000)
                        .contentShape(Rectangle())
                        .onTapGesture { showsActionsMenu = false }
                }
            }
            .overlay(alignment: .topLeading) {
                if showsActionsMenu {
                    detailActionsMenuPanel(game: game)
                        .offset(y: 44 * uiScale)
                }
            }
            .onExitCommand { showsActionsMenu = false }
            .onChange(of: game.catalogIdentity) { _, _ in showsActionsMenu = false }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func detailActionsMenuPanel(game: OPNCatalogGameObject) -> some View {
        var items: [OpenNOWDropdownItem] = []
        if game.variants.count > 1 {
            items.append(OpenNOWDropdownItem(id: "changeStore", title: "Change game store") {
                showsActionsMenu = false
                viewModel.changeSelectedGameStore()
            })
        }
        items.append(OpenNOWDropdownItem(id: "share", title: "Share") {
            showsActionsMenu = false
            viewModel.shareSelectedGame()
        })
        items.append(OpenNOWDropdownItem(id: "addShortcut", title: "Add shortcut") {
            showsActionsMenu = false
            viewModel.addShortcutForSelectedGame()
        })
        if selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true || game.isInLibrary {
            items.append(OpenNOWDropdownItem(id: "unmarkOwned", title: "Unmark as owned") {
                showsActionsMenu = false
                viewModel.removeSelectedVariantOwned()
            })
        } else if selectedVariant != nil {
            items.append(OpenNOWDropdownItem(id: "markOwned", title: "Mark as owned") {
                showsActionsMenu = false
                viewModel.markSelectedVariantOwned()
            })
        }
        items.append(OpenNOWDropdownItem(id: "visitStore", title: "Visit game store") {
            showsActionsMenu = false
            viewModel.openStoreForSelectedVariant()
        })
        return OpenNOWDropdownPanel(items: items)
    }

    private func variantStatusRow(game: OPNCatalogGameObject) -> some View {
        HStack(spacing: 0) {
            if let option = selectedPlatformOption {
                Button { viewModel.changeSelectedGameStore() } label: {
                    HStack(spacing: 6) {
                        if !option.iconURL.isEmpty {
                            CatalogStoreIconImage(url: URL(string: option.iconURL), size: 16)
                                .frame(width: 16 * uiScale, height: 16 * uiScale)
                        }
                        Text(option.title)
                            .nvidiaFont(size: 12, weight: .bold)
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(height: 30 * uiScale)
                    .padding(.horizontal, 0)
                }
                .buttonStyle(.plain)
            }
            Text(selectedPlatformHasAccess(game) ? "Ready" : "Not Owned")
                .nvidiaFont(size: 12, weight: .bold)
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 10 * uiScale)
                .frame(height: 30 * uiScale)
                .background(Color.black.opacity(0.14))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 520 * uiScale, alignment: .leading)
    }

    private func accessMessage(game: OPNCatalogGameObject) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(accessBody(game: game))
                .nvidiaFont(size: 13, weight: .medium)
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)
            Text("Configure stores from Connections.")
                .nvidiaFont(size: 13, weight: .bold)
                .foregroundStyle(.white.opacity(0.68))
            Spacer(minLength: 0)
        }
    }

    /// Resolves the parts of the current selection that the detail copy depends on. Everything the
    /// copy itself does lives in `GameDetailPresentation`.
    private func accessContext(game: OPNCatalogGameObject) -> GameDetailAccessContext {
        let option = selectedPlatformOption
        let variant = selectedVariant
        return GameDetailAccessContext(
            isQueuedForPatching: viewModel.isQueuedForPatching(game),
            isSelectedVariantPatching: variant?.isPatching == true,
            isSelectedVariantOwned: selectedVariantIsOwned(game),
            hasSelectedVariant: variant != nil,
            selectedPlatformHasAccess: selectedPlatformHasAccess(game),
            subscriptionOptionTitle: option?.hasSubscriptionEntitlement == true ? option?.title : nil,
            ownershipStoreName: (variant?.appStore.isEmpty == false) ? viewModel.displayName(forStore: variant?.appStore ?? "") : nil
        )
    }

    private func accessBody(game: OPNCatalogGameObject) -> String {
        GameDetailPresentation.accessBody(game: game, context: accessContext(game: game))
    }

    private func detailMetadataScrollArea(game: OPNCatalogGameObject, panelHeight: CGFloat) -> some View {
        // Text area grows with the panel so tall (ultrawide) panels do not leave a dead gap.
        let collapsedHeight = OpenNOWDesign.clamped(panelHeight * 0.256, minimum: 128, maximum: 210)
        let expandedHeight = OpenNOWDesign.clamped(panelHeight * 0.496, minimum: 248, maximum: 420)
        return ScrollView(.vertical, showsIndicators: isDescriptionExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                shortDescription(game: game)
                divider
                nvidiaTechRows(game: game)
                ratingBlock(game: game)
                detailRows(game: game)
                fullDescription(game: game)
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.trailing, isDescriptionExpanded ? 8 : 0)
        }
        .scrollDisabled(!isDescriptionExpanded)
        .frame(
            maxWidth: 660,
            minHeight: collapsedHeight,
            maxHeight: isDescriptionExpanded ? expandedHeight : collapsedHeight,
            alignment: .topLeading
        )
        .clipped()
    }

    private func shortDescription(game: OPNCatalogGameObject) -> some View {
        Text(GameDetailPresentation.shortDescription(game: game))
            .nvidiaFont(size: 15, weight: .medium)
            .foregroundStyle(.white.opacity(0.90))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 660, alignment: .leading)
    }

    private func fullDescription(game: OPNCatalogGameObject) -> some View {
        let description = GameDetailPresentation.longDescription(game: game)
        return VStack(alignment: .leading, spacing: 8) {
            if !description.isEmpty {
                Text("FULL DESCRIPTION")
                    .nvidiaFont(size: 11, weight: .bold)
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.56))
                Text(description)
                    .nvidiaFont(size: 14, weight: .medium)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 660, alignment: .leading)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.24))
            .frame(height: 1)
    }

    private func nvidiaTechRows(game: OPNCatalogGameObject) -> some View {
        let technologies = GameDetailPresentation.supportedTechnologyLabels(game: game)
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(technologies.prefix(2), id: \.self) { technology in
                CatalogFeatureAvailabilityRow(title: technology, message: GameDetailPresentation.featureMessage(technology), locked: GameDetailPresentation.featureIsLocked(technology))
            }
        }
        .padding(.vertical, technologies.isEmpty ? 0 : 2)
        .frame(maxWidth: 660, alignment: .leading)
    }

    private func ratingBlock(game: OPNCatalogGameObject) -> some View {
        HStack(alignment: .top, spacing: 18) {
            if !game.ratingLabel.isEmpty {
                CatalogRatingBadge(game: game, shortRating: GameDetailPresentation.esrbShortRating(game.ratingLabel))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(game.ratingLabel.isEmpty ? "CLOUD GAMING" : game.ratingLabel.uppercased())
                    .nvidiaFont(size: 13, weight: .bold)
                    .foregroundStyle(.white.opacity(0.92))
                ForEach(GameDetailPresentation.ratingDescriptors(game: game), id: \.self) { descriptor in
                    Text(descriptor)
                        .nvidiaFont(size: 12, weight: .medium)
                        .foregroundStyle(.white.opacity(0.70))
                        .frame(maxWidth: 215, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.24)).frame(height: 1).offset(y: 5) }
                }
            }
        }
    }

    private var readMoreButton: some View {
        Button {
            isDescriptionExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(isDescriptionExpanded ? "READ LESS" : "READ MORE")
                Image(systemName: isDescriptionExpanded ? "chevron.up" : "chevron.down")
            }
            .nvidiaFont(size: 13, weight: .bold)
            .foregroundStyle(.white.opacity(0.95))
        }
        .buttonStyle(.plain)
    }

    private var selectedVariant: OPNCatalogGameVariantObject? {
        viewModel.selectedVariant(in: viewModel.selectedGame)
    }

    private var selectedPlatformOption: CatalogPlatformOption? {
        viewModel.selectedPlatformOption(in: viewModel.selectedGame)
    }

    private func primaryActionTitle(game: OPNCatalogGameObject) -> String {
        GameDetailPresentation.primaryActionTitle(game: game, context: accessContext(game: game))
    }

    private func primaryAction(game: OPNCatalogGameObject) {
        if game.isLaunchPatching || selectedVariant?.isPatching == true {
            viewModel.queuePatchingLaunch(game: game, variantIndex: viewModel.selectedVariantIndex)
            return
        }
        if selectedPlatformHasAccess(game) || selectedVariant == nil {
            viewModel.launchSelectedGame()
        } else {
            viewModel.handleUnownedSelectedVariantPrimaryAction()
        }
    }

    private func selectedVariantIsOwned(_ game: OPNCatalogGameObject) -> Bool {
        guard let selectedVariant else { return false }
        return CatalogViewModel.variantIsOwned(selectedVariant, in: game)
    }

    private func selectedPlatformHasAccess(_ game: OPNCatalogGameObject) -> Bool {
        viewModel.selectedPlatformHasAccess(in: game)
    }

    private func variantChips(game: OPNCatalogGameObject) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(viewModel.platformOptions(for: game)) { option in
                Button { selectVariant(at: option.variantIndex, in: game) } label: {
                    HStack(spacing: 7) {
                        if option.hasAccess || option.isSelected {
                            Image(systemName: option.hasAccess ? "checkmark.circle.fill" : "circle.fill")
                                .nvidiaFont(size: 11, weight: .bold)
                        }
                        Text(option.title)
                            .nvidiaFont(size: 11, weight: .bold)
                    }
                    .foregroundStyle(option.isSelected ? .black.opacity(0.88) : .white.opacity(0.82))
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(option.isSelected ? OpenNOWDesign.accent : Color.white.opacity(0.09))
                    .overlay { Rectangle().stroke(option.isSelected ? OpenNOWDesign.accent : Color.white.opacity(0.14), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityValue(option.isSelected ? "Selected" : "")
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func selectVariant(at index: Int, in game: OPNCatalogGameObject) {
        viewModel.focusGameStoreVariant(at: index)
        guard index >= 0, index < game.variants.count else { return }
        let variant = game.variants[index]
        if variant.inLibrary || variant.librarySelected { viewModel.selectOwnedVariant(variant) }
    }

    private func detailRows(game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CatalogDetailRow(label: "Publisher", value: game.publisherName)
            CatalogDetailRow(label: "Developer", value: game.developerName)
            CatalogDetailRow(label: "Input", value: GameDetailPresentation.inputLine(game: game, selectedVariant: selectedVariant))
            CatalogDetailRow(label: "Players", value: GameDetailPresentation.playerLine(game: game))
            CatalogDetailRow(label: "Release Date", value: GameDetailPresentation.releaseDateLine(game: game))
            CatalogDetailRow(label: "Stores", value: game.storeLine)
            CatalogDetailRow(label: "Genres", value: game.genreLine)
        }
    }

}

struct CatalogDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(label.uppercased())
                    .nvidiaFont(size: 10, weight: .bold)
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 112, alignment: .leading)
                Text(value)
                    .nvidiaFont(size: 12, weight: .bold)
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct CatalogFeatureAvailabilityRow: View {
    let title: String
    let message: String
    let locked: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: locked ? "lock.fill" : "checkmark.circle.fill")
                .nvidiaFont(size: 13, weight: .bold)
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 18)
            Text(title)
                .nvidiaFont(size: 14, weight: .bold)
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 84, alignment: .leading)
                .lineLimit(1)
            Text(message)
                .nvidiaFont(size: 14, weight: .medium)
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
