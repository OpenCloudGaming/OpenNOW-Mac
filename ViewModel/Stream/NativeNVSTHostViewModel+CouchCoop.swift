import Foundation

@MainActor
extension NativeNVSTHostViewModel {
    static let couchCoopSwapFocusID = "controller-swap"
    static let couchCoopPadAssignFocusPrefix = "coop-pad-assign-"
    static let couchCoopPadIdentifyFocusPrefix = "coop-pad-identify-"
    static let couchCoopPressPollInterval: Duration = .milliseconds(100)

    var showsCouchCoopControllers: Bool {
        isCouchCoopActive && !couchCoopPads.isEmpty
    }

    static func couchCoopPadGroup(for pad: OPNCouchCoopPad) -> String {
        "coop-pad-\(pad.descriptor)"
    }

    var couchCoopControllerFocusEntries: [StreamHUDFocusEntry] {
        guard isCouchCoopActive else { return [] }
        let swap = StreamHUDFocusEntry(id: Self.couchCoopSwapFocusID, isDisabled: couchCoopPads.isEmpty, group: "controllers", columns: 4) { [weak self] in
            self?.swapCouchCoopPlayers()
        }
        return [swap] + couchCoopPads.flatMap(couchCoopPadFocusEntries)
    }

    private func couchCoopPadFocusEntries(for pad: OPNCouchCoopPad) -> [StreamHUDFocusEntry] {
        let group = Self.couchCoopPadGroup(for: pad)
        return [
            StreamHUDFocusEntry(id: Self.couchCoopPadAssignFocusPrefix + pad.descriptor, isDisabled: false, group: group, columns: 2) { [weak self] in
                self?.cycleCouchCoopPad(pad.descriptor)
            },
            StreamHUDFocusEntry(id: Self.couchCoopPadIdentifyFocusPrefix + pad.descriptor, isDisabled: false, group: group, columns: 2) { [weak self] in
                self?.identifyCouchCoopPad(pad.descriptor)
            },
        ]
    }

    func refreshCouchCoopControllers() {
        let coordinator = OPNCouchCoopControllerCoordinator.shared
        let active = coordinator.isActive
        if isCouchCoopActive != active { isCouchCoopActive = active }
        let pads = active ? coordinator.pads : []
        if couchCoopPads != pads { couchCoopPads = pads }
        if !active, !couchCoopPressedPads.isEmpty { couchCoopPressedPads = [] }
    }

    func pollCouchCoopPresses() async {
        while !Task.isCancelled {
            refreshCouchCoopControllers()
            if unifiedHUDVisible, isCouchCoopActive {
                let pressed = OPNCouchCoopControllerCoordinator.shared.pressedDescriptors()
                if pressed != couchCoopPressedPads { couchCoopPressedPads = pressed }
            } else if !couchCoopPressedPads.isEmpty {
                couchCoopPressedPads = []
            }
            try? await Task.sleep(for: Self.couchCoopPressPollInterval)
        }
    }

    func swapCouchCoopPlayers() {
        OPNCouchCoopControllerCoordinator.shared.swapPlayers()
    }

    func cycleCouchCoopPad(_ descriptor: String) {
        OPNCouchCoopControllerCoordinator.shared.cycleTarget(of: descriptor)
    }

    func identifyCouchCoopPad(_ descriptor: String) {
        OPNCouchCoopControllerCoordinator.shared.identify(descriptor)
    }
}
