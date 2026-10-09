//  Region mode's frozen frame, and the drag that selects an area of it.
//

import CoreGraphics
import SwiftUI

/// Puts the frozen frame on screen for as long as one is held. Its own view so it observes the
/// clipboard controller directly, rather than the stream model.
struct StreamRegionCapturePresenter: View {
    let model: NativeNVSTHostViewModel
    @ObservedObject var clipboard: StreamClipboardController

    var body: some View {
        if let regionCapture = clipboard.regionCapture {
            StreamRegionCaptureOverlay(
                regionCapture: regionCapture,
                onCommit: { model.completeRegionCapture($0) },
                onCancel: { model.cancelRegionCapture() }
            )
            .opnTransition(.opacity)
        }
    }
}

/// The freeze-frame and its drag-to-select rectangle, the stream's take on ⌘⇧4.
struct StreamRegionCaptureOverlay: View {
    let regionCapture: StreamRegionCapture
    let onCommit: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var dragStartPoint: CGPoint?
    @State private var dragEndPoint: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let fittedFrame = StreamRegionCaptureGeometry.fittedRect(imageSize: regionCapture.imageSize, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.62)
                    .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                Image(decorative: regionCapture.image.cgImage, scale: 1)
                    .resizable()
                    .frame(width: fittedFrame.width, height: fittedFrame.height)
                    .position(x: fittedFrame.midX, y: fittedFrame.midY)
                selectionRect(in: fittedFrame)
                instructions
            }
            .contentShape(Rectangle())
            .gesture(selectionGesture(in: fittedFrame))
        }
        .onExitCommand(perform: onCancel)
    }

    @ViewBuilder private func selectionRect(in fittedFrame: CGRect) -> some View {
        if let rect = liveRect(in: fittedFrame) {
            Rectangle()
                .fill(StreamHUDTheme.accent.opacity(0.18))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            Rectangle()
                .stroke(StreamHUDTheme.accent, lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    private func selectionGesture(in fittedFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartPoint == nil { dragStartPoint = value.startLocation }
                dragEndPoint = value.location
            }
            .onEnded { value in
                let startPoint = dragStartPoint ?? value.startLocation
                dragStartPoint = nil
                dragEndPoint = nil
                guard let visionRect = StreamRegionCaptureGeometry.visionRect(dragStart: startPoint, dragEnd: value.location, in: fittedFrame) else {
                    onCancel()
                    return
                }
                onCommit(visionRect)
            }
    }

    /// The rectangle being dragged, clamped to the picture.
    private func liveRect(in fittedFrame: CGRect) -> CGRect? {
        guard let dragStartPoint, let dragEndPoint else { return nil }
        let draggedRect = CGRect(
            x: min(dragStartPoint.x, dragEndPoint.x),
            y: min(dragStartPoint.y, dragEndPoint.y),
            width: abs(dragEndPoint.x - dragStartPoint.x),
            height: abs(dragEndPoint.y - dragStartPoint.y)
        ).intersection(fittedFrame)
        return draggedRect.isNull || draggedRect.isEmpty ? nil : draggedRect
    }

    private var instructions: some View {
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
                    .background(OPNCornerShape(role: .control).fill(Color.white.opacity(0.08)))
                    .overlay { OPNCornerShape(role: .control).strokeBorder(StreamHUDTheme.divider, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(OPNCornerShape(role: .control).fill(Color.black.opacity(0.86)))
        .overlay { OPNCornerShape(role: .control).strokeBorder(StreamHUDTheme.accent.opacity(0.55), lineWidth: 1) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 24)
    }
}
