//
//  OpenNOW
//

import AppKit
import Foundation

extension OPNGameService {
    func fetchAppPatchStatuses(appIds: [String], completion: @escaping OPNAppPatchStatusesCallback) {
        let uniqueAppIds = Array(Set(appIds.filter { !$0.isEmpty })).sorted()
        guard !uniqueAppIds.isEmpty else {
            dispatchAppPatchStatuses(completion, true, [:], "")
            return
        }
        resolveCatalogVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            let query = """
            query GetAppsPatchInfoForAppIds($vpcId: String!, $locale: String!, $appIds: [String]!) {
              apps(vpcId: $vpcId, language: $locale, appIds: $appIds) {
                items {
                  id
                  variants {
                    id
                    gfn {
                      status
                      library { status }
                      stateDetails {
                        ... on VariantGfnAutoPatchingMetadata { subType startTime endTime historicalEtaMins etaPredictionType }
                        ... on VariantGfnManualPatchingMetadata { subType startTime endTime }
                        ... on VariantGfnMaintenanceMetadata { subType }
                      }
                    }
                  }
                }
              }
            }
            """
            let variables: NSDictionary = ["vpcId": resolvedVpcId.isEmpty ? "GFN-PC" : resolvedVpcId, "locale": Self.currentGFNCatalogLocale(), "appIds": uniqueAppIds]
            self.postGraphQlJson(query: query, variables: variables) { [weak self] data, error in
                guard let self else { return }
                guard error.isEmpty else {
                    self.dispatchAppPatchStatuses(completion, false, [:], error)
                    return
                }
                let items = (data?["apps"] as? NSDictionary)?["items"] as? [NSDictionary] ?? []
                self.dispatchAppPatchStatuses(completion, true, self.parseAppPatchStatuses(items), "")
            }
        }
    }

    func fetchLibraryPatchStatuses(completion: @escaping OPNAppPatchStatusesCallback) {
        resolveCatalogVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            let query = """
            query GetAppsPatchInfoWithLibraryFilter($vpcId: String!, $locale: String!, $fetchCount: Int!, $cursor: String!, $filters: AppFilterFields!) {
              apps(vpcId: $vpcId, language: $locale, first: $fetchCount, after: $cursor, filters: $filters) {
                numberReturned
                pageInfo { hasNextPage endCursor totalCount }
                items {
                  id
                  variants {
                    id
                    gfn {
                      status
                      library { status }
                      stateDetails {
                        ... on VariantGfnAutoPatchingMetadata { subType startTime endTime historicalEtaMins etaPredictionType }
                        ... on VariantGfnManualPatchingMetadata { subType startTime endTime }
                        ... on VariantGfnMaintenanceMetadata { subType }
                      }
                    }
                  }
                }
              }
            }
            """
            let state = PatchStatusPageState()
            let fetchPage = RecursiveCatalogPageFetcher()
            fetchPage.action = { [weak self, state, fetchPage] page, cursor in
                guard let self else { return }
                let variables: NSDictionary = [
                    "vpcId": resolvedVpcId.isEmpty ? "GFN-PC" : resolvedVpcId,
                    "locale": Self.currentGFNCatalogLocale(),
                    "filters": Self.libraryCatalogFilter,
                    "fetchCount": Self.patchInfoFetchCount,
                    "cursor": cursor,
                ]
                self.postGraphQlJson(query: query, variables: variables) { [weak self, state, fetchPage] data, error in
                    guard let self else { return }
                    guard error.isEmpty else {
                        if !state.items.isEmpty {
                            self.dispatchAppPatchStatuses(completion, true, self.parseAppPatchStatuses(state.items), "")
                        } else {
                            self.dispatchAppPatchStatuses(completion, false, [:], error)
                        }
                        return
                    }
                    let apps = data?["apps"] as? NSDictionary
                    state.append(contentsOf: apps?["items"] as? [NSDictionary] ?? [])
                    let pageInfo = apps?["pageInfo"] as? NSDictionary
                    let hasNextPage = self.safeBool(pageInfo?["hasNextPage"])
                    let endCursor = self.safeString(pageInfo?["endCursor"]) ?? ""
                    if hasNextPage, !endCursor.isEmpty, page + 1 < Self.maxCatalogPages {
                        fetchPage.action?(page + 1, endCursor)
                    } else {
                        self.dispatchAppPatchStatuses(completion, true, self.parseAppPatchStatuses(state.items), "")
                    }
                }
            }
            fetchPage.action?(0, "")
        }
    }

    func parseAppPatchStatuses(_ apps: [NSDictionary]) -> [String: OPNAppPatchStatus] {
        var statuses: [String: OPNAppPatchStatus] = [:]
        for app in apps {
            let appId = safeString(app["id"]) ?? ""
            guard !appId.isEmpty else { continue }
            var status = OPNAppPatchStatus(appId: appId)
            for variantData in app["variants"] as? [NSDictionary] ?? [] {
                let variantId = safeString(variantData["id"]) ?? ""
                guard !variantId.isEmpty else { continue }
                let gfn = variantData["gfn"] as? NSDictionary
                let library = gfn?["library"] as? NSDictionary
                let variantIsPatching = currentStatusIsPatching(status: gfn?["status"], playabilityState: gfn?["playabilityState"], libraryStatus: library?["status"], stateDetails: gfn?["stateDetails"])
                status.variantPatchingById[variantId] = variantIsPatching
                let patchText = patchStatusText(status: gfn?["status"] ?? library?["status"], stateDetails: gfn?["stateDetails"], isPatching: variantIsPatching)
                if !patchText.primary.isEmpty { status.primaryTextByVariantId[variantId] = patchText.primary }
                if !patchText.secondary.isEmpty { status.secondaryTextByVariantId[variantId] = patchText.secondary }
                status.isPatching = status.isPatching || variantIsPatching
            }
            statuses[appId] = status
        }
        return statuses
    }

    func isAppPatchingStatus(_ value: Any?) -> Bool {
        if let text = safeString(value)?.lowercased(), !text.isEmpty {
            return text.contains("patch") || text.contains("application_patching") || text.contains("app_patching") || text.contains("autopatching") || text.contains("manualpatching")
        }
        if let dictionary = value as? NSDictionary {
            return dictionary.allValues.contains { isAppPatchingStatus($0) }
        }
        return false
    }

    func currentStatusIsPatching(status: Any?, playabilityState: Any?, libraryStatus: Any?, stateDetails: Any?) -> Bool {
        if isAppPatchingStatus(status) || isAppPatchingStatus(playabilityState) || isAppPatchingStatus(libraryStatus) { return true }
        let hasExplicitStatus = safeString(status) != nil || safeString(playabilityState) != nil || safeString(libraryStatus) != nil
        return hasExplicitStatus ? false : isAppPatchingStatus(stateDetails)
    }

    func patchStatusText(status: Any?, stateDetails: Any?, isPatching: Bool) -> (primary: String, secondary: String) {
        guard isPatching else { return ("", "") }
        let statusText = safeString(status)?.lowercased() ?? ""
        let details = stateDetails as? NSDictionary
        let subtype = (safeString(details?["subType"]) ?? statusText).lowercased()
        let primary = subtype.contains("maintenance") ? "Maintenance" : "Patching"
        let endTime = safeString(details?["endTime"]) ?? ""
        if !endTime.isEmpty { return (primary, "Estimated completion: \(endTime)") }
        let eta = safeInt(details?["historicalEtaMins"])
        if eta > 0 { return (primary, "Estimated completion: \(eta) min") }
        return (primary, "")
    }
}

private final class PatchStatusPageState: @unchecked Sendable {
    let lock = NSLock()
    var storage: [NSDictionary] = []

    var items: [NSDictionary] {
        lock.withLock { storage }
    }

    func append(contentsOf newItems: [NSDictionary]) {
        lock.withLock { storage.append(contentsOf: newItems) }
    }
}
