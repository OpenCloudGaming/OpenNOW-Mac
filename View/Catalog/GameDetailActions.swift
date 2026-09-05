//  The action half of the detail panel: the play button and its menu, the variant status row and
//  the access message behind them.
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

extension GameDetailPanel {
    func detailActions(game: OPNCatalogGameObject) -> some View {
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

    func detailActionsMenuPanel(game: OPNCatalogGameObject) -> some View {
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

    func variantStatusRow(game: OPNCatalogGameObject) -> some View {
        let hasAccess = selectedPlatformHasAccess(game)
        return HStack(spacing: 8) {
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
                    .frame(height: 28 * uiScale)
                    .padding(.horizontal, 10 * uiScale)
                    .background(Color.white.opacity(0.10))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change game store, currently \(option.title)")
            }
            // The state reads as a state, not as a second button: a dot and a word, no box.
            HStack(spacing: 6) {
                Circle()
                    .fill(hasAccess ? OpenNOWDesign.accent : Color.white.opacity(0.42))
                    .frame(width: 6, height: 6)
                Text(hasAccess ? "Ready" : "Not Owned")
                    .nvidiaFont(size: 12, weight: .bold)
                    .foregroundStyle(.white.opacity(hasAccess ? 0.86 : 0.66))
            }
            .frame(height: 28 * uiScale)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 520 * uiScale, alignment: .leading)
    }

    /// Two lines, not one clipped one: the access sentence wraps, and the store hint sits under it
    /// in the quieter weight it deserves. Side by side the sentence was truncated mid-word while a
    /// piece of advice that applies to few titles kept its full width.
    func accessMessage(game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(accessBody(game: game))
                .nvidiaFont(size: 13, weight: .medium)
                .foregroundStyle(.white.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
            if showsStoreConfigurationHint(game: game) {
                Text("Configure stores from Connections.")
                    .nvidiaFont(size: 12, weight: .medium)
                    .foregroundStyle(.white.opacity(0.52))
            }
        }
        .frame(maxWidth: 520 * uiScale, alignment: .leading)
    }

    /// Only when a store actually stands between the user and the game.
    func showsStoreConfigurationHint(game: OPNCatalogGameObject) -> Bool {
        !selectedPlatformHasAccess(game) && !game.isLaunchPatching
    }

    /// Resolves the parts of the current selection that the detail copy depends on. Everything the
    /// copy itself does lives in `GameDetailPresentation`.
    func accessContext(game: OPNCatalogGameObject) -> GameDetailAccessContext {
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

    func accessBody(game: OPNCatalogGameObject) -> String {
        GameDetailPresentation.accessBody(game: game, context: accessContext(game: game))
    }
}
