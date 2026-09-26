import CoreAudio
import Foundation
import Testing
@testable import OpenNOW

/// Microphone device selection, the half that can be exercised without a stream: the UID → device
/// resolution the picker, the Settings mic test and the capture device all share.
///
/// These run against the real machine's CoreAudio graph rather than a stub, because the failure this
/// covers is exactly a disagreement about what a UID names. A machine with no input device at all
/// still passes the fallback cases; the known-UID cases skip themselves when there is nothing to
/// resolve.
@Suite struct OPNCoreAudioDeviceLookupTests {
    @Test func anEmptyOrUnknownUIDResolvesToTheSystemDefaultInput() {
        let fallback = OPNCoreAudioDeviceLookup.defaultInputDevice()
        #expect(OPNCoreAudioDeviceLookup.inputDevice(matching: nil) == fallback)
        #expect(OPNCoreAudioDeviceLookup.inputDevice(matching: "") == fallback)
        #expect(OPNCoreAudioDeviceLookup.inputDevice(matching: "no-such-microphone-\(UUID().uuidString)") == fallback)
        #expect(OPNCoreAudioDeviceLookup.inputDeviceIfPresent(matching: "") == nil)
        #expect(OPNCoreAudioDeviceLookup.inputDeviceIfPresent(matching: "no-such-microphone") == nil)
        #expect(OPNCoreAudioDeviceLookup.uid(of: AudioDeviceID(kAudioObjectUnknown)) == nil)
    }

    @Test func aKnownUIDResolvesToItsOwnDevice() throws {
        let devices = OPNCoreAudioDeviceLookup.allInputDevices()
        try #require(!devices.isEmpty, "this machine reports no input device, so there is no UID to resolve")
        let device = devices[0]
        let uid = try #require(OPNCoreAudioDeviceLookup.uid(of: device))
        #expect(!uid.isEmpty)
        #expect(OPNCoreAudioDeviceLookup.inputDevice(matching: uid) == device)
        #expect(OPNCoreAudioDeviceLookup.inputDeviceIfPresent(matching: uid) == device)
    }

    @Test func everyEnumeratedDeviceIsInputCapable() {
        for device in OPNCoreAudioDeviceLookup.allInputDevices() {
            #expect(device != AudioDeviceID(kAudioObjectUnknown))
            #expect(OPNCoreAudioDeviceLookup.uid(of: device) != nil, "device \(device) has no UID, so no picker row could name it")
        }
    }

    /// The capture device resolves the saved UID at construction, and reports the fallback instead of
    /// losing the user's choice. No AudioUnit is opened here: resolution is the tested behaviour, and
    /// opening a unit would need a microphone the test runner may not have.
    @Test func theCaptureDeviceResolvesASavedUIDAndReportsAMissingOne() throws {
        let devices = OPNCoreAudioDeviceLookup.allInputDevices()
        try #require(!devices.isEmpty, "this machine reports no input device")
        let uid = try #require(OPNCoreAudioDeviceLookup.uid(of: devices[0]))
        let present = NvstCoreAudioDevice(preferredInputDeviceUID: uid)
        #expect(present.captureDeviceState.uniqueID == uid)
        #expect(!present.captureDeviceState.usesFallback)

        let gone = NvstCoreAudioDevice(preferredInputDeviceUID: "no-such-microphone-\(UUID().uuidString)")
        #expect(gone.captureDeviceState.usesFallback)
        #expect(gone.captureDeviceState.uniqueID == OPNCoreAudioDeviceLookup.uid(of: OPNCoreAudioDeviceLookup.defaultInputDevice()))

        let automatic = NvstCoreAudioDevice()
        #expect(!automatic.captureDeviceState.usesFallback, "an empty UID is Default Device, never a fallback")
    }

    /// A deliberate change to a device that is present is not a fallback, and the saved UID is not
    /// rewritten by a fallback — replugging the device has to return capture to it.
    @Test func aFallbackNeverRewritesTheSavedUID() async throws {
        let devices = OPNCoreAudioDeviceLookup.allInputDevices()
        try #require(!devices.isEmpty, "this machine reports no input device")
        let uid = try #require(OPNCoreAudioDeviceLookup.uid(of: devices[0]))
        let gone = "no-such-microphone-\(UUID().uuidString)"
        let device = NvstCoreAudioDevice(preferredInputDeviceUID: gone)
        #expect(device.captureDeviceState.usesFallback)
        // The preference behind the fallback is untouched: a fallback is a resolution result, not a
        // write to the saved device, so replugging it returns capture to the user's choice.
        device.setPreferredInputDevice(uid: uid)
        #expect(!device.captureDeviceState.usesFallback)
        #expect(device.captureDeviceState.uniqueID == uid)
        device.setPreferredInputDevice(uid: nil)
        #expect(!device.captureDeviceState.usesFallback, "Default Device is a choice, not a fallback")
    }

