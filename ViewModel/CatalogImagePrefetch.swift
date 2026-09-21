//  Warming the image cache ahead of a rail or grid scrolling into view.
//
//  This was two near-identical copies inside `CatalogContentViews`, each reaching for the shared
//  image cache directly from a view. The catalog view model already holds the cache, so the
//  prefetch is issued from here and the views only say what is about to be shown.
//

import Foundation

extension CatalogViewModel {
    /// Rails show a handful of tiles at a time, so only the leading games and the section's own
    /// promo tiles are worth warming.
    func prefetchRailImages(section: CatalogSectionModel, games: [OPNCatalogGameObject]) {
        var urls: [URL] = []
        var seen = Set<String>()
        for game in games.prefix(8) {
            appendPrefetchURL(game.bestTileImageURL, width: 768, urls: &urls, seen: &seen)
            appendPrefetchURL(game.bestWideImageURL, width: 768, urls: &urls, seen: &seen)
            appendPrefetchURL(game.bestLogoImageURL, width: CatalogLogoArtwork.requestWidth, urls: &urls, seen: &seen)
        }
        for tile in section.tiles.prefix(4) {
            appendPrefetchURL(tile.imageUrl, width: 768, urls: &urls, seen: &seen)
        }
        prefetchImages(urls)
    }

    /// Poster rails show more tiles per screen than wide rails, hence the larger prefix. No
    /// `bestWideImageURL` - nothing in Poster draws it.
    func prefetchPosterImages(section: CatalogSectionModel, games: [OPNCatalogGameObject]) {
        var urls: [URL] = []
        var seen = Set<String>()
        for game in games.prefix(10) {
            appendPrefetchURL(game.bestPosterImageURL, width: 512, urls: &urls, seen: &seen)
            appendPrefetchURL(game.bestLogoImageURL, width: CatalogLogoArtwork.requestWidth, urls: &urls, seen: &seen)
        }
        for tile in section.tiles.prefix(4) {
            appendPrefetchURL(tile.imageUrl, width: 768, urls: &urls, seen: &seen)
        }
        prefetchImages(urls)
    }

    /// A grid shows far more at once than a rail, hence the larger prefix.
    func prefetchGridImages(section: CatalogSectionModel) {
        var urls: [URL] = []
        var seen = Set<String>()
        for game in section.games.prefix(18) {
            appendPrefetchURL(game.bestTileImageURL, width: 768, urls: &urls, seen: &seen)
            appendPrefetchURL(game.bestWideImageURL, width: 768, urls: &urls, seen: &seen)
            appendPrefetchURL(game.bestLogoImageURL, width: CatalogLogoArtwork.requestWidth, urls: &urls, seen: &seen)
        }
        prefetchImages(urls)
    }

    /// Warms marquee banners at the size the hero band reads them, keeping the compressed bytes the
    /// scrim colour is derived from. A rung cached without them is a miss for the hero reader, which
    /// then decodes the largest artwork in the app a second time.
    func prefetchHeroArtwork(_ urls: [URL]) {
        imageCache.prefetchPriority(urls, maxPixelSize: 1920, retainingSourceData: true)
    }

    private func appendPrefetchURL(_ rawValue: String, width: Int, urls: inout [URL], seen: inout Set<String>) {
        guard let url = optimizedImageURL(rawValue, width: width) else { return }
        let key = url.absoluteString
        guard !seen.contains(key) else { return }
        seen.insert(key)
        urls.append(url)
    }
}
