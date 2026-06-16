import AppKit
import SwiftUI

public typealias OPNEmbeddedStreamCompletion = @MainActor @Sendable (_ success: Bool, _ message: String, _ report: OPNSessionReportPayload?) -> Void
public typealias OPNEmbeddedStreamProgressHandler = @MainActor @Sendable (_ progress: OPNEmbeddedStreamProgress) -> Void
public typealias OPNEmbeddedStreamQuitDecisionHandler = @MainActor @Sendable (_ shouldTerminateApplication: Bool) -> Void

@MainActor
public enum OPNEmbeddedStreamLifecycle {
    private static weak var activeController: OPNStreamViewController?

    public static var hasActiveStream: Bool {
        activeController?.canRequestUserQuitDecision == true
    }

    public static func requestApplicationQuitDecision(completion: @escaping OPNEmbeddedStreamQuitDecisionHandler) -> Bool {
        guard let activeController, activeController.canRequestUserQuitDecision else { return false }
        activeController.requestUserQuitDecision(terminateApplicationAfterChoice: true, completion: completion)
        return true
    }

    fileprivate static func activate(_ controller: OPNStreamViewController) {
        activeController = controller
    }

    fileprivate static func deactivate(_ controller: OPNStreamViewController) {
        if activeController === controller {
            activeController = nil
        }
    }
}

public struct OPNEmbeddedStreamProgress: Equatable, Sendable {
    public let title: String
    public let message: String
    public let steps: [String]
    public let currentStepIndex: Int
    public let isReady: Bool

    public init(title: String, message: String, steps: [String], currentStepIndex: Int, isReady: Bool) {
        self.title = title
        self.message = message
        self.steps = steps
        self.currentStepIndex = currentStepIndex
        self.isReady = isReady
    }
}

public struct OPNEmbeddedStreamView: NSViewControllerRepresentable {
    public typealias NSViewControllerType = NSViewController

    private let configuration: OPNStreamLaunchConfiguration
    private let onEnd: OPNEmbeddedStreamCompletion
    private let onProgress: OPNEmbeddedStreamProgressHandler?

    public init(configuration: OPNStreamLaunchConfiguration, onProgress: OPNEmbeddedStreamProgressHandler? = nil, onEnd: @escaping OPNEmbeddedStreamCompletion) {
        self.configuration = configuration
        self.onProgress = onProgress
        self.onEnd = onEnd
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onEnd: onEnd)
    }

    public func makeNSViewController(context: Context) -> NSViewController {
        let controller = OPNStreamViewController(
            gameTitle: configuration.title,
            appId: configuration.appId,
            apiToken: configuration.apiToken,
            accountLinked: configuration.accountLinked,
            selectedStore: configuration.selectedStore,
            resumeSessionId: configuration.resumeSessionId,
            resumeServer: configuration.resumeServer
        )
        controller.onStreamEnd = { success, message, report in
            Task { @MainActor in
                context.coordinator.onEnd(success, message, report)
            }
        }
        controller.onLaunchProgress = { progress in
            Task { @MainActor in
                context.coordinator.onProgress?(progress)
            }
        }
        OPNEmbeddedStreamLifecycle.activate(controller)
        context.coordinator.controller = controller
        return controller
    }

    public func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        guard let controller = nsViewController as? OPNStreamViewController else { return }
        controller.setInitialViewFrame(nsViewController.view.bounds)
    }

    public static func dismantleNSViewController(_ nsViewController: NSViewController, coordinator: Coordinator) {
        guard let controller = nsViewController as? OPNStreamViewController else { return }
        OPNEmbeddedStreamLifecycle.deactivate(controller)
        controller.shutdownForApplicationTermination()
    }

    public final class Coordinator {
        fileprivate var controller: OPNStreamViewController?
        fileprivate let onProgress: OPNEmbeddedStreamProgressHandler?
        fileprivate let onEnd: OPNEmbeddedStreamCompletion

        fileprivate init(onProgress: OPNEmbeddedStreamProgressHandler?, onEnd: @escaping OPNEmbeddedStreamCompletion) {
            self.onProgress = onProgress
            self.onEnd = onEnd
        }
    }
}
