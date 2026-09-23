//  The two selectors that shape the floating statistics overlay - how much detail it draws and
//  which corner it occupies. Shared by both stream HUDs' STATS panels so the rows read identically
//  and a change to one is a change to both.
//

import SwiftUI

struct StreamStatsHUDShapeControls: View {
    let detailLevel: StreamStatsDetailLevel
    let position: StreamStatsHUDPosition
    let focusedControlID: String?
    let onSelectDetail: (StreamStatsDetailLevel) -> Void
    let onSelectPosition: (StreamStatsHUDPosition) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StreamHUDDropdown(
                label: "Detail",
                options: StreamStatsDetailLevel.allCases.map { ($0.pickerValue, $0.title) },
                selection: detailLevel.pickerValue,
                isDisabled: false,
                onSelect: { onSelectDetail(.pickerCase(at: $0)) },
                isFocused: focusedControlID == "stats-detail"
            )
            StreamHUDDropdown(
                label: "Position",
                options: StreamStatsHUDPosition.allCases.map { ($0.pickerValue, $0.title) },
                selection: position.pickerValue,
                isDisabled: false,
                onSelect: { onSelectPosition(.pickerCase(at: $0)) },
                isFocused: focusedControlID == "stats-position"
            )
        }
    }
}
