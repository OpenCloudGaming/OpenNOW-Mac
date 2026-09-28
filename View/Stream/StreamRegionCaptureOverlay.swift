//  Region mode's frozen frame: the picture the reader drags over, and the drag itself. Presented over
//  the stream surface for as long as `regionCapture` holds a frame.
//

import CoreGraphics
import SwiftUI

/// Puts the frozen frame on screen for as long as one is held. Its own view so it observes the
/// clipboard controller directly — the frame is taken off the capture path, not off the stream model.
struct StreamRegionCapturePresenter: View {
    let model: NativeNVSTHostViewModel
    @ObservedObject var clipboard: StreamClipboardController

    var body: some View {
        if let capture = clipboard.regionCapture {
            StreamRegionCaptureOverlay(
                capture: capture,
                onCommit: { model.completeRegionCapture($0) },
                onCancel: { model.cancelRegionCapture() }
            )
            .opnTransition(.opacity)
        }
    }
}

/// The freeze-frame and its drag-to-select rectangle, the stream's take on ⌘⇧4.
struct StreamRegionCaptureOverlay: View {
    let capture: StreamRegionCapture
    let onCommit: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let fitted = StreamRegionCaptureGeometry.fittedRect(imageSize: capture.imageSize, in: proxy.size)
            let live = liveRect(in: fitted)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.62)
                    .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                Image(decorative: capture.image.cgImage, scale: 1)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)
                if let live {
                    Rectangle()
                        .fill(StreamHUDTheme.accent.opacity(0.18))
                        .frame(width: live.width, height: live.height)
                        .position(x: live.midX, y: live.midY)
                    Rectangle()
                        .stroke(StreamHUDTheme.accent, lineWidth: 1)
                        .frame(width: live.width, height: live.height)
                        .position(x: live.midX, y: live.midY)
                }
                hint
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation }
                        dragEnd = value.location
                    }
                    .onEnded { value in
                        let start = dragStart ?? value.startLocation
                        dragStart = nil
                        dragEnd = nil
                        guard let rect = StreamRegionCaptureGeometry.visionRect(dragStart: start, dragEnd: value.location, in: fitted) else {
                            onCancel()
                            return
                        }
                        onCommit(rect)
                    }
            )
        }
        .onExitCommand(perform: onCancel)
    }

    /// The rectangle being dragged, in the view's own points, clamped to the picture.
    private func liveRect(in fitted: CGRect) -> CGRect? {
        guard let dragStart, let dragEnd else { return nil }
        let rect = CGRect(
            x: min(dragStart.x, dragEnd.x),
            y: min(dragStart.y, dragEnd.y),
            width: abs(dragEnd.x - dragStart.x),
            height: abs(dragEnd.y - dragStart.y)
        ).intersection(fitted)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    private var hint: some View {
        VStack(spacing: 8) {
            Text("DRAG OVER THE TEXT TO COPY")
                .font(.streamFont(size: 11, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(StreamHUDTheme.accent)
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.streamFont(size: 11, weight: .bold))
                    .foregroundStyle(StreamHUDTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Color.white.opacity(0.08))
                    .overlay { Rectangle().stroke(StreamHUDTheme.divider, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.86))
        .overlay { Rectangle().stroke(StreamHUDTheme.accent.opacity(0.55), lineWidth: 1) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 24)
        .allowsHitTesting(true)
    }
}
