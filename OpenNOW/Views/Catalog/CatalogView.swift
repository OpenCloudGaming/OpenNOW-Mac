//  CatalogView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import Backend
import Combine
import SwiftUI

struct CatalogView: View {
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    @StateObject private var viewModel: CatalogViewModel

    init(
        account: LoginAccount,
        session: LoginSession,
        accounts: [LoginAccount],
        onSwitch: @escaping (LoginAccount) -> Void,
        onSignOut: @escaping () -> Void,
        onForget: @escaping (LoginAccount) -> Void
    ) {
        self.accounts = accounts
        self.onSwitch = onSwitch
        self.onSignOut = onSignOut
        self.onForget = onForget
        _viewModel = StateObject(wrappedValue: CatalogViewModel(account: account, session: session))
    }

    var body: some View {
        HStack(spacing: 0) {
            CatalogSidebar(viewModel: viewModel)
            VStack(spacing: 0) {
                CatalogTopBar(viewModel: viewModel, accounts: accounts, onSwitch: onSwitch, onSignOut: onSignOut, onForget: onForget)
                CatalogContentView(viewModel: viewModel)
            }
        }
        .background(Color.black)
        .overlay(alignment: .trailing) {
            if viewModel.selectedGame != nil {
                GameDetailPanel(viewModel: viewModel)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .task { viewModel.loadIfNeeded() }
        .preferredColorScheme(.dark)
    }
}

private struct CatalogSidebar: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.openNowGreen)
                    .frame(width: 24, height: 18)
                Text("GFN")
                    .font(.system(size: 18, weight: .black))
                    .tracking(1.5)
            }
            .padding(.top, 28)

            sidebarButton("Home", systemImage: "house.fill", active: true)
            sidebarButton("Games", systemImage: "square.grid.2x2.fill", active: false)
            sidebarButton("Library", systemImage: "books.vertical.fill", active: false)
            sidebarButton("Settings", systemImage: "gearshape.fill", active: false)
            Spacer()
            Button { viewModel.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.68))
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 22)
        .frame(width: 210, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.055, green: 0.055, blue: 0.055))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1) }
    }

    private func sidebarButton(_ title: String, systemImage: String, active: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 18)
            Text(title)
            Spacer()
        }
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(active ? .white : .white.opacity(0.55))
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(active ? Color.white.opacity(0.10) : Color.clear)
        .overlay(alignment: .leading) {
            if active { Rectangle().fill(Color.openNowGreen).frame(width: 3) }
        }
    }
}

private struct CatalogTopBar: View {
    @ObservedObject var viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.42))
                TextField("Search games", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .onSubmit { viewModel.browseCatalog() }
                if !viewModel.searchQuery.isEmpty {
                    Button { viewModel.searchQuery = ""; viewModel.browseCatalog() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.42))
                }
            }
            .padding(.horizontal, 14)
            .frame(width: 360, height: 38)
            .background(Color.white.opacity(0.08))
            .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }

            Picker("Sort", selection: $viewModel.selectedSortId) {
                Text("Last Played").tag("last_played")
                Text("Title").tag("title")
                Text("Newest").tag("date_added")
            }
            .labelsHidden()
            .frame(width: 150)
            .onChange(of: viewModel.selectedSortId) { _, _ in viewModel.browseCatalog() }

            Spacer()

            Menu {
                ForEach(accounts) { account in
                    Button(account.displayName) { onSwitch(account) }
                }
                Divider()
                Button("Sign Out", action: onSignOut)
                ForEach(accounts) { account in
                    Button("Forget \(account.displayName)", role: .destructive) { onForget(account) }
                }
            } label: {
                HStack(spacing: 10) {
                    AccountAvatar(name: viewModel.account.displayName, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(viewModel.account.displayName)
                            .font(.system(size: 13, weight: .bold))
                        Text(viewModel.account.membershipTier)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.openNowGreen)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .menuStyle(.button)
        }
        .padding(.horizontal, 24)
        .frame(height: 68)
        .background(Color(red: 0.075, green: 0.075, blue: 0.075))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }
}

