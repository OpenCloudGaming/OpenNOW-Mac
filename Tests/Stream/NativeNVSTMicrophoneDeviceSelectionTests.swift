import Foundation
import Testing
@testable import OpenNOW

/// The HUD half of microphone device selection: the rows the dropdown offers, the label that says
/// which device is actually capturing, and what happens when the saved device goes away.
///
/// The transport call itself needs a live session, so what is pinned here is the state the session is
/// drawn from — which is where a fallback can silently destroy the user's preference, and where a
/// stale option list hides a microphone that was just plugged in.
@MainActor
struct NativeNVSTMicrophoneDeviceSelectionTests {
    private var defaultDevice: OPNStreamMicrophoneDeviceOption {
        OPNStreamMicrophoneDeviceOption(label: "Default Device", uniqueId: "", automatic: true)
    }

    private func usbDevice(_ label: String = "USB Mic", id: String = "usb-mic") -> OPNStreamMicrophoneDeviceOption {
        OPNStreamMicrophoneDeviceOption(label: label, uniqueId: id)
    }

    @Test func theRowsAreTheSavedChoicesWithTheDefaultFirst() {
        let (_, model) = makeHUDSurface()
        model.microphoneDeviceOptions = [defaultDevice, usbDevice("USB Mic", id: "usb-USB Mic")]
        model.microphoneDeviceID = "usb-USB Mic"
        let items = model.microphoneDevicePadItems()
        #expect(items.map(\.id) == ["", "usb-USB Mic"])
        #expect(items[0].title == "Default Device")
        #expect(items[1].title == "USB Mic")
        #expect(items[1].isSelected, "the row in use is the one the checkmark marks")
        #expect(items[0].isSelected == false)
    }

    /// The label has to name what is capturing, so the picker never claims a device that is not in
    /// use. A fallback is called out rather than quietly relabelling the default.
    @Test func theTriggerLabelNamesTheDeviceAndCallsOutAFallback() {
        let (_, model) = makeHUDSurface()
        model.microphoneDeviceOptions = [defaultDevice, usbDevice("USB Mic", id: "usb-USB Mic")]
        model.microphoneDeviceID = "usb-USB Mic"
        #expect(model.microphoneDeviceSelectionLabel == "USB Mic")

        model.microphoneDeviceID = ""
        #expect(model.microphoneDeviceSelectionLabel == "Default Device")

        model.microphoneDeviceFallbackActive = true
        #expect(model.microphoneDeviceSelectionLabel == "Default Device (fallback)")
        #expect(model.microphoneDevicePadItems().first?.title == "Default Device (fallback)")
        // Selecting the default for real clears the fallback label.
        model.microphoneDeviceFallbackActive = false
        #expect(model.microphoneDeviceSelectionLabel == "Default Device")
    }

    /// A saved UID that is not in the list is the fallback, and the fallback is a resolution result:
    /// the UID stays saved so a re-plugged microphone returns to the user's choice.
    @Test func aMissingSavedDeviceIsAFallbackAndIsNotRewritten() {
        let (_, model) = makeHUDSurface()
        model.microphoneDeviceID = "usb-unplugged"
        model.microphoneDeviceOptions = [defaultDevice]
        model.resolveMicrophoneDeviceFallback()
        #expect(model.microphoneDeviceFallbackActive)

        model.microphoneDeviceOptions = [defaultDevice, usbDevice("USB Mic", id: "usb-unplugged")]
        model.resolveMicrophoneDeviceFallback()
        #expect(!model.microphoneDeviceFallbackActive, "the device came back and the label reverts")
        #expect(model.microphoneDeviceID == "usb-unplugged")
        #expect(model.microphoneDeviceSelectionLabel == "USB Mic")
    }

    /// The device went away mid-stream: capture fell back, the user is told in the transport's words,
    /// and the preference is untouched. This is the one path that could quietly make a fallback
    /// permanent.
    @Test func theFallbackReachesTheHudAndKeepsTheSavedUid() {
        let (_, model) = makeHUDSurface()
        model.microphoneDeviceID = "usb-unplugged"
        model.microphoneDeviceOptions = [defaultDevice]
        model.handleMicrophoneDeviceFallback("Microphone unavailable \u{2014} using Default Device.")
        #expect(model.microphoneDeviceFallbackActive)
        #expect(model.transientStreamMessage == "Microphone unavailable \u{2014} using Default Device.")
        #expect(model.microphoneDeviceID == "usb-unplugged", "the saved UID must survive a fallback")
        #expect(model.microphoneDeviceSelectionLabel == "Default Device (fallback)")
    }

    /// A microphone plugged in mid-stream becomes a row without closing the HUD: the list is reloaded
    /// from CoreAudio, which is what makes a hot-plug selectable at all.
    @Test func aHotPluggedDeviceBecomesARowAndClearsTheFallbackLabel() {
        let (_, model) = makeHUDSurface()
        model.microphoneDeviceID = "hot-plugged"
        model.microphoneDeviceOptions = [defaultDevice]
        model.resolveMicrophoneDeviceFallback()
        #expect(model.microphoneDeviceFallbackActive)
        model.microphoneDeviceOptions = [defaultDevice, OPNStreamMicrophoneDeviceOption(label: "Hot Plugged", uniqueId: "hot-plugged")]
        model.resolveMicrophoneDeviceFallback()
        #expect(!model.microphoneDeviceFallbackActive)
        #expect(model.microphoneDevicePadItems().contains { $0.id == "hot-plugged" })
    }

    /// Settings turned the microphone off, so there is nothing for a picker to choose between — and
    /// the reason is the same sentence the microphone tile already says.
    @Test func theRowIsUnavailableWithNoMicrophoneAndSaysWhy() {
        let (_, model) = makeHUDSurface()
        model.microphoneAvailable = false
        model.microphoneMode = "disabled"
        #expect(model.microphoneDeviceUnavailableReason == "Microphone is disabled in Settings.")
        #expect(model.isMicrophoneDeviceRowDisabled)
    }

    /// A seat that negotiated no microphone section, and a legacy RTSP-mic seat, are the two failure
    /// shapes the microphone toggle already refuses with; the disabled row repeats them word for word
    /// rather than inventing a third explanation.
    @Test func theSeatFailureCopyIsTheTogglesOwn() {
        let (_, model) = makeHUDSurface()
        model.microphoneAvailable = true
        model.microphoneMode = "voice-activity"
        model.microphoneDeviceOptions = [defaultDevice, usbDevice()]
        model.microphoneTransportAvailability = .pending
        #expect(model.microphoneDeviceUnavailableReason == nil, "not knowing yet must not grey the row out")
        #expect(!model.isMicrophoneDeviceRowDisabled)

        model.microphoneTransportAvailability = .noBundleChannel
        #expect(model.microphoneDeviceUnavailableReason == NativeNVSTMicrophoneAvailability.noBundleChannel.failureMessage)
        #expect(model.isMicrophoneDeviceRowDisabled)

        model.microphoneTransportAvailability = .legacyTransport
        #expect(model.microphoneDeviceUnavailableReason == NativeNVSTMicrophoneAvailability.legacyTransport.failureMessage)
        #expect(model.isMicrophoneDeviceRowDisabled)
    }
}
