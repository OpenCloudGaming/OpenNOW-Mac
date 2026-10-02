import AppKit
import Testing
@testable import OpenNOW

@MainActor
@Suite struct OPNCouchCoopTileTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func sideBySideGivesInstanceOneTheLeftHalfAndInstanceTwoTheRight() {
        let first = OPNCouchCoopTileGeometry.rect(in: screen, layout: .sideBySide, instance: 1)
        let second = OPNCouchCoopTileGeometry.rect(in: screen, layout: .sideBySide, instance: 2)
        #expect(first == CGRect(x: 0, y: 0, width: 864, height: 1117))
        #expect(second == CGRect(x: 864, y: 0, width: 864, height: 1117))
    }

    @Test func topAndBottomGivesInstanceOneTheTopHalf() {
        let first = OPNCouchCoopTileGeometry.rect(in: screen, layout: .topAndBottom, instance: 1)
        let second = OPNCouchCoopTileGeometry.rect(in: screen, layout: .topAndBottom, instance: 2)
        #expect(second == CGRect(x: 0, y: 0, width: 1728, height: 558))
        #expect(first == CGRect(x: 0, y: 558, width: 1728, height: 559))
    }

    @Test func theTwoTilesCoverAnOddSizedAreaWithoutGapOrOverlap() {
        let area = CGRect(x: 100, y: 40, width: 1281, height: 801)
        for layout in [OPNCouchCoopLayout.sideBySide, .topAndBottom] {
            let first = OPNCouchCoopTileGeometry.rect(in: area, layout: layout, instance: 1)
            let second = OPNCouchCoopTileGeometry.rect(in: area, layout: layout, instance: 2)
            #expect(first.flatMap { first in second.map { first.union($0) } } == area)
            #expect(first.flatMap { first in second.map { first.intersection($0).isEmpty } } == true)
        }
    }

    @Test func tilesFollowTheScreenOriginAndSize() {
        let external = CGRect(x: 1728, y: -200, width: 2560, height: 1440)
        #expect(OPNCouchCoopTileGeometry.rect(in: external, layout: .sideBySide, instance: 2) == CGRect(x: 3008, y: -200, width: 1280, height: 1440))
    }

    @Test func manualAndOutOfRangeSeatsHaveNoTile() {
        #expect(OPNCouchCoopTileGeometry.rect(in: screen, layout: .manual, instance: 1) == nil)
        #expect(OPNCouchCoopTileGeometry.rect(in: screen, layout: .sideBySide, instance: 3) == nil)
        #expect(OPNCouchCoopTileGeometry.rect(in: screen, layout: .sideBySide, instance: 0) == nil)
        #expect(OPNCouchCoopTileGeometry.rect(in: .zero, layout: .sideBySide, instance: 1) == nil)
    }

    @Test func aTileKnowsItsPixelSize() {
        let tile = OPNCouchCoopTile.make(layout: .sideBySide, instance: 1, area: screen, backingScale: 2)
        #expect(tile.isTiled)
        #expect(tile.pixelSize == CGSize(width: 1728, height: 2234))
        let manual = OPNCouchCoopTile.make(layout: .manual, instance: 1, area: screen, backingScale: 2)
        #expect(!manual.isTiled)
        #expect(manual.pixelSize == nil)
    }

    @Test func aTileSurvivesTheLaunchConfigurationRoundTrip() throws {
        let tile = OPNCouchCoopTile.make(layout: .topAndBottom, instance: 2, area: screen, backingScale: 2)
        let configuration = StreamLaunchConfiguration(title: "Game", applicationID: "100", accessToken: "token", accountLinked: true, selectedStore: "steam", coopTile: tile)
        let decoded = try JSONDecoder().decode(StreamLaunchConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(decoded.coopTile == tile)
        #expect(configuration.settingCoopTile(nil).coopTile == nil)
        #expect(configuration.settingCoopTile(nil).id == configuration.id)
    }

    @Test func aTiledWindowDropsItsChromeAndStopsSavingItsFrame() throws {
        let suite = "OpenNOWTests.CouchCoopTile.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = OPNStreamWindowFactory.make(defaults: defaults)
        let tile = OPNCouchCoopTile.make(layout: .sideBySide, instance: 1, area: screen, backingScale: 2)

        OPNCouchCoopWindowPlacement.apply(tile, to: window)

        #expect(window.isTiled)
        #expect(window.styleMask.contains(.titled))
        #expect(window.frame == tile.frame)
        #expect(window.constrainFrameRect(NSRect(x: 0, y: 1000, width: 864, height: 1117), to: nil) == NSRect(x: 0, y: 1000, width: 864, height: 1117))
        #expect(!window.collectionBehavior.contains(.fullScreenPrimary))
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            #expect(window.standardWindowButton(button)?.isHidden == true)
        }
        window.setFrame(NSRect(x: 5, y: 5, width: 700, height: 500), display: false)
        #expect(OPNStreamWindowFrameStore.rememberedFrame(isPictureInPicture: false, defaults: defaults) == nil)
    }

    @Test func manualPlacementAllowsSystemTilingAndKeepsTheFrame() {
        let window = OPNStreamWindowFactory.make(defaults: .standard)
        let tile = OPNCouchCoopTile.make(layout: .manual, instance: 1, area: screen, backingScale: 2)
        let frameBefore = window.frame

        OPNCouchCoopWindowPlacement.apply(tile, to: window)

        #expect(!window.isTiled)
        #expect(window.frame == frameBefore)
        #expect(window.collectionBehavior.contains(.fullScreenAllowsTiling))
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
    }

    @Test func framesAreOnlyPersistedWhileWindowedAndUntiled() {
        #expect(OPNStreamWindow.shouldPersistFrame(isFullScreen: false, isTiled: false))
        #expect(!OPNStreamWindow.shouldPersistFrame(isFullScreen: true, isTiled: false))
        #expect(!OPNStreamWindow.shouldPersistFrame(isFullScreen: false, isTiled: true))
    }

    @Test func tiledPresentationHidesTheMenuBarAndDock() {
        #expect(OPNCouchCoopWindowPlacement.tiledPresentationOptions == [.autoHideMenuBar, .autoHideDock])
    }
}
