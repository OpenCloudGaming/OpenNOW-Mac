import Foundation
import Testing
@testable import OpenNOW

/// The HUD's arrangement is remembered globally. Serialized because every test here writes
/// `UserDefaults`, and the layout-mutation tests live here so no parallel suite writes those keys.
@Suite(.serialized) @MainActor struct StreamHUDSettingsTests {
    @Test func unsetPreferencesCollapseNothing() {
        withPreservedHUDSettings {
            UserDefaults.standard.removeObject(forKey: OPNStreamHUDSettings.collapsedSectionsKey)
            #expect(OPNStreamHUDSettings.collapsedSections.isEmpty)
        }
    }

    @Test func everySectionRoundTrips() {
        withPreservedHUDSettings {
            let collapsed: Set<OPNStreamHUDSection> = [.capture, .network, .stream]
            OPNStreamHUDSettings.collapsedSections = collapsed
            #expect(OPNStreamHUDSettings.collapsedSections == collapsed)
        }
    }

    @Test func unknownStoredSectionsAreIgnored() {
        withPreservedHUDSettings {
            UserDefaults.standard.set(["capture", "controls", "bogus"], forKey: OPNStreamHUDSettings.collapsedSectionsKey)
            #expect(OPNStreamHUDSettings.collapsedSections == [.capture])
        }
    }

    @Test func headerFocusIDsAreDistinct() {
        let ids = OPNStreamHUDSection.allCases.map(\.focusID)
        #expect(Set(ids).count == ids.count)
    }

    @Test func sectionOrderDefaultsToTheDockOrder() {
        withPreservedHUDSettings {
            UserDefaults.standard.removeObject(forKey: OPNStreamHUDSettings.sectionOrderKey)
            #expect(OPNStreamHUDSettings.sectionOrder == OPNStreamHUDSection.allCases)
        }
    }

    /// A stored order keeps what it names and appends a section a later build added, so a new panel
    /// can never be hidden behind an older customization.
    @Test func aStoredOrderAdoptsSectionsItDoesNotName() {
        withPreservedHUDSettings {
            UserDefaults.standard.set(["stream", "audio", "bogus"], forKey: OPNStreamHUDSettings.sectionOrderKey)
            var expected: [OPNStreamHUDSection] = [.stream, .audio]
            expected.append(contentsOf: OPNStreamHUDSection.allCases.filter { !expected.contains($0) })
            #expect(OPNStreamHUDSettings.sectionOrder == expected)
        }
    }

    @Test func hiddenSectionsRoundTrip() {
        withPreservedHUDSettings {
            OPNStreamHUDSettings.hiddenSections = [.capture, .stats]
            #expect(OPNStreamHUDSettings.hiddenSections == [.capture, .stats])
        }
    }

    @Test func theClockIsOnUntilItIsTurnedOff() {
        withPreservedHUDSettings {
            UserDefaults.standard.removeObject(forKey: OPNStreamHUDSettings.clockVisibleKey)
            #expect(OPNStreamHUDSettings.isClockVisible)
            OPNStreamHUDSettings.isClockVisible = false
            #expect(!OPNStreamHUDSettings.isClockVisible)
        }
    }

    /// Folding a section the pad is standing in removes its controls from the list and moves focus to
    /// the header, so the next activate reopens it rather than firing a hidden control.
    @Test func foldingASectionAnchorsFocusOnItsHeader() {
        withPreservedHUDSettings {
            let (_, model) = makeHUDSurface()
            model.hudFocusID = "microphone"
            model.toggleHUDSection(.audio)
            #expect(model.collapsedHUDSections.contains(.audio))
            #expect(!model.hudFocusEntries.contains { $0.id == "microphone" })
            #expect(model.hudFocusID == OPNStreamHUDSection.audio.focusID)
        }
    }

    /// Dragging a section onto another drops it just above that target, matching the insertion line.
    @Test func reorderingDropsASectionAboveItsTarget() {
        withPreservedHUDSettings {
            let (_, model) = makeHUDSurface()
            model.moveHUDSection(.stream, to: .audio)
            #expect(Array(model.hudSectionOrder.prefix(3)) == [.session, .stream, .audio])
            #expect(model.hudSectionOrder.count == OPNStreamHUDSection.allCases.count)
        }
    }

    @Test func aSectionMovedToTheEndStaysLast() {
        withPreservedHUDSettings {
            let (_, model) = makeHUDSurface()
            model.moveHUDSectionToEnd(.session)
            #expect(model.hudSectionOrder.last == .session)
        }
    }

    /// A hidden section leaves the dock, and a section this session does not draw (no pad, Co-Op off)
    /// never appears either.
    @Test func hiddenAndAbsentSectionsLeaveTheDock() {
        withPreservedHUDSettings {
            let (_, model) = makeHUDSurface()
            model.remoteCoOpPreferences.isEnabled = false
            model.hiddenHUDSections = [.capture]
            #expect(!model.visibleHUDSectionOrder.contains(.capture))
            #expect(!model.visibleHUDSectionOrder.contains(.controllers))
            #expect(!model.visibleHUDSectionOrder.contains(.coop))
            #expect(model.visibleHUDSectionOrder.contains(.audio))
        }
    }

    @Test func resettingTheLayoutRestoresTheDefaults() {
        withPreservedHUDSettings {
            let (_, model) = makeHUDSurface()
            model.moveHUDSectionToEnd(.session)
            model.hiddenHUDSections = [.stats]
            model.isHUDClockVisible = false
            model.resetHUDLayout()
            #expect(model.hudSectionOrder == OPNStreamHUDSection.allCases)
            #expect(model.hiddenHUDSections.isEmpty)
            #expect(model.isHUDClockVisible)
        }
    }
}
