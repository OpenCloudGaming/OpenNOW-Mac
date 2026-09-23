//  The unified HUD's STATS panel: how much detail the floating statistics overlay draws and which
//  corner it occupies. The overlay's on/off toggle stays on the CONTROLS tile and the shortcut.
//

import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    var nativeHUDStatsPanel: some View {
        StreamHUDSection(label: "STATS") {
            StreamStatsHUDShapeControls(
                detailLevel: model.statsDetail,
                position: model.statsPosition,
                focusedControlID: model.hudFocusID,
                onSelectDetail: { model.setNativeStatsDetail($0) },
                onSelectPosition: { model.setNativeStatsPosition($0) }
            )
        }
    }
}
