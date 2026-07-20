import Foundation
import Testing
@testable import MacForceNow

private struct PerformanceAuditMeasurement: Encodable {
    let package: String
    let operation: String
    let modelCount: Int
    let iterations: Int
    let totalMilliseconds: Double
    let meanMilliseconds: Double
    let minMilliseconds: Double
    let maxMilliseconds: Double
}

private struct PerformanceAuditOutput: Encodable {
    let generatedAt: String
    let measurements: [PerformanceAuditMeasurement]
}

private struct AuditCatalogSectionModel {
    let id: String
    let title: String
    let games: [OPNCatalogGameObject]
}

@Test func catalogModelPerformanceAudit() throws {
    guard ProcessInfo.processInfo.environment["MACFORCE_NOW_PERF_AUDIT"] == "1" else { return }

    let sizes = [96, 500, 1_500, 3_000]
    var measurements: [PerformanceAuditMeasurement] = []

    for size in sizes {
        let games = makeAuditGames(count: size)
        let panels = makeAuditPanels(games: games, panelCount: 6, sectionCount: 4, gamesPerSection: min(48, max(12, size / 24)))
        let encodedGames = try JSONEncoder().encode(games)

        measurements.append(try measureThrowingAuditOperation(package: "OPN.GameServices", operation: "JSONDecoder.decode([OPNGameInfo])", modelCount: size, iterations: 25) {
            _ = try JSONDecoder().decode([OPNGameInfo].self, from: encodedGames)
        })

        measurements.append(try measureThrowingAuditOperation(package: "OPN.GameServices", operation: "JSONEncoder.encode([OPNGameInfo])", modelCount: size, iterations: 25) {
            _ = try JSONEncoder().encode(games)
        })

        measurements.append(measureAuditOperation(package: "OPN.GameServices", operation: "OPNCatalogGameObject init map", modelCount: size, iterations: 50) {
            _ = games.map(OPNCatalogGameObject.init)
        })

        let objects = games.map(OPNCatalogGameObject.init)
        measurements.append(measureAuditOperation(package: "OPN.GameServices", operation: "OPNCatalogGameObject swiftValue map", modelCount: size, iterations: 50) {
            _ = objects.map(\.swiftValue)
        })

        measurements.append(measureAuditOperation(package: "OPN.GameServices", operation: "OPNCatalogPanelObject init map", modelCount: size, iterations: 50) {
            _ = panels.map(OPNCatalogPanelObject.init)
        })

        let panelObjects = panels.map(OPNCatalogPanelObject.init)
        measurements.append(measureAuditOperation(package: "MacForceNow", operation: "CatalogViewModel.catalogSections equivalent", modelCount: size, iterations: 500) {
            _ = deriveAuditCatalogSections(from: panelObjects)
        })

        measurements.append(measureAuditOperation(package: "MacForceNow", operation: "CatalogViewModel.marqueeGames equivalent", modelCount: size, iterations: 500) {
            _ = deriveAuditMarqueeGames(from: panelObjects)
        })

        let sections = deriveAuditCatalogSections(from: panelObjects)
        let selected = sections.last?.games.last ?? objects.last
        measurements.append(measureAuditOperation(package: "MacForceNow", operation: "selected detail section scan equivalent", modelCount: size, iterations: 2_000) {
            _ = firstAuditDetailSectionIndex(for: selected, sections: sections)
        })

        measurements.append(measureAuditOperation(package: "MacForceNow", operation: "best image URL derivation equivalent", modelCount: size, iterations: 500) {
            _ = objects.map(bestAuditImageURLs)
        })
    }

    let output = PerformanceAuditOutput(generatedAt: ISO8601DateFormatter().string(from: Date()), measurements: measurements)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(output)
    if let outputPath = ProcessInfo.processInfo.environment["MACFORCE_NOW_PERF_AUDIT_OUTPUT"], !outputPath.isEmpty {
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
    print(String(decoding: data, as: UTF8.self))
}

private func measureAuditOperation(package: String, operation: String, modelCount: Int, iterations: Int, body: () -> Void) -> PerformanceAuditMeasurement {
    measureAuditDurations(package: package, operation: operation, modelCount: modelCount, iterations: iterations) {
        body()
    }
}

private func measureThrowingAuditOperation(package: String, operation: String, modelCount: Int, iterations: Int, body: () throws -> Void) throws -> PerformanceAuditMeasurement {
    try measureThrowingAuditDurations(package: package, operation: operation, modelCount: modelCount, iterations: iterations) {
        try body()
    }
}

private func measureAuditDurations(package: String, operation: String, modelCount: Int, iterations: Int, body: () -> Void) -> PerformanceAuditMeasurement {
    var durations: [Double] = []
    durations.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        let end = DispatchTime.now().uptimeNanoseconds
        durations.append(Double(end - start) / 1_000_000)
    }
    return makeAuditMeasurement(package: package, operation: operation, modelCount: modelCount, iterations: iterations, durations: durations)
}

