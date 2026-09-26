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

    // MARK: - The mode dropdown

    @Test func theModeRowsMatchTheSettingsPicker() {
        let (_, model) = makeHUDSurface()
        model.microphoneMode = "push-to-talk"
        let items = model.microphoneModePadItems()
        #expect(items.map(\.title) == OPNStreamPreferences.microphoneModeOptions.map(\.label))
        #expect(items.map(\.id) == OPNStreamPreferences.microphoneModeOptions.map(\.value))
        #expect(items.first { $0.isSelected }?.id == "push-to-talk")
        #expect(items.filter(\.isSelected).count == 1)
        #expect(model.microphoneModeSelectionLabel == "Push-to-Talk")
        #expect(model.microphoneModeCaption == "Microphone Mode \u{00b7} Push-to-Talk")
    }

    /// The mode is the capture gate and the chord, so applying it has to move all three: the live mode,
    /// whether this session can capture at all, and the preference the next session resolves from.
    @Test func applyingAModeMovesTheGateAndThePreference() {
        withPreservedMicrophoneMode {
            let (_, model) = makeHUDSurface()
            model.isMicrophoneSectionNegotiated = true

            model.applyMicrophoneMode("push-to-talk")
            #expect(model.microphoneMode == "push-to-talk")
            #expect(model.microphoneAvailable, "a held-to-talk session can still capture")
            #expect(OPNStreamPreferences.loadProfile().microphoneMode == "push-to-talk")

            model.applyMicrophoneMode("voice-activity")
            #expect(model.microphoneAvailable)

            model.applyMicrophoneMode("disabled")
            #expect(model.microphoneMode == "disabled")
            #expect(!model.microphoneAvailable, "off means this session has nothing to capture")
            #expect(OPNStreamPreferences.loadProfile().microphoneMode == "disabled")

            // Back on again in the same session: the section exists, only the mode changed.
            model.applyMicrophoneMode("voice-activity")
            #expect(model.microphoneAvailable)
        }
    }

    /// A recovery re-negotiates the microphone from the stored configuration, not from the HUD, so the
    /// stored one has to follow the live mode — otherwise an Off is silently undone by a reconnect.
    @Test func theStoredConfigurationFollowsTheLiveMode() {
        withPreservedMicrophoneMode {
            let (_, model) = makeHUDSurface()
            model.isMicrophoneSectionNegotiated = true
            model.microphoneDeviceUID = "usb-mic"

            model.applyMicrophoneMode("voice-activity")
            #expect(model.microphoneConfigurationForCurrentMode.captureRequested)
            #expect(model.microphoneConfigurationForCurrentMode.initiallyEnabled)

            model.applyMicrophoneMode("push-to-talk")
            #expect(model.microphoneConfigurationForCurrentMode.captureRequested)
            #expect(!model.microphoneConfigurationForCurrentMode.initiallyEnabled, "a reconnect must not open the microphone")

            model.applyMicrophoneMode("disabled")
            #expect(!model.microphoneConfigurationForCurrentMode.captureRequested, "a reconnect must not ask for a microphone section")
            #expect(model.microphoneConfigurationForCurrentMode.deviceUniqueID == "usb-mic")
        }
    }

    /// A session that never asked for a microphone section cannot switch one on, which is the one limit
    /// of changing the mode mid-stream, and the copy has to say that rather than blame the seat.
    @Test func aSessionThatAskedForNoMicrophoneCannotSwitchOneOn() {
        let (_, model) = makeHUDSurface()
        model.isMicrophoneSectionNegotiated = false
        model.microphoneTransportAvailability = .available
        #expect(model.microphoneUnavailableReason == "The microphone was off when this session started, so it can only be enabled for the next one.")
        #expect(model.isMicrophoneModeRowDisabled)
    }

    /// The mode row stays usable when the mode itself is off, because that is how it is turned back on.
    @Test func theModeRowStaysUsableWhileTheModeIsOff() {
        let (_, model) = makeHUDSurface()
        model.isMicrophoneSectionNegotiated = true
        model.microphoneMode = "disabled"
        model.microphoneAvailable = false
        #expect(model.microphoneUnavailableReason == nil)
        #expect(!model.isMicrophoneModeRowDisabled)
        #expect(model.isMicrophoneDeviceRowDisabled, "no capture means no device to route")
    }

    @Test func theRowRepeatsTheTogglesFailureCopy() {
        let (_, model) = makeHUDSurface()
        model.isMicrophoneSectionNegotiated = true
        model.microphoneAvailable = true
        model.microphoneMode = "voice-activity"
        model.microphoneDeviceOptions = [defaultDevice, pickedDevice()]

        model.microphoneTransportAvailability = .pending
        #expect(model.microphoneUnavailableReason == nil, "not knowing yet must not grey the row out")
        #expect(!model.isMicrophoneModeRowDisabled)

        model.microphoneTransportAvailability = .noBundleChannel
        #expect(model.microphoneUnavailableReason == NativeNVSTMicrophoneAvailability.noBundleChannel.failureMessage)
        #expect(model.isMicrophoneModeRowDisabled)

        model.microphoneTransportAvailability = .legacyTransport
        #expect(model.microphoneUnavailableReason == NativeNVSTMicrophoneAvailability.legacyTransport.failureMessage)
        #expect(model.isMicrophoneModeRowDisabled)
    }
}