    /// A device swap rebuilds capture and only capture. The send pipeline, its SSRC and its RTP
    /// sequence live on the bundle side and are pinned separately (`NvstAudioSendPipelineTests`); what
    /// this holds is that the swap never takes playout down with it, which is what would stall the
    /// video-adjacent audio path on every microphone change.
    ///
    /// No AudioUnit is opened here on purpose: starting an input unit from the test host raises the
    /// macOS microphone prompt. The rebuild the swap triggers is counted instead, and the playout half
    /// is asserted untouched.
    @Test func aDeviceSwapRebuildsCaptureWithoutTouchingPlayout() throws {
        let devices = OPNCoreAudioDeviceLookup.allInputDevices()
        try #require(!devices.isEmpty, "this machine reports no input device")
        let uid = try #require(OPNCoreAudioDeviceLookup.uid(of: devices[0]))
        let device = NvstCoreAudioDevice(preferredInputDeviceUID: nil)
        let before = device.captureDeviceRebuildEvidence
        let playoutBefore = (device.isPlayoutRunning, device.outputSampleRate, device.outputChannels)

        device.setPreferredInputDevice(uid: uid)
        #expect(device.captureDeviceState.uniqueID == uid)
        #expect(device.captureDeviceRebuildEvidence.rebuilds == before.rebuilds + 1)

        // Selecting the same device again is not a swap: nothing to rebuild.
        device.setPreferredInputDevice(uid: uid)
        #expect(device.captureDeviceRebuildEvidence.rebuilds == before.rebuilds + 1)

        #expect(device.isPlayoutRunning == playoutBefore.0)
        #expect(device.outputSampleRate == playoutBefore.1)
        #expect(device.outputChannels == playoutBefore.2)
    }

    /// A burst of notifications for one physical event collapses into one evaluation, and an
    /// environment that did not change the device it resolves to does not rebuild capture at all.
    @Test func aBurstOfDeviceNotificationsCollapsesIntoOneEvaluation() async throws {
        let devices = OPNCoreAudioDeviceLookup.allInputDevices()
        try #require(!devices.isEmpty, "this machine reports no input device")
        let uid = try #require(OPNCoreAudioDeviceLookup.uid(of: devices[0]))
        let device = NvstCoreAudioDevice(preferredInputDeviceUID: uid)
        let afterSelection = device.captureDeviceRebuildEvidence
        #expect(afterSelection.evaluations == 0, "selecting at construction is not an environment evaluation")
        for _ in 0..<8 { device.handleInputDeviceEnvironmentChange() }
        try await Task.sleep(for: .milliseconds(600))
        let evidence = device.captureDeviceRebuildEvidence
        #expect(evidence.evaluations == 1, "eight notifications for one event ran \(evidence.evaluations) evaluations")
        #expect(evidence.rebuilds == afterSelection.rebuilds, "an unchanged environment must not rebuild capture")
        // A genuine change does rebuild, exactly once — this is the rebuild the burst must not repeat
        // for the notifications that do not change anything. Skipped when the machine has a single
        // input device, since then no UID resolves anywhere but the same device.
        // A device that is neither the one in use nor the system default, so each change below really
        // does move capture to a different device and a default-fallback really is a move too.
        if let other = devices.first(where: {
            OPNCoreAudioDeviceLookup.uid(of: $0) != uid && $0 != OPNCoreAudioDeviceLookup.defaultInputDevice()
        }) {
            let otherUID = try #require(OPNCoreAudioDeviceLookup.uid(of: other))
            device.setPreferredInputDevice(uid: otherUID)
            #expect(device.captureDeviceRebuildEvidence.rebuilds == afterSelection.rebuilds + 1)
            device.setPreferredInputDevice(uid: "no-such-microphone-\(UUID().uuidString)")
            #expect(device.captureDeviceRebuildEvidence.rebuilds == afterSelection.rebuilds + 2)
        }
    }
}
