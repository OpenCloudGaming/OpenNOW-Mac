import Foundation

enum DiscordArtwork {
    static let preferredTypeOrder = ["GAME_BOX_ART", "KEY_IMAGE", "KEY_ART"]

    static func imageURL(
        imageUrlsByType: [String: [String]],
        imageUrl: String,
        heroImageUrl: String
    ) -> String? {
        for type in preferredTypeOrder {
            if let match = imageUrlsByType[type]?.first(where: isHTTPS) {
                return match
            }
        }
        if isHTTPS(imageUrl) { return imageUrl }
        if isHTTPS(heroImageUrl) { return heroImageUrl }
        return nil
    }

    static func imageURL(for game: OPNCatalogGameObject) -> String? {
        imageURL(
            imageUrlsByType: game.imageUrlsByType,
            imageUrl: game.imageUrl,
            heroImageUrl: game.heroImageUrl
        )
    }

    static func isHTTPS(_ candidate: String) -> Bool {
        guard
            let url = URL(string: candidate),
            url.scheme?.lowercased() == "https",
            let host = url.host,
            !host.isEmpty
        else {
            return false
        }
        return true
    }
}
