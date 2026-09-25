import Combine
import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    var nativeHUDSessionPanel: some View {
        StreamHUDSection(
            label: OPNStreamHUDSection.session.title,
            spacing: 8,
            isCollapsed: model.isHUDSectionCollapsed(.session),
            isFocused: model.isHUDSectionHeaderFocused(.session),
            reorderPayload: OPNStreamHUDSection.session.rawValue,
            onToggle: { model.toggleHUDSection(.session) }
        ) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    nativeHUDDetailRow(label: "Elapsed", value: StreamSessionElapsedTime.text(since: model.nativeConnectedAt, at: context.date))
                    if let limit = model.sessionLimit {
                        nativeHUDDetailRow(label: "Remaining", value: limit.remainingTimeText(at: context.date))
                        nativeSessionLimitBar(fraction: nativeSessionLimitFraction(for: limit, at: context.date))
                    }
                }
            }
        }
    }

    /// A square consumption bar: the share of the limit still left, warn-coloured near the end.
    func nativeSessionLimitBar(fraction: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.12))
                Rectangle()
                    .fill(fraction > 0.15 ? StreamHUDTheme.accent : StreamHUDTheme.warning)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    func nativeSessionLimitFraction(for limit: StreamSessionSidebarLimit, at date: Date) -> Double {
        guard limit.durationSeconds > 0 else { return 1 }
        return min(max(Double(limit.remainingSeconds(at: date)) / Double(limit.durationSeconds), 0), 1)
    }
}