private func measureThrowingAuditDurations(package: String, operation: String, modelCount: Int, iterations: Int, body: () throws -> Void) throws -> PerformanceAuditMeasurement {
    var durations: [Double] = []
    durations.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        let end = DispatchTime.now().uptimeNanoseconds
        durations.append(Double(end - start) / 1_000_000)
    }
    return makeAuditMeasurement(package: package, operation: operation, modelCount: modelCount, iterations: iterations, durations: durations)
}

private func makeAuditMeasurement(package: String, operation: String, modelCount: Int, iterations: Int, durations: [Double]) -> PerformanceAuditMeasurement {
    let total = durations.reduce(0, +)
    return PerformanceAuditMeasurement(
        package: package,
        operation: operation,
        modelCount: modelCount,
        iterations: iterations,
        totalMilliseconds: total,
        meanMilliseconds: total / Double(iterations),
        minMilliseconds: durations.min() ?? 0,
        maxMilliseconds: durations.max() ?? 0
    )
}

private func makeAuditGames(count: Int) -> [OPNGameInfo] {
    (0..<count).map { index in
        var game = OPNGameInfo()
        game.id = "game-\(index)"
        game.uuid = "uuid-\(index)"
        game.launchAppId = "\(100_000 + index)"
        game.title = "Realistic Catalog Game \(index)"
        game.shortName = "Game \(index)"
        game.description = String(repeating: "A cloud game with rich metadata and store variants. ", count: 8)
        game.developerName = "Developer \(index % 37)"
        game.publisherName = "Publisher \(index % 29)"
        game.maxLocalPlayers = (index % 4) + 1
        game.maxOnlinePlayers = (index % 64) + 1
        game.playType = index.isMultiple(of: 3) ? "Full Game" : "Streaming"
        game.membershipTierLabel = index.isMultiple(of: 5) ? "Ultimate" : "Priority"
        game.playabilityState = "PLAYABLE"
        game.imageUrl = "https://assets.example.invalid/games/\(index)/boxart.jpg"
        game.heroImageUrl = "https://assets.example.invalid/games/\(index)/hero.jpg"
        game.screenshotUrls = (0..<4).map { "https://assets.example.invalid/games/\(index)/screenshot-\($0).jpg" }
        game.imageUrlsByType = [
            "BOX_ART": [game.imageUrl],
            "HERO_IMAGE": [game.heroImageUrl],
            "MARQUEE_HERO_IMAGE": ["https://assets.example.invalid/games/\(index)/marquee.jpg"],
            "GAME_LOGO": ["https://assets.example.invalid/games/\(index)/logo.png"],
            "TV_BANNER": ["https://assets.example.invalid/games/\(index)/banner.jpg"]
        ]
        let genreValues = ["Action", "Adventure", "Strategy", "Indie"]
        let featureValues = ["RTX", "DLSS", "Cloud Saves", "Controller"]
        game.genres = Array(genreValues[0..<((index % 4) + 1)])
        game.featureLabels = Array(featureValues[0..<((index % 4) + 1)])
        game.supportedControls = ["Keyboard", "Mouse", "Gamepad"]
        game.contentRatings = ["ESRB T", "PEGI 12"]
        game.nvidiaTech = ["Reflex", "HDR"]
        let storeValues = ["STEAM", "EPIC", "UBISOFT"]
        game.availableStores = Array(storeValues[0..<((index % 3) + 1)])
        game.isInLibrary = index.isMultiple(of: 4)
        game.variants = (0..<3).map { variantIndex in
            OPNGameVariant(
                id: "game-\(index)-variant-\(variantIndex)",
                appStore: game.availableStores[min(variantIndex, game.availableStores.count - 1)],
                storeUrl: "https://store.example.invalid/game/\(index)/\(variantIndex)",
                serviceStatus: "AVAILABLE",
                librarySelected: variantIndex == 0,
                inLibrary: game.isInLibrary
            )
        }
        return game
    }
}

