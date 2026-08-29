//  CatalogPatchStatusLogic.swift
//  OpenNOW
//

import Foundation

/// Patch-status merging and application. The catalog game objects are reference types,
/// so these mutate the passed graph in place and hold no view-model state of their own.
enum CatalogPatchStatusLogic {
    static func updatePatchingStatuses(in games: inout [OPNCatalogGameObject], statuses: [String: OPNAppPatchStatus]) {
        for game in games {
            guard let status = patchStatus(for: game, statuses: statuses) else { continue }
            applyPatchingStatus(status, to: game)
        }
    }

    static func updatePatchingStatuses(in panels: inout [OPNCatalogPanelObject], statuses: [String: OPNAppPatchStatus]) {
        for panel in panels {
            for section in panel.sections {
                for game in section.games {
                    guard let status = patchStatus(for: game, statuses: statuses) else { continue }
                    applyPatchingStatus(status, to: game)
                }
            }
        }
    }

    static func applyPatchingStatus(_ status: OPNAppPatchStatus, to game: OPNCatalogGameObject) {
        for variant in game.variants {
            if let isPatching = status.variantPatchingById[variant.id] {
                variant.isPatching = isPatching
                variant.patchStatusPrimaryText = isPatching ? status.primaryTextByVariantId[variant.id] ?? variant.patchStatusPrimaryText : ""
                variant.patchStatusSecondaryText = isPatching ? status.secondaryTextByVariantId[variant.id] ?? variant.patchStatusSecondaryText : ""
            }
        }
        game.isPatching = status.isPatching || game.variants.contains { $0.isPatching }
        game.patchStatusPrimaryText = game.isPatching ? game.variants.first { !$0.patchStatusPrimaryText.isEmpty }?.patchStatusPrimaryText ?? status.primaryTextByVariantId.values.first ?? "Patching" : ""
        game.patchStatusSecondaryText = game.isPatching ? game.variants.first { !$0.patchStatusSecondaryText.isEmpty }?.patchStatusSecondaryText ?? status.secondaryTextByVariantId.values.first ?? "" : ""
    }

    static func mergePatchStatuses(_ source: [String: OPNAppPatchStatus], into target: inout [String: OPNAppPatchStatus]) {
        for (appId, status) in source {
            guard var existing = target[appId] else {
                target[appId] = status
                continue
            }
            existing.isPatching = existing.isPatching || status.isPatching
            existing.variantPatchingById.merge(status.variantPatchingById) { _, new in new }
            existing.primaryTextByVariantId.merge(status.primaryTextByVariantId) { _, new in new }
            existing.secondaryTextByVariantId.merge(status.secondaryTextByVariantId) { _, new in new }
            target[appId] = existing
        }
    }

    static func isPatching(_ game: OPNCatalogGameObject) -> Bool {
        game.isPatching || game.variants.contains { $0.isPatching }
    }

    static func patchStatusAppId(_ game: OPNCatalogGameObject) -> String? {
        for value in [game.uuid, game.id, game.launchAppId] where !value.isEmpty { return value }
        return nil
    }

    static func patchStatus(for game: OPNCatalogGameObject, statuses: [String: OPNAppPatchStatus]) -> OPNAppPatchStatus? {
        for key in [game.uuid, game.id, game.launchAppId] where !key.isEmpty {
            if let status = statuses[key] { return status }
        }
        return nil
    }
}
