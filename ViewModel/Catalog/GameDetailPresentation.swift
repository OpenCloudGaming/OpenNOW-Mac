//  Turns a catalog game into the strings the detail panel shows: eyebrow metadata, capability
//  chips, rating descriptors, the access explanation, and the spec rows.
//
//  All of it was `private` inside `GameDetailPanel`, so none of it could be checked without
//  rendering a panel. It is pure: everything it needs arrives as an argument, including the few
//  facts that only the catalog view model knows (whether a launch is queued, whether the selected
//  platform grants access), which come in as `GameDetailAccessContext`.
//

import Foundation

/// The parts of the current selection that the detail copy depends on but the game object does not
/// carry. Resolved by the view from `CatalogViewModel` and handed in.
struct GameDetailAccessContext: Equatable {
    var isQueuedForPatching = false
    var isSelectedVariantPatching = false
    var isSelectedVariantOwned = false
    var hasSelectedVariant = false
    var selectedPlatformHasAccess = false
    /// Title of the subscription that grants access, when one does.
    var subscriptionOptionTitle: String?
    /// Display name of the store the game must be owned on, when ownership is what is missing.
    var ownershipStoreName: String?
}

enum GameDetailPresentation {

    // MARK: - Headline copy

    static func capabilityLabels(game: OPNCatalogGameObject) -> [String] {
        var labels: [String] = []
        if !game.skuPlayabilityText.isEmpty { labels.append(game.skuPlayabilityText) }
        if !game.membershipTierLabel.isEmpty { labels.append("For Premium Members") }
        for technology in supportedTechnologyLabels(game: game).prefix(2) { appendUnique(technology, to: &labels) }
        if labels.isEmpty { labels.append("Cloud Ready") }
        return labels
    }

    static func detailMetadata(game: OPNCatalogGameObject) -> [String] {
        var values: [String] = []
        appendUnique(game.primaryStoreLabel, to: &values)
        appendUnique(game.ratingLabel, to: &values)
        for genre in game.genres.prefix(2) { appendUnique(genre, to: &values) }
        return values
    }

    static func appendUnique(_ value: String, to values: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !values.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        values.append(trimmed)
    }

    static func shortDescription(game: OPNCatalogGameObject) -> String {
        let value = game.shortDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
        return "Play instantly through GeForce NOW cloud streaming."
    }

    static func longDescription(game: OPNCatalogGameObject) -> String {
        let longDescription = game.longDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !longDescription.isEmpty { return longDescription }
        let gameDescription = game.gameDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return gameDescription == shortDescription(game: game) ? "" : gameDescription
    }

    // MARK: - NVIDIA technologies

    static func supportedTechnologyLabels(game: OPNCatalogGameObject) -> [String] {
        var values: [String] = []
        for rawValue in game.nvidiaTech + game.featureLabels + game.skuTags {
            if let label = supportedTechnologyLabel(rawValue) { appendUnique(label, to: &values) }
        }
        return values
    }

    static func supportedTechnologyLabel(_ rawValue: String) -> String? {
        let value = rawValue.lowercased()
        if value.contains("reflex") { return "Reflex" }
        if value.contains("rtx") || value.contains("ray tracing") || value.contains("raytracing") { return "RTX" }
        return nil
    }

    static func featureMessage(_ feature: String) -> String {
        feature.localizedCaseInsensitiveContains("reflex") ? "Upgrade your membership to unlock" : "Ready - You may need to turn this on in-game"
    }

    static func featureIsLocked(_ feature: String) -> Bool {
        feature.localizedCaseInsensitiveContains("reflex")
    }

    // MARK: - Ratings

    static func esrbShortRating(_ rating: String) -> String {
        let uppercased = rating.uppercased()
        if uppercased.contains("EVERYONE 10") { return "E10" }
        if uppercased.contains("EVERYONE") { return "E" }
        if uppercased.contains("TEEN") { return "T" }
        if uppercased.contains("MATURE") { return "M" }
        if uppercased.contains("ADULT") { return "A" }
        return String(uppercased.prefix(1))
    }

    static func ratingDescriptors(game: OPNCatalogGameObject) -> [String] {
        var descriptors = game.ratingDescriptors + game.ratingInteractiveElements
        if descriptors.isEmpty { descriptors = game.contentRatings.filter { $0.caseInsensitiveCompare(game.ratingLabel) != .orderedSame } }
        descriptors.removeAll { ["ESRB", "PEGI", "USK", "CLASSIND", "GRAC", "IARC"].contains($0.uppercased()) }
        if descriptors.isEmpty { descriptors = game.genres.prefix(2).map { $0.capitalized } }
        return Array(descriptors.prefix(3))
    }

    // MARK: - Access and the primary button

    static func primaryActionTitle(game: OPNCatalogGameObject, context: GameDetailAccessContext) -> String {
        if game.isLaunchPatching || context.isSelectedVariantPatching { return context.isQueuedForPatching ? "QUEUED" : "QUEUE" }
        if context.selectedPlatformHasAccess { return "PLAY" }
        if context.hasSelectedVariant { return "MARK OWNED" }
        return "PLAY"
    }

    static func accessBody(game: OPNCatalogGameObject, context: GameDetailAccessContext) -> String {
        if game.isLaunchPatching || context.isSelectedVariantPatching {
            if context.isQueuedForPatching {
                return "Queued to launch automatically after GeForce NOW finishes patching this game."
            }
            let secondary = game.patchStatusSecondaryDisplayText
            return secondary.isEmpty ? "GeForce NOW is \(game.patchStatusPrimaryDisplayText.lowercased()). Launch will be available after patching finishes." : secondary
        }
        if context.isSelectedVariantOwned {
            return "Access unlocked with your membership. Game ownership required to play."
        }
        if let subscriptionOptionTitle = context.subscriptionOptionTitle {
            return "Access unlocked through your \(subscriptionOptionTitle) subscription."
        }
        if let ownershipStoreName = context.ownershipStoreName {
            return "Game ownership required on \(ownershipStoreName) to play."
        }
        return "Access requires a GeForce NOW membership and supported game ownership."
    }

    // MARK: - Spec rows

    static func releaseDateLine(game: OPNCatalogGameObject) -> String {
        let value = game.releaseDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return value
    }

    static func inputLine(game: OPNCatalogGameObject, selectedVariant: OPNCatalogGameVariantObject?) -> String {
        var labels: [String] = []
        let controls = selectedVariant?.supportedControls.isEmpty == false ? selectedVariant?.supportedControls ?? [] : game.supportedControls
        for control in controls { appendUnique(readableControlLabel(control), to: &labels) }
        return labels.joined(separator: ", ")
    }

    static func readableControlLabel(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "_", with: " ").lowercased()
        if normalized.contains("keyboard") || normalized.contains("mouse") { return "Keyboard & Mouse" }
        if normalized.contains("gamepad partial") { return "Partial Gamepad" }
        if normalized.contains("gamepad") || normalized.contains("controller") { return "Gamepad" }
        if normalized.contains("touch") { return "Touchscreen" }
        if normalized.contains("wheel") { return "Wheel" }
        if normalized.contains("flight") || normalized.contains("hotas") { return "Flight Controls" }
        return value.capitalized
    }

    static func playerLine(game: OPNCatalogGameObject) -> String {
        let local = game.maxLocalPlayers
        let online = game.maxOnlinePlayers
        guard local > 0 || online > 0 else { return "" }
        if online > 1, local > 1 { return "1-\(local) local, online multiplayer" }
        if online > 1 { return "Single player, online multiplayer" }
        if local > 1 { return "1-\(local) local players" }
        return "Single player"
    }
}
