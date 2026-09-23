import SwiftUI

struct ScreenshotSelectionOverlay: View {
    @Bindable var model: ScreenshotEditorViewModel
    @Environment(\.opnUIScale) private var uiScale
    @FocusState private var isFocused: Bool
    @State private var drag: SelectionDrag?

    private struct SelectionDrag {
        enum Operation {
            case draw
            case move(CGRect)
            case resize(CGRect, ScreenshotSelectionHandle)
        }

        let operation: Operation
    }

    var body: some View {
        selectionActions(describedSelection(interactionSurface))
    }

    private var interactionSurface: some View {
        GeometryReader { proxy in
            let imageFrame = ScreenshotSelectionGeometry.imageFrame(in: proxy.size, imageSize: model.imageSize)
            ZStack(alignment: .topLeading) {
                Color.clear
                if let selection = model.selection {
                    selectionChrome(ScreenshotSelectionGeometry.displayRectangle(selection, imageFrame: imageFrame, imageSize: model.imageSize), imageFrame: imageFrame)
                }
            }
            .contentShape(Rectangle())
            .gesture(selectionGesture(imageFrame: imageFrame))
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .opnTakingFocus($isFocused, while: model.isReady)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat], action: handleArrow)
        .onChange(of: model.imageSize) { drag = nil }
        .allowsHitTesting(model.isReady)
    }

    private func describedSelection(_ surface: some View) -> some View {
        surface
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Screenshot selection"))
            .accessibilityValue(Text(model.selection == nil ? "No selection" : model.dimensionsDescription))
            .accessibilityHint(Text("Drag to select. Arrow keys move the selection. Option and arrow keys resize it. Shift uses ten-pixel steps."))
    }

    private func selectionActions(_ view: some View) -> some View {
        view
            .accessibilityAction(named: Text("Select All")) { model.selectAll() }
            .accessibilityAction(named: Text("Clear Selection")) { model.clearSelection() }
            .accessibilityAction(named: Text("Crop")) { model.applyCrop() }
            .accessibilityAction(named: Text("Move Left")) { model.moveSelection(by: CGSize(width: -1, height: 0)) }
            .accessibilityAction(named: Text("Move Right")) { model.moveSelection(by: CGSize(width: 1, height: 0)) }
            .accessibilityAction(named: Text("Move Up")) { model.moveSelection(by: CGSize(width: 0, height: -1)) }
            .accessibilityAction(named: Text("Move Down")) { model.moveSelection(by: CGSize(width: 0, height: 1)) }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.resizeSelection(by: CGSize(width: 1, height: 1))
                case .decrement: model.resizeSelection(by: CGSize(width: -1, height: -1))
                @unknown default: break
                }
            }
    }

    private func selectionChrome(_ rectangle: CGRect, imageFrame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(imageFrame)
                path.addRect(rectangle)
            }
            .fill(OPNDesign.Surface.scrim, style: FillStyle(eoFill: true))
            thirdsGuides(in: rectangle)
                .stroke(OPNDesign.Stroke.strong, lineWidth: 1)
            Rectangle()
                .strokeBorder(OPNDesign.accent, lineWidth: 1.5)
                .frame(width: rectangle.width, height: rectangle.height)
                .offset(x: rectangle.minX, y: rectangle.minY)
            ForEach(ScreenshotSelectionHandle.allCases, id: \.self) { handle in
                Rectangle()
                    .fill(OPNDesign.accent)
                    .overlay { Rectangle().strokeBorder(OPNDesign.onAccent.opacity(0.5), lineWidth: 1) }
                    .frame(width: 10 * uiScale, height: 10 * uiScale)
                    .position(handle.position(in: rectangle))
            }
        }
        .allowsHitTesting(false)
    }

    private func thirdsGuides(in rectangle: CGRect) -> Path {
        Path { path in
            for index in 1...2 {
                let fraction = CGFloat(index) / 3
                let x = rectangle.minX + rectangle.width * fraction
                let y = rectangle.minY + rectangle.height * fraction
                path.move(to: CGPoint(x: x, y: rectangle.minY))
                path.addLine(to: CGPoint(x: x, y: rectangle.maxY))
                path.move(to: CGPoint(x: rectangle.minX, y: y))
                path.addLine(to: CGPoint(x: rectangle.maxX, y: y))
            }
        }
    }

    private func selectionGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1 * uiScale)
            .onChanged { value in
                guard model.isReady else { return }
                guard let operation = drag?.operation ?? operation(at: value.startLocation, imageFrame: imageFrame) else { return }
                if drag == nil {
                    model.beginSelectionChange()
                    drag = SelectionDrag(operation: operation)
                }
                updateSelection(for: operation, value: value, imageFrame: imageFrame)
            }
            .onEnded { _ in
                model.endSelectionChange()
                drag = nil
            }
    }

    private func operation(at point: CGPoint, imageFrame: CGRect) -> SelectionDrag.Operation? {
        guard let selection = model.selection else {
            return imageFrame.contains(point) ? .draw : nil
        }
        let rectangle = ScreenshotSelectionGeometry.displayRectangle(selection, imageFrame: imageFrame, imageSize: model.imageSize)
        let hitRadius = 10 * uiScale
        let handle = ScreenshotSelectionHandle.allCases.first { handle in
            let position = handle.position(in: rectangle)
            return abs(position.x - point.x) <= hitRadius && abs(position.y - point.y) <= hitRadius
        }
        if let handle { return .resize(selection, handle) }
        if rectangle.contains(point) { return .move(selection) }
        return imageFrame.contains(point) ? .draw : nil
    }

    private func updateSelection(for operation: SelectionDrag.Operation, value: DragGesture.Value, imageFrame: CGRect) {
        let translation = ScreenshotSelectionGeometry.pixelTranslation(value.translation, imageFrame: imageFrame, imageSize: model.imageSize)
        switch operation {
        case .draw:
            model.updateSelection(ScreenshotSelectionGeometry.selection(from: value.startLocation, to: value.location, imageFrame: imageFrame, imageSize: model.imageSize))
        case .move(let selection):
            model.updateSelection(ScreenshotSelectionGeometry.moved(selection, by: translation, imageSize: model.imageSize))
        case .resize(let selection, let handle):
            model.updateSelection(ScreenshotSelectionGeometry.resized(selection, handle: handle, by: translation, imageSize: model.imageSize))
        }
    }

    private func handleArrow(_ press: KeyPress) -> KeyPress.Result {
        guard model.isReady, model.selection != nil, !press.modifiers.contains(.command) else { return .ignored }
        let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
        let translation: CGSize
        switch press.key {
        case .leftArrow: translation = CGSize(width: -step, height: 0)
        case .rightArrow: translation = CGSize(width: step, height: 0)
        case .upArrow: translation = CGSize(width: 0, height: -step)
        case .downArrow: translation = CGSize(width: 0, height: step)
        default: return .ignored
        }
        if press.modifiers.contains(.option) {
            model.resizeSelection(by: translation)
            return .handled
        }
        model.moveSelection(by: translation)
        return .handled
    }
}
