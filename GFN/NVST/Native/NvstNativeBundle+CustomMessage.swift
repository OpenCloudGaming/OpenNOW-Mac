import Foundation

extension NvstNativeBundle {
    /// Parses the seat's custom messages and fans out the one this client acts on. Returns whether
    /// the command was a custom-message carrier, so the main dispatch can stop there.
    func handleCustomMessageCommand(_ command: NvstControlCommand) -> Bool {
        guard NvstDlssStateNotification.isCustomMessage(command) else { return false }
        guard let state = NvstDlssStateNotification.parse(command) else {
            logUnhandledCustomMessage(command)
            return true
        }
        logger?("NVST DLSS state \(state.summary)")
        onDlssState?(state)
        return true
    }

    /// Names a custom message this client does not act on, so it is not dropped silently: the seat
    /// adds types over time, and an unhandled one reads like a message that never arrived.
    private func logUnhandledCustomMessage(_ command: NvstControlCommand) {
        let type = NvstDlssStateNotification.messageType(of: command) ?? "unknown"
        logger?("NVST custom message type=\(type) len=\(command.payload.count)")
    }
}
