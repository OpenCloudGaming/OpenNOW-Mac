import AppKit
import Testing
@testable import OpenNOW

/// Two placements, one window: the windowed stream and the small floating PiP picture. They are
/// stored under different keys, and this pins that saving one never overwrites the other - the
/// failure mode is a next session that opens at PiP's size.
@MainActor
@Suite struct OPNStreamWindowFrameStoreTests {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "OpenNOWTests.StreamWindowFrameStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    @Test func theTwoPlacementsAreRememberedSeparately() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let windowed = NSRect(x: 120, y: 80, width: 1280, height: 720)
        let pip = NSRect(x: 400, y: 300, width: 640, height: 360)

        #expect(OPNStreamWindowFrameStore.rememberedFrame(pictureInPicture: false, defaults: defaults) == nil)
        #expect(OPNStreamWindowFrameStore.rememberedFrame(pictureInPicture: true, defaults: defaults) == nil)

        OPNStreamWindowFrameStore.save(windowed, pictureInPicture: false, defaults: defaults)
        OPNStreamWindowFrameStore.save(pip, pictureInPicture: true, defaults: defaults)

        #expect(OPNStreamWindowFrameStore.rememberedFrame(pictureInPicture: false, defaults: defaults) == windowed)
        #expect(OPNStreamWindowFrameStore.rememberedFrame(pictureInPicture: true, defaults: defaults) == pip)
    }

    /// A zero-sized or unreadable frame must read as "nothing remembered", not as a window with no
    /// size.
    @Test func aDegenerateStoredFrameIsIgnored() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(NSStringFromRect(NSRect(x: 0, y: 0, width: 0, height: 360)),
                     forKey: OPNStreamWindowFrameStore.windowedFrameKey)
        #expect(OPNStreamWindowFrameStore.rememberedFrame(pictureInPicture: false, defaults: defaults) == nil)

        OPNStreamWindowFrameStore.save(NSRect(x: 0, y: 0, width: 0, height: 0), pictureInPicture: false, defaults: defaults)
        #expect(OPNStreamWindowFrameStore.rememberedFrame(pictureInPicture: false, defaults: defaults) == nil)
    }

    @Test func aRememberedFrameIsClampedOntoAScreen() {
        let visible = [NSRect(x: 0, y: 25, width: 1440, height: 875)]

        let belowFloor = OPNStreamWindowFrameStore.onScreen(
            NSRect(x: -500, y: -300, width: 640, height: 360), within: visible)
        #expect(belowFloor.minX >= visible[0].minX)
        #expect(belowFloor.minY >= visible[0].minY)

        let pastCeiling = OPNStreamWindowFrameStore.onScreen(
            NSRect(x: 2000, y: 5000, width: 640, height: 360), within: visible)
        #expect(pastCeiling.maxX <= visible[0].maxX)
        #expect(pastCeiling.maxY <= visible[0].maxY)

        // The screen it already overlaps wins over the first one in the list.
        let second = NSRect(x: 2000, y: 0, width: 1440, height: 900)
        let onSecond = OPNStreamWindowFrameStore.onScreen(
            NSRect(x: 2100, y: 100, width: 640, height: 360), within: visible + [second])
        #expect(onSecond.origin == NSPoint(x: 2100, y: 100))
    }

    /// A display that has since been unplugged leaves no visible frames to clamp against; the frame
    /// is passed through rather than mangled.
    @Test func withNoScreensTheFrameIsLeftAlone() {
        let frame = NSRect(x: -500, y: -300, width: 640, height: 360)
        #expect(OPNStreamWindowFrameStore.onScreen(frame, within: []) == frame)
    }
}
