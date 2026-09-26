import Foundation
import Testing
@testable import OpenNOW

/// The HUD half of microphone device selection: the rows, the label naming the device in use, and the
/// state a fallback leaves behind. The transport call itself needs a live session.
@MainActor
struct NativeNVSTMicrophoneDeviceSelectionTests {
    private var defaultDevice: OPNStreamMicrophoneDeviceOption {
        OPNStreamMicrophoneDeviceOption(label: "Default Device", uniqueId: "", automatic: true)
    }

    private func pickedDevice(_ label: String = "USB Mic", uid: String = "usb-mic") -> OPNStreamMicrophoneDeviceOption {
        OPNStreamMicrophoneDeviceOption(label: label, uniqueId: uid)
    }

    /// A model whose picker offers the default and one USB microphone, with the USB one in use.
    private func modelWithTwoDevices() -> NativeNVSTHostViewModel {
        let (_, model) = makeHUDSurface()
        model.microphoneDeviceOptions = [defaultDevice, pickedDevice()]
        model.microphoneDeviceUID = "usb-mic"
        return model
    }

    @Test func theRowsAreTheSavedChoicesWithTheDefaultFirst() {
        let model = modelWithTwoDevices()
        let items = model.microphoneDevicePadItems()
        #expect(items.map(\.id) == ["", "usb-mic"])
        #expect(items[0].title == "Default Device")
        #expect(items[1].title == "USB Mic")
        #expect(items[1].isSelected, "the row in use is the one the checkmark marks")
        #expect(!items[0].isSelected)
    }

    @Test func theTriggerLabelNamesTheDeviceInUse() {
        let model = modelWithTwoDevices()
        #expect(model.microphoneDeviceSelectionLabel == "USB Mic")
        #expect(model.microphoneDeviceCaption == "Microphone Device \u{00b7} USB Mic")

        model.microphoneDeviceUID = ""
        #expect(model.microphoneDeviceSelectionLabel == "Default Device")
    }

    /// The label has to name what is capturing, so it never claims a device that is not in use.
    @Test func theTriggerLabelCallsOutAFallback() {
        let model = modelWithTwoDevices()
        model.isMicrophoneDeviceFallbackActive = true
        #expect(model.microphoneDeviceSelectionLabel == "USB Mic (fallback)")
        #expect(model.microphoneDevicePadItems().first?.title == "Default Device (fallback)")
    }

    @Test func aMissingSavedDeviceIsReportedAsAFallback() {
        let (_, model) = makeHUDSurface()
        model.microphoneDeviceUID = "usb-unplugged"
        model.microphoneDeviceOptions = [defaultDevice]
        model.resolveMicrophoneDeviceFallback()
        #expect(model.isMicrophoneDeviceFallbackActive)
    }

    @Test func aPresentSavedDeviceIsNotAFallback() {
        let model = modelWithTwoDevices()
        model.resolveMicrophoneDeviceFallback()
        #expect(!model.isMicrophoneDeviceFallbackActive)
        #expect(model.microphoneDeviceUID == "usb-mic", "resolving never rewrites the saved UID")
    }

    /// The device went away mid-stream: capture fell back, the user is told in the transport's words,
    /// and the preference is untouched — this is the one path that could make a fallback permanent.
    @Test func theFallbackReachesTheHud() {
        let (_, model) = makeHUDSurface()
        model.microphoneDeviceUID = "usb-unplugged"
        model.microphoneDeviceOptions = [defaultDevice]
        model.handleMicrophoneDeviceFallback("Microphone unavailable \u{2014} using Default Device.")
        #expect(model.isMicrophoneDeviceFallbackActive)
        #expect(model.transientStreamMessage == "Microphone unavailable \u{2014} using Default Device.")
        #expect(model.microphoneDeviceUID == "usb-unplugged", "the saved UID must survive a fallback")
    }

    @Test func aHotPluggedDeviceBecomesARow() {
        let (_, model) = makeHUDSurface()
        model.microphoneDeviceUID = "hot-plugged"
        model.microphoneDeviceOptions = [defaultDevice]
        model.resolveMicrophoneDeviceFallback()
        #expect(model.isMicrophoneDeviceFallbackActive)

        model.microphoneDeviceOptions = [defaultDevice, pickedDevice("Hot Plugged", uid: "hot-plugged")]
        model.resolveMicrophoneDeviceFallback()
        #expect(!model.isMicrophoneDeviceFallbackActive, "the device came back and the label reverts")
        #expect(model.microphoneDevicePadItems().contains { $0.id == "hot-plugged" })
    }

    @Test func theRowIsUnavailableWithNoMicrophone() {
        let (_, model) = makeHUDSurface()
        model.microphoneAvailable = false
        model.microphoneMode = "disabled"
        #expect(model.microphoneDeviceUnavailableReason == "Microphone is disabled in Settings.")
        #expect(model.isMicrophoneDeviceRowDisabled)
    }

    /// A seat that negotiated no microphone section, and a legacy RTSP-mic seat, are the two failure
    /// shapes the microphone toggle already refuses with; the disabled row repeats them word for word.
    @Test func theRowRepeatsTheTogglesFailureCopy() {
        let (_, model) = makeHUDSurface()
        model.microphoneAvailable = true
        model.microphoneMode = "voice-activity"
        model.microphoneDeviceOptions = [defaultDevice, pickedDevice()]

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
