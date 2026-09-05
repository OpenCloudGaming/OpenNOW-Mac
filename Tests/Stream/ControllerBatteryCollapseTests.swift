import Foundation
import Testing
@testable import OpenNOW

struct ControllerBatteryCollapseTests {
    private func presence(_ id: String, host: UInt64, level: UInt8?, charging: Bool = false, model: SteamControllerModel = .triton) -> SteamControllerHIDMonitor.BatteryPresence {
        .init(deviceID: InputDeviceID(id), hostID: host, model: model, level: level, charging: charging)
    }

    /// A Steam Controller 2 receiver has four pairing slots; one pad lit up several of them over a
    /// session and the HUD grew a battery square per slot.
    @Test func slotsOfOneReceiverReportingOnePadCollapseToOneController() {
        let collapsed = ControllerBatteryInfo.collapsed([
            presence("steam-controller-1", host: 42, level: 80),
            presence("steam-controller-2", host: 42, level: 80),
            presence("steam-controller-3", host: 42, level: 80),
        ])
        #expect(collapsed.count == 1)
        #expect(collapsed[0].level == 80)
        #expect(collapsed[0].name == "Steam Controller 2")
    }

    @Test func differentReadingsUnderOneReceiverAreTwoPads() {
        let collapsed = ControllerBatteryInfo.collapsed([
            presence("steam-controller-1", host: 42, level: 80),
            presence("steam-controller-2", host: 42, level: 35),
        ])
        #expect(collapsed.count == 2)
    }

    @Test func wiredPadsHaveTheirOwnHostAndStaySeparate() {
        let collapsed = ControllerBatteryInfo.collapsed([
            presence("steam-controller-1", host: 1, level: 80, model: .legacy),
            presence("steam-controller-2", host: 2, level: 80, model: .legacy),
        ])
        #expect(collapsed.count == 2)
        #expect(collapsed.allSatisfy { $0.name == "Steam Controller" })
    }
}
