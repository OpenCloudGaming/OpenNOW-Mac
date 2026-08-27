//
//  SettingsConnectionsViews.swift
//  OpenNOW
//

import AppKit
import CryptoKit
import SwiftUI

struct ConnectionsSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        let stores = connectionStores
        SettingsCard(title: "Store Connections", uiScale: uiScale) {
            if stores.isEmpty {
                AccountEmptyState(title: "No store providers available.", subtitle: "OpenNOW did not return any account providers for this session.", uiScale: uiScale)
            } else {
                StoreConnectionsOverview(connectedCount: connectedStoreCount(in: stores), totalCount: stores.count, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                VStack(spacing: 8 * uiScale) {
                    ForEach(stores, id: \.self) { store in
                        StoreConnectionRow(viewModel: viewModel, store: store, uiScale: uiScale)
                    }
                }
            }
        }
    }

    private var connectionStores: [String] {
        var seen = Set<String>()
        var stores: [String] = []
        for store in viewModel.storeDefinitions.map(\.store) + viewModel.accountStores.map(\.store) where !store.isEmpty {
            let key = store.lowercased()
            guard !seen.contains(key), !isHiddenConnectionStore(store) else { continue }
            seen.insert(key)
            stores.append(store)
        }
        return stores.sorted { lhs, rhs in
            let lhsConnected = viewModel.accountStatus(forStore: lhs) != nil
            let rhsConnected = viewModel.accountStatus(forStore: rhs) != nil
            if lhsConnected != rhsConnected { return lhsConnected }
            return viewModel.displayName(forStore: lhs).localizedStandardCompare(viewModel.displayName(forStore: rhs)) == .orderedAscending
        }
    }

    private func connectedStoreCount(in stores: [String]) -> Int {
        stores.filter { viewModel.accountStatus(forStore: $0) != nil }.count
    }

    private func isHiddenConnectionStore(_ store: String) -> Bool {
        let rawKey = normalizedStoreKey(store)
        let displayKey = normalizedStoreKey(viewModel.displayName(forStore: store))
        return Self.hiddenConnectionStoreKeys.contains(rawKey) || Self.hiddenConnectionStoreKeys.contains(displayKey)
    }

    private func normalizedStoreKey(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static let hiddenConnectionStoreKeys: Set<String> = [
        "ea",
        "eaapp",
        "electronicarts",
        "gog",
        "gogcom",
        "none",
        "nvidia",
        "origin",
        "stove",
        "unknown"
    ]
}

struct StoreConnectionsOverview: View {
    let connectedCount: Int
    let totalCount: Int
    let uiScale: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 14 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text("Library ownership sync")
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white)
                Text("Connected stores can sync library ownership before launch.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer(minLength: 0)
            SettingsStatusPill(title: "CONNECTED", value: "\(connectedCount)/\(totalCount)", positive: connectedCount > 0, uiScale: uiScale)
        }
    }
}

struct StoreConnectionRow: View {
    let viewModel: CatalogViewModel
    let store: String
    let uiScale: CGFloat

    var body: some View {
        let account = viewModel.accountStatus(forStore: store)
        let definition = viewModel.storeDefinitions.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
        let displayName = viewModel.displayName(forStore: store)
        let iconAsset = StoreIconAsset.resolve(store: store, displayName: displayName)
        let iconURL = definition?.smallImageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let isConnected = account != nil
        let supportsLinking = definition?.isAccountLinkingSupported == true || account?.hasAccountLinkingData == true
        HStack(alignment: .center, spacing: 16 * uiScale) {
            Rectangle()
                .fill(isConnected ? OpenNOWDesign.accent : Color.white.opacity(0.18))
                .frame(width: 4 * uiScale, height: 46 * uiScale)
            StoreIcon(asset: iconAsset, imageURL: iconURL, connected: isConnected, uiScale: uiScale)
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(displayName)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(isConnected ? .white : .white.opacity(0.86))
                Text(statusText(account))
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(isConnected ? .white.opacity(0.62) : .white.opacity(0.44))
            }
            Spacer(minLength: 12 * uiScale)
            SettingsStatusPill(title: isConnected ? "LINKED" : "AVAILABLE", value: isConnected ? connectionDetail(account) : "Not linked", positive: isConnected, uiScale: uiScale)
            if account?.hasAccountSyncingData == true {
                SettingsActionButton(title: "SYNC", tone: .secondary, minimumWidth: 86 * uiScale, uiScale: uiScale) { viewModel.syncStoreAccount(store) }
            }
            if supportsLinking {
                SettingsActionButton(title: account == nil ? "CONNECT" : "MANAGE", minimumWidth: 96 * uiScale, uiScale: uiScale) { viewModel.linkStoreAccount(store) }
            }
        }
        .padding(12 * uiScale)
        .background(isConnected ? OpenNOWDesign.accent.opacity(0.095) : SettingsVendorLayout.row)
        .overlay { Rectangle().stroke(isConnected ? OpenNOWDesign.accent.opacity(0.34) : Color.white.opacity(0.08), lineWidth: 1) }
    }

    private func statusText(_ account: CatalogStoreAccount?) -> String {
        guard let account else { return "Not connected" }
        if !account.userDisplayName.isEmpty { return "Connected as \(account.userDisplayName)" }
        if !account.userIdentifier.isEmpty { return "Connected as \(account.userIdentifier)" }
        if account.totalSyncedGames > 0 { return "\(account.totalSyncedGames) synced games" }
        if !account.syncState.isEmpty { return account.syncState.replacingOccurrences(of: "_", with: " ").capitalized }
        return "Connected"
    }

    private func connectionDetail(_ account: CatalogStoreAccount?) -> String {
        guard let account else { return "Not linked" }
        if account.totalSyncedGames > 0 { return "\(account.totalSyncedGames) games" }
        if !account.syncDate.isEmpty { return "Synced" }
        return "Ready"
    }
}

