import Foundation
import Testing
@testable import OpenNOW

/// The HUD half of output device selection: rows, labels, fallback and rollback. The transport call
/// itself needs a live session, so the device's own report is what is driven here.
@MainActor
struct NativeNVSTOutputDeviceSelectionTests {
    private var defaultDevice: OPNStreamAudioDeviceOption {
        OPNStreamAudioDeviceOption(label: "Default Device", uniqueId: "")
    }

    private func pickedDevice(_ label: String = "USB Speakers", uid: String = "usb-out") -> OPNStreamAudioDeviceOption {
        OPNStreamAudioDeviceOption(label: label, uniqueId: uid)
    }

    private func modelWithTwoDevices() -> NativeNVSTHostViewModel {
        let (_, model) = makeHUDSurface()
        model.outputDeviceOptions = [defaultDevice, pickedDevice()]
        model.outputDeviceUID = "usb-out"
        model.isConnected = true
        return model
    }

    private func change(resolved: String?, preferred: String?, isFallback: Bool = false, isOutputUsable: Bool = true, isRouteActivated: Bool = true) -> NvstOutputDeviceChange {
        NvstOutputDeviceChange(resolvedUniqueID: resolved,
                               preferredUniqueID: preferred,
                               isFallback: isFallback,
                               isOutputUsable: isOutputUsable,
                               isRouteActivated: isRouteActivated)
    }

    @Test func theRowsAreTheSavedChoicesWithTheDefaultFirst() {
        let model = modelWithTwoDevices()
        let items = model.outputDevicePadItems()
        #expect(items.map(\.id) == ["", "usb-out"])
        #expect(items[0].title == "Default Device")
        #expect(items[1].title == "USB Speakers")
        #expect(items[1].isSelected, "the row in use is the one the checkmark marks")
        #expect(!items[0].isSelected)
    }

    @Test func theTriggerLabelNamesTheDeviceInUse() {
        let model = modelWithTwoDevices()
        #expect(model.outputDeviceSelectionLabel == "USB Speakers")
        #expect(model.outputDeviceCaption == "Output Device \u{00b7} USB Speakers")

        model.outputDeviceUID = ""
        #expect(model.outputDeviceSelectionLabel == "Default Device")
    }

    @Test func theTriggerLabelCallsOutAFallback() {
        let model = modelWithTwoDevices()
        model.isOutputDeviceFallbackActive = true
        #expect(model.outputDeviceSelectionLabel == "USB Speakers (fallback)")
        #expect(model.outputDevicePadItems().first?.title == "Default Device (fallback)")
    }

    @Test func aMissingSavedDeviceIsReportedAsAFallback() {
        let (_, model) = makeHUDSurface()
        model.outputDeviceUID = "usb-unplugged"
        model.outputDeviceOptions = [defaultDevice]
        model.resolveOutputDeviceFallback()
        #expect(model.isOutputDeviceFallbackActive)
    }

    @Test func aPresentSavedDeviceIsNotAFallback() {
        let model = modelWithTwoDevices()
        model.resolveOutputDeviceFallback()
        #expect(!model.isOutputDeviceFallbackActive)
        #expect(model.outputDeviceUID == "usb-out", "resolving never rewrites the saved UID")
    }

    /// The device reported a fallback mid-stream: the label moves, the user is told, and the saved
    /// preference is untouched — this is the one path that could make a fallback permanent.
    @Test func aDeviceReportedFallbackPreservesTheSavedChoice() {
        let (_, model) = makeHUDSurface()
        model.isConnected = true
        model.outputDeviceUID = "usb-unplugged"
        model.outputDeviceOptions = [defaultDevice]
        model.handleNativeOutputDeviceChange(change(resolved: nil, preferred: "usb-unplugged", isFallback: true))
        #expect(model.isOutputDeviceFallbackActive)
        #expect(model.outputDeviceUID == "usb-unplugged", "the saved UID must survive a fallback")
        #expect(model.transientStreamMessage.contains("fallback"))
    }

    /// A switch the device could not activate rolls the pending row back instead of leaving the
    /// picker claiming a route that was never opened.
    @Test func aRouteThatNeverActivatedRollsBack() {
        withExclusivePreferenceDomain {
            let model = modelWithTwoDevices()
            model.outputDeviceUID = ""
            model.outputDevicePendingUID = "usb-out"
            model.handleNativeOutputDeviceChange(change(resolved: nil, preferred: "usb-out", isFallback: true, isRouteActivated: false))
            #expect(model.outputDevicePendingUID == nil)
            #expect(model.transientStreamMessage == "Could not switch audio output.")
            #expect(model.outputDeviceUID.isEmpty, "a switch that never activated must not be saved")
        }
    }

    /// No usable output at all is reported rather than silently ignored.
    @Test func noUsableOutputIsReported() {
        let (_, model) = makeHUDSurface()
        model.isConnected = true
        model.outputDeviceOptions = [defaultDevice]
        model.outputDeviceUID = ""
        model.handleNativeOutputDeviceChange(change(resolved: nil, preferred: nil, isOutputUsable: false))
        #expect(model.transientStreamMessage == "No audio output device available.")
    }

    /// A route the device confirms is written through to the preference Settings reads.
    @Test func aConfirmedRouteIsSaved() {
        withExclusivePreferenceDomain {
            let key = "OpenNOW.Stream.OutputDeviceId"
            let previous = OPNAppPreferenceStorage.standard.object(forKey: key)
            defer {
                if previous == nil { OPNAppPreferenceStorage.standard.removeObject(forKey: key) }
                if let previous { OPNAppPreferenceStorage.standard.set(previous, forKey: key) }
            }
            let model = modelWithTwoDevices()
            model.outputDeviceUID = ""
            model.outputDevicePendingUID = "usb-out"
            model.handleNativeOutputDeviceChange(change(resolved: "usb-out", preferred: "usb-out"))
            #expect(model.outputDeviceUID == "usb-out")
            #expect(model.outputDevicePendingUID == nil)
            #expect(OPNStreamPreferences.loadProfile().outputDeviceId == "usb-out")
        }
    }

    /// The picker is unusable with only the synthetic default to offer, and while a switch is in
    /// flight behind the same transport call.
    @Test func theRowIsDisabledWhileUnusable() {
        let (_, model) = makeHUDSurface()
        model.outputDeviceOptions = [defaultDevice]
        #expect(model.isOutputDeviceRowDisabled, "one row is nothing to pick between")

        model.isConnected = true
        model.outputDeviceOptions = [defaultDevice, pickedDevice()]
        #expect(!model.isOutputDeviceRowDisabled)

        model.outputDevicePendingUID = "usb-out"
        #expect(model.isOutputDeviceRowDisabled, "a switch in flight must not be re-entered")
    }
}
