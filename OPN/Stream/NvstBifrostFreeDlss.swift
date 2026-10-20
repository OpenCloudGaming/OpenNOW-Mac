import Foundation

/// The seat's applied DLSS state, delivered on the main actor because the surfaces that read it —
/// the stats HUD and the settings card's status line — live there.
public typealias StreamDlssStateHandler = @MainActor @Sendable (NvstDlssStateNotification) -> Void

extension NvstBifrostFreeTransport {
    public func setDlssStateHandler(_ handler: StreamDlssStateHandler?) {
        onDlssStateChanged = handler
    }

    /// The seat's applied DLSS override state, for the HUD and the log. The seat only speaks when
    /// the state changes, and the first message of a session is usually the all-zero one.
    func handleDlssState(_ notification: NvstDlssStateNotification) {
        lastDlssState = notification
        guard let notify = onDlssStateChanged else { return }
        Task { @MainActor in notify(notification) }
    }
}
