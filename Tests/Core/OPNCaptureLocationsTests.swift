import Foundation
import Testing
@testable import OpenNOW

/// `OPNCaptureLocations` is the single answer to "where does this library write", so these check the
/// three things a caller depends on: the documented default, a reader's override, and a fallback
/// that is explained rather than silent.
struct OPNCaptureLocationsTests {
    private func makeStorage() -> OPNAppPreferenceStorage {
        let name = "OpenNOW.CaptureLocationsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        return OPNAppPreferenceStorage(defaults: defaults, defaultsDomain: name)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureLocations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func defaultsLiveUnderOpenNOWInTheReadersMediaFolders() {
        let screenshots = OPNCaptureLibrary.screenshots.productionDefaultDirectory()
        let recordings = OPNCaptureLibrary.recordings.productionDefaultDirectory()
        #expect(screenshots.path.hasSuffix("Pictures/OpenNOW"))
        #expect(recordings.path.hasSuffix("Movies/OpenNOW"))
        #expect(screenshots.path != recordings.path)
    }

    @Test func anOverrideIsHonouredByResolution() throws {
        let storage = makeStorage()
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let chosen = base.appendingPathComponent("Chosen", isDirectory: true)

        OPNCaptureLocations.setOverride(chosen, for: .screenshots, storage: storage)
        let resolution = OPNCaptureLocations.resolve(.screenshots, storage: storage, baseDirectory: base)

        #expect(resolution.isUsingOverride)
        #expect(resolution.url.standardizedFileURL == chosen.standardizedFileURL)
        #expect(OPNCaptureLocations.storedOverridePath(for: .screenshots, storage: storage) == chosen.standardizedFileURL.path)
    }

    @Test func resettingAnOverrideRestoresTheDefault() throws {
        let storage = makeStorage()
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let chosen = base.appendingPathComponent("Chosen", isDirectory: true)

        OPNCaptureLocations.setOverride(chosen, for: .recordings, storage: storage)
        OPNCaptureLocations.resetOverride(for: .recordings, storage: storage)

        let resolution = OPNCaptureLocations.resolve(.recordings, storage: storage, baseDirectory: base)
        #expect(resolution.overridePath == nil)
        #expect(resolution.url.standardizedFileURL == base.appendingPathComponent("recordings", isDirectory: true).standardizedFileURL)
    }

    @Test func aBlankOverrideCountsAsUnset() throws {
        let storage = makeStorage()
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        storage.set("   ", forKey: OPNCaptureLibrary.screenshots.preferenceKey)
        #expect(OPNCaptureLocations.storedOverridePath(for: .screenshots, storage: storage) == nil)
        let resolution = OPNCaptureLocations.resolve(.screenshots, storage: storage, baseDirectory: base)
        #expect(resolution.overridePath == nil)
    }

    @Test func anUnusableOverrideFallsBackToTheDefaultAndSaysWhy() throws {
        let storage = makeStorage()
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        // iCloud Drive is never a valid capture root, so this stands in for a path that cannot be
        // used without writing anything into the reader's real iCloud container.
        let cloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/OpenNOWNotAllowed", isDirectory: true)
        OPNCaptureLocations.setOverride(cloud, for: .screenshots, storage: storage)

        let resolution = OPNCaptureLocations.resolve(.screenshots, storage: storage, baseDirectory: base)
        #expect(!resolution.isUsingOverride)
        #expect(resolution.rejectionReason != nil)
        #expect(resolution.url.standardizedFileURL == base.appendingPathComponent("screenshots", isDirectory: true).standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: cloud.path))
    }

    @Test func validationRefusesFilesAndAcceptsWritableFolders() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("a-file")
        try Data().write(to: file)

        #expect(throws: OPNCaptureLocationError.notADirectory) {
            try OPNCaptureLocations.validateDirectory(file)
        }
        let directory = base.appendingPathComponent("Made/Up/Here", isDirectory: true)
        let validated = try OPNCaptureLocations.validateDirectory(directory)
        #expect(validated.standardizedFileURL == directory.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func theTwoLibrariesShareOneFolderOnlyWhenTheyArePointedAtIt() throws {
        let storage = makeStorage()
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(!OPNCaptureLocations.isSharingOneFolder(storage: storage, baseDirectory: base))
        let shared = base.appendingPathComponent("Shared", isDirectory: true)
        OPNCaptureLocations.setOverride(shared, for: .screenshots, storage: storage)
        OPNCaptureLocations.setOverride(shared, for: .recordings, storage: storage)
        #expect(OPNCaptureLocations.isSharingOneFolder(storage: storage, baseDirectory: base))
    }

    @Test func theLibrariesFollowAnOverrideThroughTheirForwarders() throws {
        let storage = makeStorage()
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let chosen = base.appendingPathComponent("Screenshots", isDirectory: true)
        OPNCaptureLocations.setOverride(chosen, for: .screenshots, storage: storage)

        #expect(OPNCaptureLocations.directory(for: .screenshots, storage: storage, baseDirectory: base).standardizedFileURL == chosen.standardizedFileURL)
    }
}

/// The rest of the suite must never write into the reader's real folders; the redirect that makes
/// that true is keyed off the launched process, so this reads as an invariant rather than a fixture.
struct OPNCaptureTestIsolationTests {
    @Test func testRunsNeverResolveIntoTheRealMediaFolders() throws {
        // A test run must redirect the roots; missing the redirect is the failure, not a skip.
        _ = try #require(OPNCaptureLocations.testRootDirectory, "the test run did not redirect capture roots")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for library in OPNCaptureLibrary.allCases {
            let path = OPNCaptureLocations.directory(for: library).path
            #expect(!path.hasPrefix(home + "/Pictures"))
            #expect(!path.hasPrefix(home + "/Movies"))
            #expect(path.contains("OpenNOWTests-"))
        }
    }
}
