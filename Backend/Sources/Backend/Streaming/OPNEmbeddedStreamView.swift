import AppKit
import SwiftUI

public typealias OPNEmbeddedStreamCompletion = @MainActor @Sendable (_ success: Bool, _ message: String, _ report: OPNSessionReportPayload?) -> Void

public struct OPNEmbeddedStreamView: NSViewControllerRepresentable {
    public typealias NSViewControllerType = NSViewController

    private let configuration: OPNStreamLaunchConfiguration
    private let onEnd: OPNEmbeddedStreamCompletion

    public init(configuration: OPNStreamLaunchConfiguration, onEnd: @escaping OPNEmbeddedStreamCompletion) {
        self.configuration = configuration
        self.onEnd = onEnd
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onEnd: onEnd)
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
        context.coordinator.controller = controller
        return controller
    }

    public func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        guard let controller = nsViewController as? OPNStreamViewController else { return }
        controller.setInitialViewFrame(nsViewController.view.bounds)
    }

    public static func dismantleNSViewController(_ nsViewController: NSViewController, coordinator: Coordinator) {
        guard let controller = nsViewController as? OPNStreamViewController else { return }
        controller.shutdownForApplicationTermination()
    }

    public final class Coordinator {
        fileprivate var controller: OPNStreamViewController?
        fileprivate let onEnd: OPNEmbeddedStreamCompletion

        fileprivate init(onEnd: @escaping OPNEmbeddedStreamCompletion) {
            self.onEnd = onEnd
        }
    }
}
