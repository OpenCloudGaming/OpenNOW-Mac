//  The floating statistics overlay's shape: how much detail it draws and which corner it occupies.
//  The shortcut and the CONTROLS tile only toggle the overlay on and off, so re-showing it always
//  brings back the level and corner chosen here.
//

import Foundation

@MainActor
extension NativeNVSTHostViewModel {

    func setNativeStatsDetail(_ level: StreamStatsDetailLevel) {
        guard statsDetail != level else { return }
        statsDetail = level
        OPNStreamStatsHUDSettings.detailLevel = level
        OPNStreamTelemetry.capture("nvst.ui.stats.detail", level: .info, message: "Native NVST stats detail changed.", attributes: ["applicationID": configuration.applicationID, "detail": level.rawValue])
    }

    func setNativeStatsPosition(_ position: StreamStatsHUDPosition) {
        guard statsPosition != position else { return }
        statsPosition = position
        OPNStreamStatsHUDSettings.position = position
        OPNStreamTelemetry.capture("nvst.ui.stats.position", level: .info, message: "Native NVST stats position changed.", attributes: ["applicationID": configuration.applicationID, "position": position.rawValue])
    }

    func cycleNativeStatsDetail() {
        setNativeStatsDetail(StreamStatsDetailLevel.allCases.wrappingNext(after: statsDetail))
    }

    func cycleNativeStatsPosition() {
        setNativeStatsPosition(StreamStatsHUDPosition.allCases.wrappingNext(after: statsPosition))
    }
}
