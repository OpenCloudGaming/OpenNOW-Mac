import AppKit
import CryptoKit
import Foundation

@objc(OPNAppDelegateSupport)
final class OPNAppDelegateSupport: NSObject {
    @objc(screenNameForScreen:)
    static func screenName(forScreen screen: Int) -> String {
        switch screen {
        case 0: return "email_entry"
        case 1: return "authenticating"
        case 2: return "store"
        case 3: return "catalog"
        case 4: return "settings"
        case 5: return "error"
        case 6: return "oauth_browser"
        default: return "unknown"
        }
    }

    @objc(supportsDesktopNavigationForScreen:)
    static func supportsDesktopNavigation(forScreen screen: Int) -> Bool {
        screen == 2 || screen == 3 || screen == 4
    }

    @objc(authSessionToken:)
    static func authSessionToken(_ session: NSObject?) -> String {
        let idToken = stringValue(session, key: "idToken")
        if !idToken.isEmpty { return idToken }
        return stringValue(session, key: "accessToken")
    }

    @objc(authSessionAccessTokenValid:)
    static func authSessionAccessTokenValid(_ session: NSObject?) -> Bool {
        let token = stringValue(session, key: "accessToken")
        let expiry = int64Value(session, key: "accessTokenExpiry")
        return !token.isEmpty && expiry > currentMilliseconds()
    }

    @objc(authSessionClientTokenValid:)
    static func authSessionClientTokenValid(_ session: NSObject?) -> Bool {
        let token = stringValue(session, key: "clientToken")
        let expiry = int64Value(session, key: "clientTokenExpiry")
        return !token.isEmpty && expiry > currentMilliseconds()
    }

    @objc(authSessionIdentifier:)
    static func authSessionIdentifier(_ session: NSObject?) -> String {
        let userId = stringValue(session, key: "userId")
        if !userId.isEmpty { return userId }
        let email = stringValue(session, key: "email")
        if !email.isEmpty { return email }
        let displayName = stringValue(session, key: "displayName")
        if !displayName.isEmpty { return displayName }
        return stringValue(session, key: "accessToken")
    }

    @objc(authSessionDisplayName:)
    static func authSessionDisplayName(_ session: NSObject?) -> String {
        let displayName = stringValue(session, key: "displayName")
        if !displayName.isEmpty { return displayName }
        let email = stringValue(session, key: "email")
        if !email.isEmpty {
            let localPart = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
            return localPart.isEmpty ? email : localPart
        }
        let userId = stringValue(session, key: "userId")
        if !userId.isEmpty { return userId }
        return "Account"
    }

    @objc(displayTier:)
    static func displayTier(_ tier: String?) -> String {
        let raw = tier?.isEmpty == false ? tier! : "Free"
        switch raw.uppercased() {
        case "ULTIMATE": return "Ultimate"
        case "PRIORITY", "PERFORMANCE": return "Priority"
        case "FREE": return "Free"
        default: return raw.capitalized
        }
    }

    @objc(formatRemainingPlayTimeForSubscription:)
    static func formatRemainingPlayTime(forSubscription subscription: NSObject?) -> String {
        if boolValue(subscription, key: "isUnlimited") { return "Unlimited" }
        return "\(formatHours(doubleValue(subscription, key: "remainingHours"))) left"
    }

    @objc(stringLooksLikeEmail:)
    static func stringLooksLikeEmail(_ value: String?) -> Bool {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let atIndex = trimmed.firstIndex(of: "@"), atIndex != trimmed.startIndex else { return false }
        let domainStart = trimmed.index(after: atIndex)
        guard domainStart < trimmed.endIndex else { return false }
        return trimmed[domainStart...].contains(".")
    }

    @objc(displayNameFromUserInfo:)
    static func displayName(fromUserInfo info: NSDictionary?) -> String? {
        guard let value = info?["preferred_username"] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @objc(gravatarURLStringForEmail:)
    static func gravatarURLString(forEmail rawEmail: String?) -> String? {
        guard let rawEmail, !rawEmail.isEmpty else { return nil }
        let normalized = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, let data = normalized.data(using: .utf8) else { return nil }
        let digest = Insecure.MD5.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "https://www.gravatar.com/avatar/\(hash)?s=96&d=identicon"
    }

    @objc(accountSwitcherImageForSession:currentAvatar:)
    static func accountSwitcherImage(forSession session: NSObject?, currentAvatar: NSImage?) -> NSImage? {
        _ = session
        guard let currentAvatar else { return nil }
        let image = currentAvatar.copy() as? NSImage
        image?.size = NSSize(width: 22.0, height: 22.0)
        return image
    }

    @objc(sessionProbeAuthenticationError:)
    static func sessionProbeAuthenticationError(_ error: String?) -> Bool {
        let text = error ?? ""
        return text.contains("HTTP 401")
            || text.contains("HTTP 403")
            || text.contains("AUTH_FAILURE")
            || text.contains("auth_failure")
            || text.contains("No access token")
    }

    @objc(transientNetworkLostError:)
    static func transientNetworkLostError(_ error: String?) -> Bool {
        let lower = (error ?? "").lowercased()
        return lower.contains("network connection was lost")
            || lower.contains("nsurlerrornetworkconnectionlost")
            || lower.contains("-1005")
    }

    @objc(unauthorizedError:)
    static func unauthorizedError(_ error: String?) -> Bool {
        (error ?? "").contains("401")
    }

    @objc(notFoundError:)
    static func notFoundError(_ error: String?) -> Bool {
        (error ?? "").contains("404")
    }

    @objc(windowIsFullScreen:)
    static func windowIsFullScreen(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return MainActor.assumeIsolated {
            window.styleMask.contains(.fullScreen)
        }
    }

    @objc(openExternalURLString:)
    static func openExternalURLString(_ urlString: String?) {
        guard let urlString,
              let url = URL(string: urlString),
              url.scheme?.isEmpty == false,
              url.host?.isEmpty == false,
              NSWorkspace.shared.open(url)
        else {
            OPNSentry.logErrorMessage("[AppDelegate] Failed to open URL: \(urlString ?? "")")
            NSSound.beep()
            return
        }
    }

    @objc(desktopChromeScaleForHeight:)
    static func desktopChromeScale(forHeight height: CGFloat) -> CGFloat {
        min(1.0, max(0.80, max(1.0, height) / 900.0))
    }

    private static func currentMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    private static func formatHours(_ hours: Double) -> String {
        let safeHours = hours.isFinite && hours >= 0 ? hours : 0
        let totalMinutes = max(0, Int((safeHours * 60.0).rounded()))
        return String(format: "%ldh %02ldm", totalMinutes / 60, totalMinutes % 60)
    }

    private static func stringValue(_ object: NSObject?, key: String) -> String {
        object?.value(forKey: key) as? String ?? ""
    }

    private static func int64Value(_ object: NSObject?, key: String) -> Int64 {
        if let number = object?.value(forKey: key) as? NSNumber { return number.int64Value }
        return 0
    }

    private static func doubleValue(_ object: NSObject?, key: String) -> Double {
        if let number = object?.value(forKey: key) as? NSNumber { return number.doubleValue }
        return 0
    }

    private static func boolValue(_ object: NSObject?, key: String) -> Bool {
        if let number = object?.value(forKey: key) as? NSNumber { return number.boolValue }
        return false
    }
}
