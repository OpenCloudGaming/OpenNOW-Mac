import CoreGraphics
import Foundation
import Observation

@MainActor @Observable
final class ScreenshotEditorViewModel {
    let screenshot: StreamScreenshot
    private(set) var previewImage: StreamScreenshotImage?
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorMessage: String?

    private struct EditState: Equatable {
        var crop: CGRect
        var selection: CGRect?
    }

    private var state = EditState(crop: .zero)
    private var undoHistory: [EditState] = []
    private var redoHistory: [EditState] = []
    @ObservationIgnored private var sourceImage: StreamScreenshotImage?
    @ObservationIgnored private var interactionStart: EditState?

    init(screenshot: StreamScreenshot) {
        self.screenshot = screenshot
    }

    var selection: CGRect? { state.selection }
    var crop: CGRect { state.crop }
    var imageSize: CGSize { state.crop.size }
    var isReady: Bool { previewImage != nil && !isLoading && !isSaving }
    var canUndo: Bool { isReady && !undoHistory.isEmpty }
    var canRedo: Bool { isReady && !redoHistory.isEmpty }
    var isEdited: Bool { sourceImage != nil && state.crop != originalBounds }
    var canReset: Bool { isReady && (isEdited || selection != nil) }
    var canSave: Bool { isReady && isEdited && selection == nil }

    var canCrop: Bool {
        isReady && selection != nil && selection != CGRect(origin: .zero, size: imageSize)
    }

    var dimensionsDescription: String {
        let size = selection?.size ?? imageSize
        return "\(Int(size.width)) × \(Int(size.height)) px"
    }

    private var originalBounds: CGRect {
        guard let sourceImage else { return .zero }
        return CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
    }

    func load() async {
        guard sourceImage == nil, !isLoading, !Task.isCancelled else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let screenshot = screenshot
        let task = Task.detached(priority: .userInitiated) { try StreamScreenshotLibrary.loadImage(for: screenshot) }
        do {
            let image = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            sourceImage = image
            previewImage = image
            state = EditState(crop: originalBounds)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginSelectionChange() {
        guard isReady, interactionStart == nil else { return }
        interactionStart = state
    }

    func updateSelection(_ rectangle: CGRect?) {
        guard isReady else { return }
        state.selection = rectangle.flatMap { ScreenshotSelectionGeometry.bounded($0, imageSize: imageSize) }
        errorMessage = nil
    }

    func endSelectionChange() {
        guard let previous = interactionStart else { return }
        interactionStart = nil
        recordUndo(previous)
    }

    func selectAll() {
        guard isReady else { return }
        beginSelectionChange()
        updateSelection(CGRect(origin: .zero, size: imageSize))
        endSelectionChange()
    }

    func clearSelection() {
        guard isReady else { return }
        beginSelectionChange()
        updateSelection(nil)
        endSelectionChange()
    }

    func moveSelection(by translation: CGSize) {
        guard isReady, let selection else { return }
        beginSelectionChange()
        updateSelection(ScreenshotSelectionGeometry.moved(selection, by: translation, imageSize: imageSize))
        endSelectionChange()
    }

    func resizeSelection(by translation: CGSize) {
        guard isReady, let selection else { return }
        beginSelectionChange()
        updateSelection(ScreenshotSelectionGeometry.resized(selection, handle: .bottomTrailing, by: translation, imageSize: imageSize))
        endSelectionChange()
    }

    func applyCrop() {
        guard canCrop, let selection else { return }
        endSelectionChange()
        let previous = state
        let next = selection.offsetBy(dx: state.crop.minX, dy: state.crop.minY)
        guard updatePreview(crop: next) else { return }
        state = EditState(crop: next)
        recordUndo(previous)
    }

    func undo() {
        guard canUndo else { return }
        endSelectionChange()
        guard let previous = undoHistory.last, updatePreview(crop: previous.crop) else { return }
        undoHistory.removeLast()
        redoHistory.append(state)
        state = previous
    }

    func redo() {
        guard canRedo, let next = redoHistory.last, updatePreview(crop: next.crop) else { return }
        interactionStart = nil
        redoHistory.removeLast()
        undoHistory.append(state)
        state = next
    }

    func reset() {
        guard canReset else { return }
        endSelectionChange()
        let previous = state
        guard updatePreview(crop: originalBounds) else { return }
        state = EditState(crop: originalBounds)
        recordUndo(previous)
    }

    func save() async throws -> StreamScreenshot {
        try Task.checkCancellation()
        guard canSave, let sourceImage else { throw StreamScreenshotLibraryError.invalidCrop }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let screenshot = screenshot
        let crop = state.crop
        let task = Task.detached(priority: .userInitiated) {
            try StreamScreenshotLibrary.saveCroppedScreenshot(screenshot, image: sourceImage, crop: crop)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func recordUndo(_ previous: EditState) {
        guard previous != state else { return }
        undoHistory.append(previous)
        if undoHistory.count > 100 { undoHistory.removeFirst() }
        redoHistory.removeAll()
    }

    private func updatePreview(crop: CGRect) -> Bool {
        guard let sourceImage, let image = sourceImage.cgImage.cropping(to: crop) else {
            errorMessage = StreamScreenshotLibraryError.invalidCrop.localizedDescription
            return false
        }
        previewImage = StreamScreenshotImage(cgImage: image)
        errorMessage = nil
        return true
    }
}
