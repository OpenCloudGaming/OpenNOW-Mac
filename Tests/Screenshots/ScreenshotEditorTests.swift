import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OpenNOW

@MainActor @Suite(.serialized)
struct ScreenshotEditorTests {
    @Test func aWholeSelectionDragIsOneUndoStep() async throws {
        let fixture = try ScreenshotEditorFixture.make()
        defer { try? fixture.remove() }
        let model = ScreenshotEditorViewModel(screenshot: fixture.screenshot)
        await model.load()
        model.beginSelectionChange()
        for width in 1...30 { model.updateSelection(CGRect(x: 3, y: 4, width: width, height: 20)) }
        model.endSelectionChange()
        #expect(model.canUndo)
        model.undo()
        #expect(model.selection == nil)
        #expect(!model.canUndo)
        model.redo()
        #expect(model.selection == CGRect(x: 3, y: 4, width: 30, height: 20))
    }

    @Test func repeatedCropsKeepTheirOriginalPixelCoordinatesThroughUndo() async throws {
        let fixture = try ScreenshotEditorFixture.make()
        defer { try? fixture.remove() }
        let model = ScreenshotEditorViewModel(screenshot: fixture.screenshot)
        await model.load()
        selectScreenshotArea(CGRect(x: 8, y: 6, width: 40, height: 24), in: model)
        model.applyCrop()
        selectScreenshotArea(CGRect(x: 3, y: 4, width: 20, height: 10), in: model)
        model.applyCrop()
        #expect(model.crop == CGRect(x: 11, y: 10, width: 20, height: 10))
        #expect(model.previewImage?.width == 20)
        model.undo()
        #expect(model.crop == CGRect(x: 8, y: 6, width: 40, height: 24))
        #expect(model.selection == CGRect(x: 3, y: 4, width: 20, height: 10))
        model.redo()
        #expect(model.crop == CGRect(x: 11, y: 10, width: 20, height: 10))
        model.reset()
        #expect(model.imageSize == CGSize(width: 64, height: 40))
        #expect(!model.isEdited)
        #expect(!model.canSave)
        model.undo()
        #expect(model.crop == CGRect(x: 11, y: 10, width: 20, height: 10))
    }

    @Test func keyboardSelectionCanReachASinglePixelWithoutLeavingTheImage() async throws {
        let fixture = try ScreenshotEditorFixture.make()
        defer { try? fixture.remove() }
        let model = ScreenshotEditorViewModel(screenshot: fixture.screenshot)
        await model.load()
        model.selectAll()
        #expect(!model.canCrop)
        model.resizeSelection(by: CGSize(width: -1000, height: -1000))
        model.moveSelection(by: CGSize(width: 1000, height: 1000))
        #expect(model.selection == CGRect(x: 63, y: 39, width: 1, height: 1))
        model.applyCrop()
        #expect(model.previewImage?.width == 1)
        #expect(model.previewImage?.height == 1)
    }

    @Test func savingWaitsForAPendingSelectionToBeApplied() async throws {
        let fixture = try ScreenshotEditorFixture.make()
        defer { try? fixture.remove() }
        let model = ScreenshotEditorViewModel(screenshot: fixture.screenshot)
        await model.load()
        selectScreenshotArea(CGRect(x: 4, y: 6, width: 20, height: 20), in: model)
        #expect(!model.canSave)
        model.applyCrop()
        #expect(model.canSave)
        model.selectAll()
        #expect(!model.canSave)
        model.clearSelection()
        #expect(model.canSave)
    }

    @Test func savingCreatesAPixelExactPNGWithTheSourcesAlbums() async throws {
        let fixture = try ScreenshotEditorFixture.make()
        defer { try? fixture.remove() }
        let originalPNG = try Data(contentsOf: fixture.screenshot.imageURL)
        let originalMetadata = try Data(contentsOf: fixture.screenshot.metadataURL)
        let model = ScreenshotEditorViewModel(screenshot: fixture.screenshot)
        await model.load()
        selectScreenshotArea(CGRect(x: 11, y: 7, width: 23, height: 19), in: model)
        model.applyCrop()
        let saved = try await model.save()
        #expect(saved.id != fixture.screenshot.id)
        #expect(saved.width == 23 && saved.height == 19)
        #expect(saved.applicationID == fixture.screenshot.applicationID)
        #expect(saved.albumIDs == fixture.screenshot.albumIDs)
        #expect(saved.fileSizeBytes == Int64(try Data(contentsOf: saved.imageURL).count))
        let decodedMetadata = try JSONDecoder.recordingDecoder.decode(StreamScreenshot.self, from: Data(contentsOf: saved.metadataURL))
        #expect(decodedMetadata.id == saved.id && decodedMetadata.title == saved.title)
        #expect(decodedMetadata.width == saved.width && decodedMetadata.height == saved.height)
        #expect(decodedMetadata.albumIDs == saved.albumIDs && decodedMetadata.applicationID == saved.applicationID)
        #expect(decodedMetadata.fileSizeBytes == saved.fileSizeBytes && decodedMetadata.imageURL == saved.imageURL)
        #expect(abs(decodedMetadata.createdAt.timeIntervalSince(saved.createdAt)) < 1)
        let bitmap = NSBitmapImageRep(cgImage: try StreamScreenshotLibrary.loadImage(for: saved).cgImage)
        let source = NSBitmapImageRep(cgImage: try StreamScreenshotLibrary.loadImage(for: fixture.screenshot).cgImage)
        expectPixel(in: bitmap, x: 0, y: 0, source: source, sourceX: 11, sourceY: 7)
        expectPixel(in: bitmap, x: 22, y: 18, source: source, sourceX: 33, sourceY: 25)
        #expect(try Data(contentsOf: fixture.screenshot.imageURL) == originalPNG)
        #expect(try Data(contentsOf: fixture.screenshot.metadataURL) == originalMetadata)
    }