private func makeAuditPanels(games: [OPNGameInfo], panelCount: Int, sectionCount: Int, gamesPerSection: Int) -> [OPNPanelResult] {
    guard !games.isEmpty else { return [] }
    return (0..<panelCount).map { panelIndex in
        let sections = (0..<sectionCount).map { sectionIndex in
            let start = ((panelIndex * sectionCount + sectionIndex) * gamesPerSection) % games.count
            let sectionGames = (0..<gamesPerSection).map { games[(start + $0) % games.count] }
            return OPNPanelSection(id: "panel-\(panelIndex)-section-\(sectionIndex)", title: "Section \(sectionIndex)", typename: "GameSection", games: sectionGames)
        }
        return OPNPanelResult(id: "panel-\(panelIndex)", title: "Panel \(panelIndex)", typename: "Panel", sections: sections)
    }
}

private func deriveAuditCatalogSections(from panels: [OPNCatalogPanelObject]) -> [AuditCatalogSectionModel] {
    var sections: [AuditCatalogSectionModel] = []
    var seenTitles = Set<String>()
    for panel in panels {
        for section in panel.sections where !section.games.isEmpty {
            let title = section.title.isEmpty ? panel.title : section.title
            let resolvedTitle = title.isEmpty ? "Featured Games" : title
            guard !seenTitles.contains(resolvedTitle) else { continue }
            seenTitles.insert(resolvedTitle)
            sections.append(AuditCatalogSectionModel(id: section.id.isEmpty ? resolvedTitle : section.id, title: resolvedTitle, games: section.games))
        }
    }
    return sections
}

private func deriveAuditMarqueeGames(from panels: [OPNCatalogPanelObject]) -> [OPNCatalogGameObject] {
    var games: [OPNCatalogGameObject] = []
    var seen = Set<String>()
    for panel in panels {
        for section in panel.sections {
            for game in section.games {
                let key = auditIdentity(for: game)
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                games.append(game)
            }
        }
    }
    return games
}

private func firstAuditDetailSectionIndex(for selectedGame: OPNCatalogGameObject?, sections: [AuditCatalogSectionModel]) -> Int? {
    guard let selectedGame else { return nil }
    for index in sections.indices where sections[index].games.contains(where: { auditLooseIdentityMatches($0, selectedGame) }) {
        return index
    }
    return nil
}

private func auditIdentity(for game: OPNCatalogGameObject) -> String {
    if !game.id.isEmpty { return game.id }
    if !game.uuid.isEmpty { return game.uuid }
    if !game.launchAppId.isEmpty { return game.launchAppId }
    return game.title.lowercased()
}

private func auditLooseIdentityMatches(_ lhs: OPNCatalogGameObject, _ rhs: OPNCatalogGameObject) -> Bool {
    let lhsIdentity = auditIdentity(for: lhs)
    let rhsIdentity = auditIdentity(for: rhs)
    if !lhsIdentity.isEmpty, lhsIdentity == rhsIdentity { return true }
    if !lhs.launchAppId.isEmpty, lhs.launchAppId == rhs.launchAppId { return true }
    return !lhs.title.isEmpty && lhs.title.caseInsensitiveCompare(rhs.title) == .orderedSame
}

private func bestAuditImageURLs(for game: OPNCatalogGameObject) -> [String] {
    [bestAuditHeroImageURL(for: game), bestAuditLogoImageURL(for: game), bestAuditTileImageURL(for: game), bestAuditWideImageURL(for: game)].filter { !$0.isEmpty }
}

private func bestAuditHeroImageURL(for game: OPNCatalogGameObject) -> String {
    if !game.heroImageUrl.isEmpty { return game.heroImageUrl }
    for key in ["MARQUEE_HERO_IMAGE", "HERO_IMAGE"] {
        if let value = game.imageUrlsByType[key]?.first, !value.isEmpty { return value }
    }
    return bestAuditTileImageURL(for: game)
}

private func bestAuditLogoImageURL(for game: OPNCatalogGameObject) -> String {
    for key in ["GAME_LOGO", "LOGO", "TITLE_LOGO"] {
        if let value = game.imageUrlsByType[key]?.first, !value.isEmpty { return value }
        if let value = game.imageUrlsByType[key.lowercased()]?.first, !value.isEmpty { return value }
    }
    return ""
}

private func bestAuditTileImageURL(for game: OPNCatalogGameObject) -> String {
    if !game.imageUrl.isEmpty { return game.imageUrl }
    for key in ["BOX_ART", "BOXART", "TILE", "GAME_BOX_ART", "HERO_IMAGE"] {
        if let value = game.imageUrlsByType[key]?.first, !value.isEmpty { return value }
    }
    if let value = game.screenshotUrls.first, !value.isEmpty { return value }
    return game.heroImageUrl
}

private func bestAuditWideImageURL(for game: OPNCatalogGameObject) -> String {
    for key in ["TV_BANNER"] {
        if let value = game.imageUrlsByType[key]?.first, !value.isEmpty { return value }
    }
    return ""
}
