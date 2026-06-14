//
//  LoginModels.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import Foundation
import SwiftData

@Model
final class LoginAccount {
    @Attribute(.unique) var email: String
    var displayName: String
    var providerIdpId: String
    var providerName: String
    var membershipTier: String
    var authorizationState: String
    var authStatus: String
    var preferredRegion: String
    var createdAt: Date
    var lastLoginAt: Date
    var rememberSession: Bool
    var isActive: Bool

    init(
        email: String,
        displayName: String,
        providerIdpId: String,
        providerName: String,
        membershipTier: String = "Free",
        authorizationState: String = "AUTHORIZED",
        authStatus: String = "LOGGED_IN",
        preferredRegion: String = "Auto",
        createdAt: Date = Date(),
        lastLoginAt: Date = Date(),
        rememberSession: Bool = true,
        isActive: Bool = true
    ) {
        self.email = email
        self.displayName = displayName
        self.providerIdpId = providerIdpId
        self.providerName = providerName
        self.membershipTier = membershipTier
        self.authorizationState = authorizationState
        self.authStatus = authStatus
        self.preferredRegion = preferredRegion
        self.createdAt = createdAt
        self.lastLoginAt = lastLoginAt
        self.rememberSession = rememberSession
        self.isActive = isActive
    }
}

@Model
final class LoginSession {
    @Attribute(.unique) var id: String
    var accountEmail: String
    var authMethod: String
    var accessToken: String
    var clientToken: String
    var idToken: String
    var deviceId: String
    var issuedAt: Date
    var expiresAt: Date
    var clientTokenExpiresAt: Date
    var isActive: Bool
    var canContinueOffline: Bool

    init(
        id: String = UUID().uuidString,
        accountEmail: String,
        authMethod: String,
        accessToken: String,
        clientToken: String,
        idToken: String,
        deviceId: String,
        issuedAt: Date = Date(),
        expiresAt: Date,
        clientTokenExpiresAt: Date,
        isActive: Bool = true,
        canContinueOffline: Bool = true
    ) {
        self.id = id
        self.accountEmail = accountEmail
        self.authMethod = authMethod
        self.accessToken = accessToken
        self.clientToken = clientToken
        self.idToken = idToken
        self.deviceId = deviceId
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.clientTokenExpiresAt = clientTokenExpiresAt
        self.isActive = isActive
        self.canContinueOffline = canContinueOffline
    }

    var isExpired: Bool {
        expiresAt <= Date()
    }
}

@Model
final class LoginDeviceRegistration {
    @Attribute(.unique) var id: String
    var deviceId: String
    var displayName: String
    var createdAt: Date
    var lastUsedAt: Date

    init(
        id: String = "primary",
        deviceId: String = UUID().uuidString,
        displayName: String = Host.current().localizedName ?? "OpenNOW Mac",
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.deviceId = deviceId
        self.displayName = displayName
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}