    @Test func closingAnEditorDiscardsTheDraftWithoutWritingFiles() async throws {
        let fixture = try ScreenshotEditorFixture.make()
        defer { try? fixture.remove() }
        let library = ScreenshotsViewModel()
        library.startEditing(fixture.screenshot)
        let editor = try #require(library.editorViewModel)
        await editor.load()
        selectScreenshotArea(CGRect(x: 5, y: 5, width: 20, height: 20), in: editor)
        editor.applyCrop()
        library.closeEditor()
        #expect(library.editorViewModel == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).count == 2)
    }

    @Test func aSavedCropBecomesVisibleEvenWhenResolutionFiltersWouldHideIt() async throws {
        let fixture = try ScreenshotEditorFixture.make()
        defer { try? fixture.remove() }
        let library = ScreenshotsViewModel()
        library.screenshots = [fixture.screenshot]
        library.selectedAlbum = .unfiled
        library.searchText = "Missing title"
        library.activeFilters = [.fourK]
        library.startEditing(fixture.screenshot)
        let editor = try #require(library.editorViewModel)
        await editor.load()
        selectScreenshotArea(CGRect(x: 5, y: 5, width: 20, height: 20), in: editor)
        editor.applyCrop()
        library.startEditorSave()
        let saveTask = try #require(library.editorSaveTask)
        await saveTask.value
        let saved = try #require(library.selectedScreenshot)
        #expect(saved.id != fixture.screenshot.id)
        #expect(library.editorViewModel == nil)
        #expect(library.editorSaveTask == nil)
        #expect(library.visibleScreenshots.contains(where: { $0.id == saved.id }))
    }

    @Test func aCancelledSaveLeavesNoPartialCopy() async throws {
        let fixture = try ScreenshotEditorFixture.make()
        defer { try? fixture.remove() }
        let model = ScreenshotEditorViewModel(screenshot: fixture.screenshot)
        await model.load()
        selectScreenshotArea(CGRect(x: 5, y: 5, width: 20, height: 20), in: model)
        model.applyCrop()
        let task = Task { try await model.save() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled save produced a screenshot")
        } catch is CancellationError {
            #expect(!model.isSaving)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).count == 2)
        }
    }

    @Test func unreadableImagesShowAnErrorWithEditingDisabled() async throws {
        let fixture = try ScreenshotEditorFixture.make()
        defer { try? fixture.remove() }
        try Data("invalid PNG".utf8).write(to: fixture.screenshot.imageURL)
        let model = ScreenshotEditorViewModel(screenshot: fixture.screenshot)
        await model.load()
        #expect(model.errorMessage != nil)
        #expect(!model.isLoading)
        #expect(!model.isReady)
        #expect(!model.canCrop && !model.canSave)
    }

    @Test func outOfBoundsExportsAreRejectedBeforeWriting() throws {
        let fixture = try ScreenshotEditorFixture.make()
        defer { try? fixture.remove() }
        let image = try StreamScreenshotLibrary.loadImage(for: fixture.screenshot)
        #expect(throws: StreamScreenshotLibraryError.self) {
            try StreamScreenshotLibrary.saveCroppedScreenshot(fixture.screenshot, image: image, crop: CGRect(x: -10, y: 0, width: 20, height: 10))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).count == 2)
    }

    private func expectPixel(in bitmap: NSBitmapImageRep, x: Int, y: Int, source: NSBitmapImageRep, sourceX: Int, sourceY: Int) {
        var actual = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        var expected = [Int](repeating: 0, count: source.samplesPerPixel)
        bitmap.getPixel(&actual, atX: x, y: y)
        source.getPixel(&expected, atX: sourceX, y: sourceY)
        #expect(actual == expected)
    }
}
