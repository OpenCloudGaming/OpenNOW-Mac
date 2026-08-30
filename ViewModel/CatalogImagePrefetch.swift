//
//  CatalogImagePrefetch.swift
//  OpenNOW
//
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
            appendPrefetchURL(game.bestLogoImageURL, width: 300, urls: &urls, seen: &seen)
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
            appendPrefetchURL(game.bestLogoImageURL, width: 300, urls: &urls, seen: &seen)
        }
        prefetchImages(urls)
    }

    private func appendPrefetchURL(_ rawValue: String, width: Int, urls: inout [URL], seen: inout Set<String>) {
        guard let url = optimizedImageURL(rawValue, width: width) else { return }
        let key = url.absoluteString
        guard !seen.contains(key) else { return }
        seen.insert(key)
        urls.append(url)
    }
}
