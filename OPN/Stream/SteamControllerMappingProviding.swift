//
//  SteamControllerMappingProviding.swift
//  MacForceNow
//

import Foundation

@MainActor
protocol SteamControllerMappingProviding: AnyObject {
    var activeProfile: SteamControllerMappingProfile? { get }
}

extension SteamControllerMappingStore: SteamControllerMappingProviding {}