struct StoreIcon: View {
    let asset: StoreIconAsset?
    let imageURL: String?
    let connected: Bool
    let uiScale: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(connected ? OpenNOWDesign.accent.opacity(0.18) : Color.white.opacity(0.075))
            if let url = resolvedImageURL {
                StoreRemoteIconImage(url: url, asset: asset, connected: connected)
            } else {
                StoreLocalIconImage(asset: asset, connected: connected)
            }
        }
        .frame(width: 42 * uiScale, height: 42 * uiScale)
        .overlay { Rectangle().stroke(connected ? OpenNOWDesign.accent.opacity(0.42) : Color.white.opacity(0.12), lineWidth: 1) }
        .accessibilityHidden(true)
    }

    private var resolvedImageURL: URL? {
        guard let imageURL, !imageURL.isEmpty else { return nil }
        return URL(string: imageURL)
    }
}

struct StoreRemoteIconImage: View {
    let imageCache: any CatalogImageServing = CatalogImageCache.shared
    let url: URL
    let asset: StoreIconAsset?
    let connected: Bool

    @State private var image: NSImage?
    @State private var hasFailed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
                    .saturation(connected ? 1 : 0.65)
                    .opacity(connected ? 1 : 0.68)
            } else if hasFailed {
                StoreLocalIconImage(asset: asset, connected: connected)
            } else {
                StoreLocalIconImage(asset: asset, connected: connected)
                    .opacity(0.42)
            }
        }
        .task(id: url) { await loadImage() }
    }

    @MainActor
    private func loadImage() async {
        image = nil
        hasFailed = false
        guard let cached = await imageCache.image(for: url), !Task.isCancelled else {
            hasFailed = !Task.isCancelled
            return
        }
        image = cached.image
        hasFailed = false
    }
}

struct StoreLocalIconImage: View {
    let asset: StoreIconAsset?
    let connected: Bool

    var body: some View {
        if let asset, let image = StoreIconImage.loadImage(named: asset.assetName) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(asset.padding)
                .saturation(connected ? 1 : 0.65)
                .opacity(connected ? 1 : 0.68)
        } else {
            Image(systemName: "link")
                .font(.settingsNvidia(size: 17, weight: .bold))
                .foregroundStyle(connected ? OpenNOWDesign.accent : .white.opacity(0.56))
        }
    }
}

enum StoreIconImage {
    @MainActor static func loadImage(named name: String) -> NSImage? {
        let cacheKey = name as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "StoreIcons") ?? Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Resources/StoreIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    @MainActor private static let cache = NSCache<NSString, NSImage>()
}

enum StoreIconAsset: CaseIterable {
    case battlenet
    case epicGames
    case steam
    case ubisoftConnect
    case xbox
    case gaijin

    var assetName: String {
        switch self {
        case .battlenet: return "store-battlenet"
        case .epicGames: return "store-epic-games"
        case .steam: return "store-steam"
        case .ubisoftConnect: return "store-ubisoft-connect"
        case .xbox: return "store-xbox"
        case .gaijin: return "store-gaijin"
        }
    }

    var padding: CGFloat {
        switch self {
        case .epicGames: return 5
        case .steam, .xbox: return 4
        default: return 6
        }
    }

    static func resolve(store: String, displayName: String) -> StoreIconAsset? {
        let key = normalized(store)
        let displayKey = normalized(displayName)
        let combined = key + displayKey
        if combined.contains("battlenet") || combined.contains("battle") || combined.contains("blizzard") { return .battlenet }
        if combined.contains("epic") { return .epicGames }
        if combined.contains("steam") { return .steam }
        if combined.contains("ubisoft") || combined.contains("uplay") { return .ubisoftConnect }
        if combined.contains("xbox") || combined.contains("microsoft") { return .xbox }
        if combined.contains("gaijin") { return .gaijin }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