private struct CatalogContentView: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let hero = viewModel.featuredGames.first ?? viewModel.catalogGames.first {
                    CatalogHeroView(viewModel: viewModel, game: hero)
                }

                if !viewModel.errorMessage.isEmpty {
                    CatalogMessageView(message: viewModel.errorMessage, systemImage: "exclamationmark.triangle.fill")
                }
                if viewModel.isLoading || viewModel.isLoadingPanels {
                    CatalogLoadingStrip()
                }

                ForEach(Array(viewModel.catalogSections.enumerated()), id: \.offset) { _, section in
                    CatalogRailView(viewModel: viewModel, title: section.title, games: section.games)
                }
            }
            .padding(.leading, 30)
            .padding(.trailing, viewModel.selectedGame == nil ? 30 : 420)
            .padding(.vertical, 28)
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.02, blue: 0.02), Color(red: 0.09, green: 0.09, blue: 0.09)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct CatalogHeroView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let game: OPNCatalogGameObject

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestHeroImageURL, width: 1400), contentMode: .fill)
                .frame(maxWidth: .infinity, minHeight: 340, maxHeight: 340)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 14) {
                Text("GEFORCE NOW")
                    .font(.system(size: 12, weight: .black))
                    .tracking(2.2)
                    .foregroundStyle(Color.openNowGreen)
                Text(game.title.isEmpty ? "Featured Game" : game.title)
                    .font(.system(size: 44, weight: .black))
                    .lineLimit(2)
                Text(game.gameDescription.isEmpty ? game.genreLine : game.gameDescription)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(3)
                    .frame(maxWidth: 620, alignment: .leading)
                HStack(spacing: 12) {
                    Button { viewModel.launch(game: game) } label: {
                        Text("PLAY")
                            .frame(width: 132)
                    }
                    .buttonStyle(VendorGetInButtonStyle())
                    Button { viewModel.selectGame(game) } label: {
                        Text("DETAILS")
                            .frame(width: 132)
                    }
                    .buttonStyle(SecondaryLoginButtonStyle(compact: true))
                }
            }
            .padding(32)
        }
        .clipShape(Rectangle())
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }
}

private struct CatalogRailView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let title: String
    let games: [OPNCatalogGameObject]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.system(size: 22, weight: .black))
                Spacer()
                Text("\(games.count) games")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(games.enumerated()), id: \.element.catalogIdentity) { _, game in
                        CatalogGameTile(viewModel: viewModel, game: game)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

private struct CatalogGameTile: View {
    @ObservedObject var viewModel: CatalogViewModel
    let game: OPNCatalogGameObject
    @State private var isHovering = false

    var body: some View {
        Button { viewModel.selectGame(game) } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomLeading) {
                    CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestTileImageURL, width: 420), contentMode: .fill)
                        .frame(width: 184, height: 246)
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
                    if game.isInLibrary {
                        Text("IN LIBRARY")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.openNowGreen)
                            .padding(8)
                    }
                }
                Text(game.title.isEmpty ? "Untitled Game" : game.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(width: 184, alignment: .leading)
                Text(game.genreLine.isEmpty ? game.storeLine : game.genreLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
                    .frame(width: 184, alignment: .leading)
            }
            .padding(8)
            .background(isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.045))
            .overlay { Rectangle().stroke(isHovering ? Color.openNowGreen.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct GameDetailPanel: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        if let game = viewModel.selectedGame {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestHeroImageURL, width: 760), contentMode: .fill)
                        .frame(height: 224)
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                    Button { viewModel.selectGame(nil) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.black.opacity(0.62))
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(game.title.isEmpty ? "Selected Game" : game.title)
                            .font(.system(size: 32, weight: .black))
                            .lineLimit(3)
                        Text(game.gameDescription.isEmpty ? "Play instantly through GeForce NOW cloud streaming." : game.gameDescription)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineSpacing(3)

                        detailChips(game: game)

                        if !game.variants.isEmpty {
                            Picker("Store", selection: $viewModel.selectedVariantIndex) {
                                ForEach(Array(game.variants.enumerated()), id: \.offset) { index, variant in
                                    Text(variant.appStore.isEmpty ? "GeForce NOW" : variant.appStore.uppercased()).tag(index)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Button { viewModel.launchSelectedGame() } label: {
                            Text("PLAY")
                                .font(.system(size: 15, weight: .black))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(VendorGetInButtonStyle())

                        Button("Open Store") { viewModel.openStoreForSelectedVariant() }
                            .buttonStyle(SecondaryLoginButtonStyle(compact: true))
                            .opacity(game.variants.isEmpty ? 0.5 : 1)
                            .disabled(game.variants.isEmpty)

                        if !viewModel.launchMessage.isEmpty {
                            CatalogMessageView(message: viewModel.launchMessage, systemImage: "play.circle.fill")
                        }

                        detailRows(game: game)
                    }
                    .padding(24)
                }
            }
            .frame(width: 390)
            .frame(maxHeight: .infinity)
            .background(Color(red: 0.075, green: 0.075, blue: 0.075))
            .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1) }
            .shadow(color: .black.opacity(0.52), radius: 26, x: -18, y: 0)
        }
    }

    private func detailChips(game: OPNCatalogGameObject) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(game.detailChips, id: \.self) { chip in
                Text(chip)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.09))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
            }
        }
    }

    private func detailRows(game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CatalogDetailRow(label: "Developer", value: game.developerName)
            CatalogDetailRow(label: "Publisher", value: game.publisherName)
            CatalogDetailRow(label: "Stores", value: game.storeLine)
            CatalogDetailRow(label: "Controls", value: game.supportedControls.joined(separator: ", "))
            CatalogDetailRow(label: "Features", value: game.featureLabels.joined(separator: ", "))
        }
    }
}

