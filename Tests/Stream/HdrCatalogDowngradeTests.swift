//  A store edition the catalog lists without HDR streams SDR for that session only: the codec and
//  colour are chosen for SDR, the saved preference is untouched, and unknown metadata changes nothing.

import Foundation
import Testing
@testable import OpenNOW

@Suite struct HdrCatalogDowngradeTests {
    private typealias Resolver = StreamSettingsResolver

    private let hdrCapableDisplay = StreamDeviceCapabilities(h265HardwareDecodeSupported: true, hdrDisplaySupported: true)

    /// HDR pins HEVC here and SDR is what picks H.264, so the codec says which one ran. The 8-bit
    /// preference is the other half: HDR lifts it to ten bits, SDR leaves it alone.
    private func hdrPreferredProfile(catalogSupport: HdrCatalogSupport) -> StreamProfile {
        StreamProfile(
            resolution: StreamResolution(width: 1920, height: 1080),
            fps: 60,
            codec: "auto",
            colorQuality: "8bit_420",
            maxBitrateMbps: 25,
            enableHdr: true,
            catalogHdrSupport: catalogSupport
        )
    }

    @Test func anEditionWithoutHdrStreamsSdrForThatSession() {
        let settings = Resolver.resolve(profile: hdrPreferredProfile(catalogSupport: .unsupported), capabilities: hdrCapableDisplay)

        #expect(settings.enableHdr == false)
        #expect(settings.hdrDowngrade == .gameUnsupported)
        #expect(settings.codec == "H264")
        #expect(settings.colorQuality == "8bit_420")
    }

    @Test func anEditionThatDeclaresHdrKeepsTheHdrRequest() {
        let settings = Resolver.resolve(profile: hdrPreferredProfile(catalogSupport: .supported), capabilities: hdrCapableDisplay)

        #expect(settings.enableHdr)
        #expect(settings.hdrDowngrade == nil)
        #expect(settings.codec == "H265")
        #expect(settings.colorQuality == "10bit_420")
    }

    @Test func unknownCatalogMetadataKeepsTheHdrRequest() {
        let settings = Resolver.resolve(profile: hdrPreferredProfile(catalogSupport: .unknown), capabilities: hdrCapableDisplay)

        #expect(settings.enableHdr)
        #expect(settings.hdrDowngrade == nil)
    }

    @Test func aDisplayWithoutHdrHeadroomIsNotADowngrade() {
        let settings = Resolver.resolve(
            profile: hdrPreferredProfile(catalogSupport: .unsupported),
            capabilities: StreamDeviceCapabilities(h265HardwareDecodeSupported: true)
        )

        #expect(settings.enableHdr == false)
        #expect(settings.hdrDowngrade == nil)
    }

    @Test func aReaderWhoDidNotAskForHdrSeesNoDowngrade() {
        var profile = hdrPreferredProfile(catalogSupport: .unsupported)
        profile.enableHdr = false

        let settings = Resolver.resolve(profile: profile, capabilities: hdrCapableDisplay)

        #expect(settings.enableHdr == false)
        #expect(settings.hdrDowngrade == nil)
    }

    @Test func aStoreLauncherSessionTakesNoCatalogOpinion() {
        let configuration = StreamLaunchConfiguration(
            title: "Store Game",
            applicationID: "123",
            accessToken: "token",
            accountLinked: true,
            selectedStore: "STEAM",
            metadata: [StreamLaunchConfiguration.hdrCatalogSupportKey: HdrCatalogSupport.unsupported.rawValue]
        )

        #expect(configuration.hdrCatalogSupport(isStoreLauncherSession: false) == .unsupported)
        #expect(configuration.hdrCatalogSupport(isStoreLauncherSession: true) == .unknown)

        let settings = Resolver.resolve(
            profile: hdrPreferredProfile(catalogSupport: configuration.hdrCatalogSupport(isStoreLauncherSession: true)),
            capabilities: hdrCapableDisplay
        )

        #expect(settings.enableHdr)
        #expect(settings.hdrDowngrade == nil)
    }

    @Test func theSavedPreferenceSurvivesTheDowngrade() {
        var profile = hdrPreferredProfile(catalogSupport: .unsupported)

        _ = Resolver.resolve(profile: profile, capabilities: hdrCapableDisplay)

        #expect(profile.enableHdr)
    }

    @Test func aLaunchThatNeverAskedTheCatalogCarriesNoOpinion() {
        let configuration = StreamLaunchConfiguration(
            title: "Store Game",
            applicationID: "123",
            accessToken: "token",
            accountLinked: true,
            selectedStore: "STEAM"
        )

        #expect(configuration.hdrCatalogSupport(isStoreLauncherSession: false) == .unknown)
    }
}
