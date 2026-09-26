import Foundation
import Testing
@testable import OpenNOW

/// The one-time move off `NVIDIA/GeForce NOW`. Runs against temporary trees, never a real library.
struct OPNCaptureMigrationTests {
    private func makeStorage() -> OPNAppPreferenceStorage {
        let name = "OpenNOW.CaptureMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        return OPNAppPreferenceStorage(defaults: defaults, defaultsDomain: name)
    }

    private struct Fixture {
        let root: URL
        let storage: OPNAppPreferenceStorage

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureMigration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            storage = {
                let name = "OpenNOW.CaptureMigrationTests.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: name) ?? .standard
                return OPNAppPreferenceStorage(defaults: defaults, defaultsDomain: name)
            }()
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        /// The vendor's own folder for one library, e.g. `.../NVIDIA/screenshots` standing in for
        /// `~/Pictures/NVIDIA/GeForce NOW`.
        func legacy(_ library: OPNCaptureLibrary) -> URL {
            root.appendingPathComponent("NVIDIA", isDirectory: true)
                .appendingPathComponent(library.rawValue, isDirectory: true)
        }

        func destination(_ library: OPNCaptureLibrary) -> URL {
            root.appendingPathComponent("OpenNOW", isDirectory: true)
                .appendingPathComponent(library.rawValue, isDirectory: true)
        }

        func migrate(moveItem: ((URL, URL) throws -> Void)? = nil) -> OPNCaptureMigration.Result {
            OPNCaptureMigration.runMigration(
                storage: storage,
                legacyRoots: { self.legacy($0) },
                destinations: { self.destination($0) },
                moveItem: moveItem ?? { try FileManager.default.moveItem(at: $0, to: $1) }
            )
        }
    }

    private func writeFile(_ url: URL, contents: String = "data") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    @Test func aLegacyTreeMovesWholeAndKeepsItsSidecarsAndAlbums() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let screenshotsLegacy = fixture.legacy(.screenshots)
        try writeFile(screenshotsLegacy.appendingPathComponent("one.png"))
        try writeFile(screenshotsLegacy.appendingPathComponent("one.json"), contents: #"{"storageDirectoryPath":"/nowhere"}"#)
        try writeFile(screenshotsLegacy.appendingPathComponent("albums.json"), contents: "[]")
        try writeFile(fixture.legacy(.recordings).appendingPathComponent("Game/one.mp4"))

        let result = fixture.migrate()

        #expect(result.movedLibraries == [.screenshots, .recordings])
        #expect(result.warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: screenshotsLegacy.path))
        let destination = fixture.destination(.screenshots)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("one.png").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("one.json").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("albums.json").path))
        #expect(FileManager.default.fileExists(atPath: fixture.destination(.recordings).appendingPathComponent("Game/one.mp4").path))
        #expect(fixture.storage.bool(forKey: OPNCaptureMigration.completionMarkerKey))
    }

    @Test func aSecondRunIsANoOp() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try writeFile(fixture.legacy(.screenshots).appendingPathComponent("one.png"))
        #expect(fixture.migrate().movedLibraries == [.screenshots])

        let second = fixture.migrate()
        #expect(second.movedLibraries.isEmpty)
        #expect(!second.isMigrationRun)
    }

    @Test func anExistingDestinationStopsTheMoveAndLeavesTheLegacyTreeAlone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try writeFile(fixture.legacy(.screenshots).appendingPathComponent("one.png"))
        try writeFile(fixture.destination(.screenshots).appendingPathComponent("newer.png"))

        let result = fixture.migrate()

        #expect(result.movedLibraries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.legacy(.screenshots).appendingPathComponent("one.png").path))
        #expect(FileManager.default.fileExists(atPath: fixture.destination(.screenshots).appendingPathComponent("newer.png").path))
        #expect(fixture.storage.bool(forKey: OPNCaptureMigration.completionMarkerKey))
    }

    @Test func aReadersOverrideSkipsTheMoveWithoutMarkingItDone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try writeFile(fixture.legacy(.screenshots).appendingPathComponent("one.png"))
        OPNCaptureLocations.setOverride(fixture.root.appendingPathComponent("Elsewhere"), for: .screenshots, storage: fixture.storage)

        let result = fixture.migrate()

        #expect(result.movedLibraries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.legacy(.screenshots).appendingPathComponent("one.png").path))
        #expect(!fixture.storage.bool(forKey: OPNCaptureMigration.completionMarkerKey))
    }

    @Test func aCrossVolumeFailureFallsBackToCopyVerifyAndDelete() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacy = fixture.legacy(.screenshots)
        try writeFile(legacy.appendingPathComponent("Game/one.png"), contents: "cross-volume")
        try writeFile(legacy.appendingPathComponent("Game/nested/two.png"), contents: "nested")

        let result = fixture.migrate(moveItem: { _, _ in throw CocoaError(.fileWriteUnknown) })

        #expect(result.warnings.isEmpty)
        let destination = fixture.destination(.screenshots)
        #expect(result.movedLibraries == [.screenshots])
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try String(contentsOf: destination.appendingPathComponent("Game/one.png"), encoding: .utf8) == "cross-volume")
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Game/nested/two.png").path))
        #expect(fixture.storage.bool(forKey: OPNCaptureMigration.completionMarkerKey))
    }

    @Test func aFailedMoveKeepsTheLegacyLibraryReadableAndWarns() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try writeFile(fixture.legacy(.screenshots).appendingPathComponent("one.png"))
        // A regular file where the destination's parent has to be makes both the move and the copy
        // fallback fail, standing in for a full disk or a revoked permission.
        try writeFile(fixture.root.appendingPathComponent("OpenNOW"))

        let result = fixture.migrate()

        #expect(!result.warnings.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.legacy(.screenshots).appendingPathComponent("one.png").path))
        #expect(!fixture.storage.bool(forKey: OPNCaptureMigration.completionMarkerKey))
        #expect(fixture.storage.string(forKey: OPNCaptureMigration.noticeKey) == result.warnings.joined(separator: " "))
    }

    @Test func theVendorFolderIsRemovedOnlyWhenTheMoveLeftItEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try writeFile(fixture.legacy(.screenshots).appendingPathComponent("one.png"))
        // Something the official client owns, next to the folder OpenNOW used to write into.
        try writeFile(fixture.root.appendingPathComponent("NVIDIA/not-ours.txt"))

        _ = fixture.migrate()

        #expect(fileExists(fixture.root.appendingPathComponent("NVIDIA/not-ours.txt")))
        #expect(!fileExists(fixture.legacy(.screenshots)))
    }

    @Test func theVendorFolderGoesWhenItIsEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try writeFile(fixture.legacy(.screenshots).appendingPathComponent("one.png"))

        _ = fixture.migrate()

        #expect(!fileExists(fixture.root.appendingPathComponent("NVIDIA")))
    }

    @Test func theNoticeNamesTheNewLocationAndIsDismissedOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try writeFile(fixture.legacy(.screenshots).appendingPathComponent("one.png"))

        _ = fixture.migrate()

        let notice = try #require(fixture.storage.string(forKey: OPNCaptureMigration.noticeKey))
        #expect(notice.contains(fixture.destination(.screenshots).path))
        OPNCaptureMigration.acknowledgeNotice(storage: fixture.storage)
        #expect(fixture.storage.string(forKey: OPNCaptureMigration.noticeKey) == nil)
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// Enumeration hands back `/private/var/...` for a `/var/...` root, so paths are canonicalised
/// before a comparison.
private func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

