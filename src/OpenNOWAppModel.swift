import Foundation
import Observation

enum OpenNOWRoute: Equatable, Sendable {
    case signIn
    case authenticating(message: String)
    case store
    case library
    case settings(section: String?)
    case stream(StreamRoute)
    case error(OpenNOWErrorRoute)
}

struct StreamRoute: Equatable, Sendable {
    var title: String
    var appId: String
    var returnRoute: OpenNOWRoute.ReturnDestination
}

struct OpenNOWErrorRoute: Equatable, Sendable {
    var title: String
    var message: String
    var canRetry: Bool
    var retryRoute: OpenNOWRoute.ReturnDestination
}

extension OpenNOWRoute {
    enum ReturnDestination: Equatable, Sendable {
        case signIn
        case store
        case library
        case settings
    }
}

@MainActor
@Observable
final class OpenNOWAppModel {
    var route: OpenNOWRoute = .authenticating(message: "Starting OpenNOW...")
    var currentSession = OPNAuthSession()
    var isStreamActive = false
    var activeStreamTitle = ""

    func showSignIn() {
        route = .signIn
    }

    func showAuthenticating(message: String) {
        route = .authenticating(message: message.isEmpty ? "Authenticating..." : message)
    }

    func showStore() {
        route = .store
    }

    func showLibrary() {
        route = .library
    }

    func showSettings(section: String? = nil) {
        route = .settings(section: section)
    }

    func showError(title: String, message: String, canRetry: Bool, retryRoute: OpenNOWRoute.ReturnDestination = .signIn) {
        route = .error(OpenNOWErrorRoute(title: title, message: message, canRetry: canRetry, retryRoute: retryRoute))
    }

    func startStream(title: String, appId: String, returnRoute: OpenNOWRoute.ReturnDestination) {
        isStreamActive = true
        activeStreamTitle = title.isEmpty ? "Current Stream" : title
        route = .stream(StreamRoute(title: activeStreamTitle, appId: appId, returnRoute: returnRoute))
    }

    func endStream(success: Bool, errorMessage: String = "", returnRoute: OpenNOWRoute.ReturnDestination = .store) {
        isStreamActive = false
        activeStreamTitle = ""
        if success || errorMessage.isEmpty {
            navigate(to: returnRoute)
        } else {
            showError(title: "Stream Error", message: errorMessage, canRetry: true, retryRoute: returnRoute)
        }
    }

    func navigate(to destination: OpenNOWRoute.ReturnDestination) {
        switch destination {
        case .signIn:
            showSignIn()
        case .store:
            showStore()
        case .library:
            showLibrary()
        case .settings:
            showSettings()
        }
    }
}
