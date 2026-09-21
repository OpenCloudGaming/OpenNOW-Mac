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

    /// Warms the marquee slides the hero will rotate to. Banners decode at the size and with the
    /// source bytes the hero band reads them; wordmarks do not need the bytes. Deferred rather than
    /// priority: these are not on the first frame, so they decode one at a time behind it.
    func prewarmHeroRotation(heroURLs: [URL], wordmarkURLs: [URL]) {
        imageCache.prewarmDeferred(heroURLs, maxPixelSize: 1920, retainingSourceData: true)
        imageCache.prewarmDeferred(wordmarkURLs, maxPixelSize: CGFloat(CatalogLogoArtwork.requestWidth), retainingSourceData: false)
    }

    private func appendPrefetchURL(_ rawValue: String, width: Int, urls: inout [URL], seen: inout Set<String>) {
        guard let url = optimizedImageURL(rawValue, width: width) else { return }
        let key = url.absoluteString
        guard !seen.contains(key) else { return }
        seen.insert(key)
        urls.append(url)
    }
}
