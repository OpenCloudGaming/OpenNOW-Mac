import CoreAudio
import Foundation
import Testing
@testable import OpenNOW

/// The UID → device resolution the picker, the Settings mic test and the capture device all share.
/// A hosted runner reports no input device, so cases needing a real UID are skipped, not failed.
@Suite struct OPNCoreAudioDeviceLookupTests {
    private enum InputDeviceGate {
        static let isAvailable = !OPNCoreAudioDeviceLookup.allInputDevices().isEmpty
        static let skipReason = "Needs a real CoreAudio input device; a hosted runner reports none."
    }

    private func inputDevices() throws -> [AudioDeviceID] {
        let devices = OPNCoreAudioDeviceLookup.allInputDevices()
        try #require(!devices.isEmpty, "a CoreAudio input device")
        return devices
    }

    private func inputDeviceUID(_ device: AudioDeviceID) throws -> String {
        try #require(OPNCoreAudioDeviceLookup.uid(of: device), "a UID for device \(device)")
    }

    @Test func anUnusableUIDResolvesToTheSystemDefaultInput() {
        let fallback = OPNCoreAudioDeviceLookup.defaultInputDevice()
        #expect(OPNCoreAudioDeviceLookup.inputDevice(matching: nil) == fallback)
        #expect(OPNCoreAudioDeviceLookup.inputDevice(matching: "") == fallback)
        #expect(OPNCoreAudioDeviceLookup.inputDevice(matching: "no-such-microphone-\(UUID().uuidString)") == fallback)
        #expect(OPNCoreAudioDeviceLookup.inputDeviceIfPresent(matching: "") == nil)
        #expect(OPNCoreAudioDeviceLookup.inputDeviceIfPresent(matching: "no-such-microphone") == nil)
        #expect(OPNCoreAudioDeviceLookup.uid(of: AudioDeviceID(kAudioObjectUnknown)) == nil)
    }

    @Test(.enabled(if: InputDeviceGate.isAvailable, Comment(rawValue: InputDeviceGate.skipReason)))
    func aPresentUIDResolvesToItsOwnDevice() throws {
        let device = try inputDevices()[0]
        let uid = try inputDeviceUID(device)
        #expect(!uid.isEmpty)
        #expect(OPNCoreAudioDeviceLookup.inputDevice(matching: uid) == device)
        #expect(OPNCoreAudioDeviceLookup.inputDeviceIfPresent(matching: uid) == device)
    }

    @Test func everyEnumeratedDeviceIsInputCapable() {
        for device in OPNCoreAudioDeviceLookup.allInputDevices() {
            #expect(device != AudioDeviceID(kAudioObjectUnknown))
            #expect(OPNCoreAudioDeviceLookup.uid(of: device) != nil, "device \(device) has no UID")
        }
    }

    /// Resolution is the tested behaviour, so no AudioUnit is opened: that needs a microphone the
    /// runner may not have, and it raises the macOS permission prompt.
    @Test(.enabled(if: InputDeviceGate.isAvailable, Comment(rawValue: InputDeviceGate.skipReason)))
    func theCaptureDeviceResolvesASavedUID() throws {
        let uid = try inputDeviceUID(inputDevices()[0])
        let device = NvstCoreAudioDevice(preferredInputDeviceUID: uid)
        #expect(device.captureDeviceState.uniqueID == uid)
        #expect(!device.captureDeviceState.isFallback)
    }

    @Test(.enabled(if: InputDeviceGate.isAvailable, Comment(rawValue: InputDeviceGate.skipReason)))
    func theCaptureDeviceReportsFallbackForAMissingUID() throws {
        let gone = NvstCoreAudioDevice(preferredInputDeviceUID: "no-such-microphone-\(UUID().uuidString)")
        #expect(gone.captureDeviceState.isFallback)
        let defaultUID = OPNCoreAudioDeviceLookup.uid(of: OPNCoreAudioDeviceLookup.defaultInputDevice())
        #expect(gone.captureDeviceState.uniqueID == defaultUID)

        let automatic = NvstCoreAudioDevice()
        #expect(!automatic.captureDeviceState.isFallback, "an empty UID is Default Device, not a fallback")
    }

