//  A crop rectangle you drag on the video, instead of four sliders labelled X, Y, W and H.
//
//  While it is up the preview shows the *original* frame - no crop, no rotation, no flips - because
//  the preview otherwise shows the cropped result and you would be cropping a crop. That also keeps
//  the mapping here one-to-one: no rotation to invert, no mirrored axis to reason about.
//

import SwiftUI

struct RecordingCropOverlay: View {
    @ObservedObject var viewModel: RecordingEditorViewModel
    let uiScale: CGFloat

    @State private var dragBase: NormalizedCrop?

    private struct NormalizedCrop {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    private enum Corner: CaseIterable {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing
    }

    /// Crop fractions are the smallest the exporter will accept, and match the sliders.
    private static let minimumSize = 0.1

    var body: some View {
        GeometryReader { proxy in
            let video = videoRect(in: proxy.size)
            let crop = cropRect(in: video)
            ZStack(alignment: .topLeading) {
                // Everything outside the crop, dimmed. Four rectangles rather than an even-odd
                // path so the crop stays hit-testable underneath.
                Color.black.opacity(0.55)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .mask {
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                            Rectangle()
                                .frame(width: crop.width, height: crop.height)
                                .offset(x: crop.minX, y: crop.minY)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .allowsHitTesting(false)

                thirdsGuides(crop: crop)

                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: crop.width, height: crop.height)
                    .overlay { Rectangle().stroke(OpenNOWDesign.accent, lineWidth: 1.5) }
                    .offset(x: crop.minX, y: crop.minY)
                    .gesture(moveGesture(video: video))
                    .focusable()
                    .accessibilityLabel("Crop area")
                    .accessibilityValue(viewModel.croppedOutputDescription)
                    .accessibilityHint("Arrow keys move it. Hold Option to resize.")
                    // The overlay is the only way to set a crop that is not one of the five
                    // presets, and dragging is the only way to drive it. Keyboard equivalents keep
                    // arbitrary crops reachable without a pointer.
                    .accessibilityAdjustableAction { direction in
                        let step = RecordingEditorViewModel.cropNudgeStep
                        switch direction {
                        case .increment: viewModel.resizeCrop(dWidth: step, dHeight: step)
                        case .decrement: viewModel.resizeCrop(dWidth: -step, dHeight: -step)
                        @unknown default: break
                        }
                    }
                    .onMoveCommand { direction in
                        let step = RecordingEditorViewModel.cropNudgeStep
                        switch direction {
                        case .left: viewModel.nudgeCrop(dx: -step, dy: 0)
                        case .right: viewModel.nudgeCrop(dx: step, dy: 0)
                        // `cropY` is measured from the bottom, so up is positive.
                        case .up: viewModel.nudgeCrop(dx: 0, dy: step)
                        case .down: viewModel.nudgeCrop(dx: 0, dy: -step)
                        @unknown default: break
                        }
                    }

                ForEach(Corner.allCases, id: \.self) { corner in
                    handle(corner: corner, crop: crop, video: video)
                }

                sizeBadge(crop: crop)
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: - Chrome

    private func thirdsGuides(crop: CGRect) -> some View {
        Path { path in
            for index in 1...2 {
                let x = crop.minX + crop.width * CGFloat(index) / 3
                path.move(to: CGPoint(x: x, y: crop.minY))
                path.addLine(to: CGPoint(x: x, y: crop.maxY))
                let y = crop.minY + crop.height * CGFloat(index) / 3
                path.move(to: CGPoint(x: crop.minX, y: y))
                path.addLine(to: CGPoint(x: crop.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.24), lineWidth: 1)
        .allowsHitTesting(false)
    }

    private func sizeBadge(crop: CGRect) -> some View {
        Text(viewModel.croppedOutputDescription)
            .font(.recordingsFont(size: 10 * uiScale, weight: .bold))
            .foregroundStyle(.black.opacity(0.86))
            .padding(.horizontal, 6 * uiScale)
            .frame(height: 18 * uiScale)
            .background(OpenNOWDesign.accent)
            .offset(x: crop.minX, y: max(0, crop.minY - 22 * uiScale))
            .allowsHitTesting(false)
    }

    private func handle(corner: Corner, crop: CGRect, video: CGRect) -> some View {
        let size = 14 * uiScale
        let point = position(of: corner, in: crop)
        return Rectangle()
            .fill(OpenNOWDesign.accent)
            .overlay { Rectangle().stroke(Color.black.opacity(0.45), lineWidth: 1) }
            .frame(width: size, height: size)
            .offset(x: point.x - size / 2, y: point.y - size / 2)
            .gesture(resizeGesture(corner: corner, video: video))
            // The rectangle itself is the accessible control; four corner grabs would be four
            // elements saying the same thing.
            .accessibilityHidden(true)
    }

    private func position(of corner: Corner, in crop: CGRect) -> CGPoint {
        switch corner {
        case .topLeading: return CGPoint(x: crop.minX, y: crop.minY)
        case .topTrailing: return CGPoint(x: crop.maxX, y: crop.minY)
        case .bottomLeading: return CGPoint(x: crop.minX, y: crop.maxY)
        case .bottomTrailing: return CGPoint(x: crop.maxX, y: crop.maxY)
        }
    }

    // MARK: - Geometry

    /// The player letterboxes with `resizeAspect`, so the video is not the whole pane and the crop
    /// has to be measured against the picture rather than the view.
    private func videoRect(in size: CGSize) -> CGRect {
        Self.videoRect(in: size, sourceAspect: viewModel.sourceAspect)
    }

    nonisolated static func videoRect(in size: CGSize, sourceAspect: Double) -> CGRect {
        let aspect = CGFloat(sourceAspect)
        guard size.width > 0, size.height > 0, aspect > 0, aspect.isFinite else { return CGRect(origin: .zero, size: size) }
        let fittedHeight = size.width / aspect
        if fittedHeight <= size.height {
            return CGRect(x: 0, y: (size.height - fittedHeight) / 2, width: size.width, height: fittedHeight)
        }
        let fittedWidth = size.height * aspect
        return CGRect(x: (size.width - fittedWidth) / 2, y: 0, width: fittedWidth, height: size.height)
    }

    /// `cropY` is measured from the bottom, the way Core Image's extent is; the view measures from
    /// the top. This is the one place that flip happens.
    private func cropRect(in video: CGRect) -> CGRect {
        Self.cropRect(in: video, x: viewModel.cropX, y: viewModel.cropY, width: viewModel.cropWidth, height: viewModel.cropHeight)
    }

    nonisolated static func cropRect(in video: CGRect, x: Double, y: Double, width: Double, height: Double) -> CGRect {
        CGRect(
            x: video.minX + video.width * x,
            y: video.minY + video.height * (1 - y - height),
            width: video.width * width,
            height: video.height * height
        )
    }

    // MARK: - Gestures

    private func moveGesture(video: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let base = beginDrag()
                let deltaX = Double(value.translation.width / max(video.width, 1))
                let deltaY = Double(value.translation.height / max(video.height, 1))
                viewModel.cropX = clamp(base.x + deltaX, 0, 1 - base.width)
                viewModel.cropY = clamp(base.y - deltaY, 0, 1 - base.height)
            }
            .onEnded { _ in endDrag() }
    }

    private func resizeGesture(corner: Corner, video: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let base = beginDrag()
                let deltaX = Double(value.translation.width / max(video.width, 1))
                let deltaY = Double(value.translation.height / max(video.height, 1))
                switch corner {
                case .topLeading:
                    setLeadingEdge(base: base, delta: deltaX)
                    setTopEdge(base: base, delta: deltaY)
                case .topTrailing:
                    setTrailingEdge(base: base, delta: deltaX)
                    setTopEdge(base: base, delta: deltaY)
                case .bottomLeading:
                    setLeadingEdge(base: base, delta: deltaX)
                    setBottomEdge(base: base, delta: deltaY)
                case .bottomTrailing:
                    setTrailingEdge(base: base, delta: deltaX)
                    setBottomEdge(base: base, delta: deltaY)
                }
            }
            .onEnded { _ in endDrag() }
    }

    private func setLeadingEdge(base: NormalizedCrop, delta: Double) {
        let maximum = base.x + base.width - Self.minimumSize
        let x = clamp(base.x + delta, 0, maximum)
        viewModel.cropX = x
        viewModel.cropWidth = base.x + base.width - x
    }

    private func setTrailingEdge(base: NormalizedCrop, delta: Double) {
        viewModel.cropWidth = clamp(base.width + delta, Self.minimumSize, 1 - base.x)
    }

    /// The view's top edge is the high edge in bottom-origin coordinates, so it moves the height
    /// while `cropY` stays put.
    private func setTopEdge(base: NormalizedCrop, delta: Double) {
        let top = clamp(base.y + base.height - delta, base.y + Self.minimumSize, 1)
        viewModel.cropHeight = top - base.y
    }

    private func setBottomEdge(base: NormalizedCrop, delta: Double) {
        let maximum = base.y + base.height - Self.minimumSize
        let y = clamp(base.y - delta, 0, maximum)
        viewModel.cropY = y
        viewModel.cropHeight = base.y + base.height - y
    }

    /// One undo step per gesture, and every intermediate value measured from where the drag
    /// started rather than from the last frame, so the rectangle cannot drift.
    private func beginDrag() -> NormalizedCrop {
        if let dragBase { return dragBase }
        viewModel.beginInteractiveEdit()
        let base = NormalizedCrop(x: viewModel.cropX, y: viewModel.cropY, width: viewModel.cropWidth, height: viewModel.cropHeight)
        dragBase = base
        return base
    }

    private func endDrag() {
        dragBase = nil
        viewModel.endInteractiveEdit()
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value.isFinite ? value : lower, lower), max(lower, upper))
    }
}


/// Owns the observation of `isAdjustingCrop`.
///
/// The recordings page observes the *reference* to the editor view model, not its contents, so a
/// `viewModel.isAdjustingCrop` test written in that page's body never invalidated it: the overlay
/// appeared whenever something unrelated happened to redraw the page, and otherwise not at all.
struct RecordingCropOverlayHost: View {
    @ObservedObject var viewModel: RecordingEditorViewModel
    let uiScale: CGFloat

    var body: some View {
        if viewModel.isAdjustingCrop {
            RecordingCropOverlay(viewModel: viewModel, uiScale: uiScale)
        }
    }
}
