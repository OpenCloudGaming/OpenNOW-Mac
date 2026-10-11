import CoreGraphics
import Testing
@testable import OpenNOW

@Suite struct OPNStreamTileLayoutTests {
    private let landscape = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let secondScreen = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
    private let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)

    @Test func twoWindowsOnTwoScreensFillOneScreenEach() {
        let tiles = OPNStreamTileLayout.tiles(screens: [landscape, secondScreen], windowCount: 2, orientation: .auto)
        #expect(tiles == [
            OPNStreamTile(frame: landscape, screenIndex: 0),
            OPNStreamTile(frame: secondScreen, screenIndex: 1),
        ])
    }

    @Test func twoWindowsOnOneLandscapeScreenSplitSideBySideInAutomatic() {
        let tiles = OPNStreamTileLayout.tiles(screens: [landscape], windowCount: 2, orientation: .auto)
        #expect(tiles.map(\.frame) == [
            CGRect(x: 0, y: 0, width: 960, height: 1080),
            CGRect(x: 960, y: 0, width: 960, height: 1080),
        ])
        #expect(tiles.allSatisfy { $0.screenIndex == 0 })
    }

    @Test func twoWindowsOnOnePortraitScreenSplitTopAndBottomInAutomatic() {
        let tiles = OPNStreamTileLayout.tiles(screens: [portrait], windowCount: 2, orientation: .auto)
        #expect(tiles.map(\.frame) == [
            CGRect(x: 0, y: 960, width: 1080, height: 960),
            CGRect(x: 0, y: 0, width: 1080, height: 960),
        ])
    }

    @Test func explicitOrientationOverridesTheScreenShape() {
        let stacked = OPNStreamTileLayout.tiles(screens: [landscape], windowCount: 2, orientation: .topAndBottom)
        #expect(stacked.map(\.frame) == [
            CGRect(x: 0, y: 540, width: 1920, height: 540),
            CGRect(x: 0, y: 0, width: 1920, height: 540),
        ])
        let columns = OPNStreamTileLayout.tiles(screens: [portrait], windowCount: 2, orientation: .sideBySide)
        #expect(columns.map(\.frame) == [
            CGRect(x: 0, y: 0, width: 540, height: 1920),
            CGRect(x: 540, y: 0, width: 540, height: 1920),
        ])
    }

    @Test func threeWindowsOnOneScreenShareItInOneStrip() {
        let tiles = OPNStreamTileLayout.tiles(screens: [landscape], windowCount: 3, orientation: .sideBySide)
        #expect(tiles.map(\.frame.width) == [640, 640, 640])
        #expect(tiles.map(\.frame.minX) == [0, 640, 1280])
    }

    @Test func fourWindowsOnOneScreenFormAGrid() {
        let tiles = OPNStreamTileLayout.tiles(screens: [landscape], windowCount: 4, orientation: .auto)
        #expect(tiles.map(\.frame) == [
            CGRect(x: 0, y: 540, width: 960, height: 540),
            CGRect(x: 960, y: 540, width: 960, height: 540),
            CGRect(x: 0, y: 0, width: 960, height: 540),
            CGRect(x: 960, y: 0, width: 960, height: 540),
        ])
    }

    @Test func threeWindowsOnTwoScreensGiveTheFirstScreenTheExtraWindow() {
        let tiles = OPNStreamTileLayout.tiles(screens: [landscape, secondScreen], windowCount: 3, orientation: .auto)
        #expect(tiles.map(\.screenIndex) == [0, 0, 1])
        #expect(tiles[2].frame == secondScreen)
        #expect(tiles[0].frame.width + tiles[1].frame.width == landscape.width)
    }

    @Test func oddScreenSizesLeaveNoSeamAndNoOverlap() {
        let odd = CGRect(x: 0, y: 0, width: 1367, height: 769)
        for count in 2...7 {
            for orientation in OPNStreamTileOrientation.allCases {
                let tiles = OPNStreamTileLayout.tiles(screens: [odd], windowCount: count, orientation: orientation)
                #expect(tiles.count == count)
                let covered = tiles.reduce(0) { $0 + $1.frame.width * $1.frame.height }
                #expect(covered == odd.width * odd.height, "\(count) windows, \(orientation)")
                for (index, tile) in tiles.enumerated() {
                    #expect(odd.contains(tile.frame))
                    for other in tiles[(index + 1)...] {
                        #expect(tile.frame.intersection(other.frame).isEmpty || tile.frame.intersection(other.frame).width * tile.frame.intersection(other.frame).height == 0)
                    }
                }
            }
        }
    }

    @Test func screensOfDifferentSizesKeepTheirOwnTiles() {
        let tiles = OPNStreamTileLayout.tiles(screens: [landscape, secondScreen], windowCount: 4, orientation: .sideBySide)
        let first = tiles.filter { $0.screenIndex == 0 }
        let second = tiles.filter { $0.screenIndex == 1 }
        #expect(first.count == 2 && second.count == 2)
        #expect(first.allSatisfy { landscape.contains($0.frame) })
        #expect(second.allSatisfy { secondScreen.contains($0.frame) })
        #expect(second.map(\.frame.width) == [1280, 1280])
    }

    @Test func nothingToPlaceProducesNoTiles() {
        #expect(OPNStreamTileLayout.tiles(screens: [], windowCount: 2, orientation: .auto).isEmpty)
        #expect(OPNStreamTileLayout.tiles(screens: [landscape], windowCount: 0, orientation: .auto).isEmpty)
    }

    @Test func oneWindowFillsItsScreen() {
        #expect(OPNStreamTileLayout.tiles(screens: [landscape, secondScreen], windowCount: 1, orientation: .auto) == [
            OPNStreamTile(frame: landscape, screenIndex: 0),
        ])
    }

    @Test func theOrientationPreferenceRoundTripsThroughStorage() {
        let original = OPNStreamTileOrientation.stored
        defer { OPNStreamTileOrientation.store(original) }
        for orientation in OPNStreamTileOrientation.allCases {
            OPNStreamTileOrientation.store(orientation)
            #expect(OPNStreamTileOrientation.stored == orientation)
        }
    }
}