    /// A fallback is a resolution result, never a write to the saved device: replugging it has to
    /// return capture to the user's choice.
    @Test(.enabled(if: InputDeviceGate.isAvailable, Comment(rawValue: InputDeviceGate.skipReason)))
    func aFallbackIsClearedWhenTheSavedDeviceIsSelected() async throws {
        let uid = try inputDeviceUID(inputDevices()[0])
        let device = NvstCoreAudioDevice(preferredInputDeviceUID: "no-such-microphone-\(UUID().uuidString)")
        #expect(device.captureDeviceState.isFallback)

        device.setPreferredInputDevice(uid: uid)
        #expect(!device.captureDeviceState.isFallback)
        #expect(device.captureDeviceState.uniqueID == uid)

        device.setPreferredInputDevice(uid: nil)
        #expect(!device.captureDeviceState.isFallback, "Default Device is a choice, not a fallback")
    }

    /// A swap rebuilds capture and only capture: the send pipeline and its RTP sequence are pinned in
    /// `NvstAudioSendPipelineTests`, and playout must not be torn down with the microphone.
    @Test(.enabled(if: InputDeviceGate.isAvailable, Comment(rawValue: InputDeviceGate.skipReason)))
    func aDeviceSwapRebuildsCaptureWithoutTouchingPlayout() throws {
        let uid = try inputDeviceUID(inputDevices()[0])
        let device = NvstCoreAudioDevice(preferredInputDeviceUID: nil)
        let before = device.captureDeviceRebuildEvidence
        let playoutBefore = (device.isPlayoutRunning, device.outputSampleRate, device.outputChannels)

        device.setPreferredInputDevice(uid: uid)
        #expect(device.captureDeviceState.uniqueID == uid)
        #expect(device.captureDeviceRebuildEvidence.rebuilds == before.rebuilds + 1)

        // Selecting the device already in use is not a swap: nothing to rebuild.
        device.setPreferredInputDevice(uid: uid)
        #expect(device.captureDeviceRebuildEvidence.rebuilds == before.rebuilds + 1)

        #expect(device.isPlayoutRunning == playoutBefore.0)
        #expect(device.outputSampleRate == playoutBefore.1)
        #expect(device.outputChannels == playoutBefore.2)
    }

    /// One physical plug fires several notifications, and each rebuild recreates an AudioUnit, so the
    /// burst has to collapse into one evaluation and must not rebuild when nothing resolved differently.
    @Test(.enabled(if: OPNCoreAudioDeviceLookup.allInputDevices().count > 1,
                   Comment(rawValue: "Needs two input devices to move capture between them.")))
    func aBurstOfDeviceNotificationsCollapsesIntoOneEvaluation() async throws {
        let devices = try inputDevices()
        let uid = try inputDeviceUID(devices[0])
        let device = NvstCoreAudioDevice(preferredInputDeviceUID: uid)
        let afterSelection = device.captureDeviceRebuildEvidence
        #expect(afterSelection.evaluations == 0, "selecting at construction is not an environment evaluation")

        for _ in 0..<8 { device.handleInputDeviceEnvironmentChange() }
        try await Task.sleep(for: .milliseconds(600))
        let evidence = device.captureDeviceRebuildEvidence
        #expect(evidence.evaluations == 1, "eight notifications ran \(evidence.evaluations) evaluations")
        #expect(evidence.rebuilds == afterSelection.rebuilds, "an unchanged environment must not rebuild")

        // A genuine change does rebuild, once per move.
        let otherDevice = try #require(devices.first { OPNCoreAudioDeviceLookup.uid(of: $0) != uid }, "a second input device")
        device.setPreferredInputDevice(uid: try inputDeviceUID(otherDevice))
        #expect(device.captureDeviceRebuildEvidence.rebuilds == afterSelection.rebuilds + 1)
    }
}
