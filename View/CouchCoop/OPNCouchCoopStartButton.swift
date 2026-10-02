import SwiftUI

struct OPNCouchCoopStartButton: View {
    @AppStorage(OPNLabs.couchCoop.storageKey) private var isCouchCoopEnabled = false
    @ObservedObject private var presence = OPNCouchCoopPresence.shared

    var body: some View {
        if isCouchCoopEnabled {
            Button("Start Couch Co-op") {
                OPNCouchCoopLauncher.startSecondInstance()
            }
            .disabled(!OPNCouchCoopLauncher.canStart(isFlagEnabled: isCouchCoopEnabled, occupied: occupiedInstanceNumbers))
        }
    }

    private var occupiedInstanceNumbers: [Int] {
        Array(Set(presence.roster.instanceNumbers + [OPNAppInstance.current.number]))
    }
}
