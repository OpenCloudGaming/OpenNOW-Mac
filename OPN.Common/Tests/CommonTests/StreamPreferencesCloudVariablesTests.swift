import Foundation
import Foundation
import Testing
@testable import Common

@Suite(.serialized) struct StreamPreferencesLocationTests {
    @Test func automaticServerLocationKeepsProviderCloudMatchBase() {
        let previousRegionUrl = OPNStreamPreferences.loadSelectedRegionUrl()
        let previousCachedRegions = OPNStreamPreferences.loadCachedRegions()
        defer {
            OPNStreamPreferences.saveSelectedRegionUrl(previousRegionUrl)
            OPNStreamPreferences.saveCachedRegions(previousCachedRegions)
        }

        OPNStreamPreferences.saveSelectedRegionUrl("")
        OPNStreamPreferences.saveCachedRegions([
            OPNStreamRegionOption(name: "Texas (USA)", url: "https://us-texas.cloudmatchbeta.nvidiagrid.net/", latencyMs: 12),
        ])

        #expect(OPNStreamPreferences.loadSelectedStreamingBaseUrl() == OPNStreamPreferences.defaultStreamingBaseUrl)
    }

    @Test func manualServerLocationUsesSelectedRegionalCloudMatchBase() {
        let previousRegionUrl = OPNStreamPreferences.loadSelectedRegionUrl()
        let previousCachedRegions = OPNStreamPreferences.loadCachedRegions()
        defer {
            OPNStreamPreferences.saveSelectedRegionUrl(previousRegionUrl)
            OPNStreamPreferences.saveCachedRegions(previousCachedRegions)
        }

        OPNStreamPreferences.saveSelectedRegionUrl("https://us-texas.cloudmatchbeta.nvidiagrid.net")
        OPNStreamPreferences.saveCachedRegions([
            OPNStreamRegionOption(name: "Georgia (USA)", url: "https://us-georgia.cloudmatchbeta.nvidiagrid.net/", latencyMs: 10),
        ])

        #expect(OPNStreamPreferences.loadSelectedStreamingBaseUrl() == "https://us-texas.cloudmatchbeta.nvidiagrid.net/")
    }

    @Test func cachedRegionsDeduplicatePersistedNormalizedUrls() {
        let defaults = UserDefaults.standard
        let cachedRegionsKey = "OpenNOW.Stream.CachedRegions"
        let previousCachedRegions = defaults.object(forKey: cachedRegionsKey)
        defer {
            if let previousCachedRegions { defaults.set(previousCachedRegions, forKey: cachedRegionsKey) }
            else { defaults.removeObject(forKey: cachedRegionsKey) }
            defaults.synchronize()
        }

        defaults.set([
            ["name": "Unknown", "url": "https://prod.cloudmatchbeta.nvidiagrid.net", "latencyMs": -1],
            ["name": "Slow", "url": "https://prod.cloudmatchbeta.nvidiagrid.net/", "latencyMs": 42],
            ["name": "Fast", "url": "https://prod.cloudmatchbeta.nvidiagrid.net/", "latencyMs": 12],
            ["name": "Texas (USA)", "url": "https://us-texas.cloudmatchbeta.nvidiagrid.net/", "latencyMs": 20],
        ], forKey: cachedRegionsKey)
        defaults.synchronize()

        #expect(OPNStreamPreferences.loadCachedRegions() == [
            OPNStreamRegionOption(name: "Fast", url: "https://prod.cloudmatchbeta.nvidiagrid.net/", latencyMs: 12),
            OPNStreamRegionOption(name: "Texas (USA)", url: "https://us-texas.cloudmatchbeta.nvidiagrid.net/", latencyMs: 20),
        ])
    }
}

@Test func cloudVariablesRequestIncludesRequiredGXTQueryItems() throws {
    let request = try #require(OPNStreamPreferences.cloudVariablesRequest(token: "token", locale: "en_US"))
    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })

    #expect(components.scheme == "https")
    #expect(components.host == "gx-target-experiments-frontend-api.gx.nvidia.com")
    #expect(components.path == "/cloudvariables/v3")
    #expect(queryItems["cvName"]?.contains("webRtcNetworkTestV2") == true)
    #expect(queryItems["clientVer"] == "2.0.85.135")
    #expect(queryItems["clientType"] == "Browser")
    #expect(queryItems["browserType"] == "Chrome")
    #expect(queryItems["deviceOS"] == "MacOS")
    #expect(queryItems["deviceMake"] == "APPLE")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
}
