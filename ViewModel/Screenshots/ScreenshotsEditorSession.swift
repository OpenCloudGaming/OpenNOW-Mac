import Foundation

extension ScreenshotsViewModel {
    func startEditing(_ screenshot: StreamScreenshot) {
        guard editorViewModel == nil else { return }
        selectedScreenshot = screenshot
        editorViewModel = ScreenshotEditorViewModel(screenshot: screenshot)
    }

    func closeEditor() {
        editorSaveTask?.cancel()
        editorSaveTask = nil
        editorViewModel = nil
    }

    func startEditorSave() {
        guard let editor = editorViewModel, editor.canSave, editorSaveTask == nil else { return }
        editorSaveTask = Task { [weak self] in
            do {
                let screenshot = try await editor.save()
                guard let self, self.editorViewModel === editor else { return }
                self.editorSaveTask = nil
                self.editedScreenshotSaved(screenshot)
            } catch is CancellationError {
                guard let self, self.editorViewModel === editor else { return }
                self.editorSaveTask = nil
            } catch {
                guard let self, self.editorViewModel === editor else { return }
                self.editorSaveTask = nil
                editor.errorMessage = error.localizedDescription
            }
        }
    }

}