private struct CatalogDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .top) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 84, alignment: .leading)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct CatalogRemoteImage: View {
    let url: URL?
    let contentMode: ContentMode

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            case .failure:
                CatalogImageFallback()
            case .empty:
                CatalogImageFallback().overlay { ProgressView().controlSize(.small) }
            @unknown default:
                CatalogImageFallback()
            }
        }
    }
}

private struct CatalogImageFallback: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 34, weight: .black))
                .foregroundStyle(Color.openNowGreen.opacity(0.78))
        }
    }
}

private struct CatalogMessageView: View {
    let message: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.openNowGreen)
            Text(message)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.07))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }
}

private struct CatalogLoadingStrip: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Loading GeForce NOW catalog")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(12)
        .background(Color.white.opacity(0.055))
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var size = CGSize(width: width, height: 0)
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if lineWidth + subviewSize.width > width, lineWidth > 0 {
                size.height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }
        size.height += lineHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if x + subviewSize.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(subviewSize))
            x += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }
    }
}

private extension OPNCatalogGameObject {
    var catalogIdentity: String { CatalogViewModel.identity(for: self) }

    var bestHeroImageURL: String {
        if !heroImageUrl.isEmpty { return heroImageUrl }
        for key in ["HERO_IMAGE", "HERO", "BACKGROUND", "KEY_ART"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        return bestTileImageURL
    }

    var bestTileImageURL: String {
        if !imageUrl.isEmpty { return imageUrl }
        for key in ["BOX_ART", "BOXART", "TILE", "GAME_BOX_ART", "HERO_IMAGE"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        if let value = screenshotUrls.first, !value.isEmpty { return value }
        return heroImageUrl
    }

    var genreLine: String { genres.prefix(3).joined(separator: " / ") }

    var storeLine: String {
        let stores = availableStores.isEmpty ? variants.map(\.appStore) : availableStores
        return stores.filter { !$0.isEmpty }.map { $0.uppercased() }.joined(separator: ", ")
    }

    var detailChips: [String] {
        var chips: [String] = []
        if isInLibrary { chips.append("IN LIBRARY") }
        if !membershipTierLabel.isEmpty { chips.append(membershipTierLabel.uppercased()) }
        if !playabilityState.isEmpty { chips.append(playabilityState.replacingOccurrences(of: "_", with: " ").uppercased()) }
        chips.append(contentsOf: genres.prefix(3).map { $0.uppercased() })
        return chips.isEmpty ? ["CLOUD READY"] : chips
    }
}