/// D2: an item resolves from where its sidecar was found once the stored path stops existing, so a
/// folder move — ours or the reader's own in Finder — loses nothing.
struct OPNCaptureItemResolutionTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureResolution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aMissingStoredPathFallsBackToTheSidecarsDirectory() throws {
        let sidecarDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sidecarDirectory) }
        let resolved = StreamScreenshotLibrary.healedStoragePath(
            stored: "/definitely/not/here",
            sidecarDirectory: sidecarDirectory
        )
        #expect(resolved == sidecarDirectory.path)
    }

    @Test func anExplicitOutOfRootPathStillWinsWhileItExists() throws {
        let outside = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let sidecarDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sidecarDirectory) }
        let resolved = StreamScreenshotLibrary.healedStoragePath(
            stored: outside.path,
            sidecarDirectory: sidecarDirectory
        )
        #expect(resolved == outside.path)
    }

    @Test func aScreenshotWithAStalePathStillLoadsFromItsSidecar() throws {
        let root = try StreamScreenshotLibrary.ensureDirectory()
        let id = UUID()
        let sidecar = root.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        let image = root.appendingPathComponent(id.uuidString).appendingPathExtension("png")
        defer {
            try? FileManager.default.removeItem(at: sidecar)
            try? FileManager.default.removeItem(at: image)
        }
        let stale = StreamScreenshot(
            id: id,
            title: "Moved",
            applicationID: "100",
            createdAt: Date(),
            width: 4,
            height: 4,
            fileName: image.lastPathComponent,
            fileSizeBytes: 3,
            albumIDs: [],
            storageDirectoryPath: "/definitely/not/here"
        )
        try JSONEncoder.recordingEncoder.encode(stale).write(to: sidecar)
        try Data([1, 2, 3]).write(to: image)

        let loaded = try #require(StreamScreenshotLibrary.loadScreenshots().first { $0.id == id })
        // Enumeration hands back `/private/var/...` for a temporary-directory root, so both sides are
        // canonicalised before comparing.
        let loadedDirectory = try #require(loaded.storageDirectoryPath)
        #expect(canonicalPath(loadedDirectory) == canonicalPath(root.path))
        #expect(loaded.imageURL.resolvingSymlinksInPath() == image.resolvingSymlinksInPath())
    }

    @Test func aRecordingWithAStalePathStillLoadsFromItsSidecar() throws {
        let root = StreamRecordingLibrary.recordingsDirectory
        let directory = root.appendingPathComponent("Resolution-\(UUID().uuidString)", isDirectory: true)
        let id = UUID()
        let sidecar = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        let video = directory.appendingPathComponent(id.uuidString).appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = StreamRecording(
            id: id,
            title: "Moved",
            applicationID: "100",
            createdAt: Date(),
            durationSeconds: 1,
            width: 4,
            height: 4,
            videoBitrateMbps: 1,
            audioBitrateKbps: 128,
            enhancedVideo: false,
            fileName: video.lastPathComponent,
            fileSizeBytes: 3,
            storageDirectoryPath: "/definitely/not/here"
        )
        try JSONEncoder.recordingEncoder.encode(stale).write(to: sidecar)
        try Data([1, 2, 3]).write(to: video)

        let loaded = try #require(StreamRecordingLibrary.loadRecordings().first { $0.id == id })
        let loadedDirectory = try #require(loaded.storageDirectoryPath)
        #expect(canonicalPath(loadedDirectory) == canonicalPath(directory.path))
    }
}
