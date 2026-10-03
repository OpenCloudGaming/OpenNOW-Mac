import CoreAudio
import Foundation

/// The one place in the app that resolves CoreAudio devices: the system default for a selector, and
/// a device by the UID a picker saved. Both directions share one enumeration.
enum OPNCoreAudioDeviceLookup {
    static func defaultAudioDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return AudioDeviceID(kAudioObjectUnknown)
        }
        return device
    }

    static func defaultInputDevice() -> AudioDeviceID {
        defaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputDevice() -> AudioDeviceID {
        defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    /// Nil when `uniqueId` is empty or its device is gone. Callers that must keep capture running use
    /// `resolvedInputDevice(matching:)` instead.
    static func inputDevice(matching uniqueId: String?) -> AudioDeviceID? {
        device(matching: uniqueId, among: allInputDevices())
    }

    /// Falls back to the system default input, and the caller keeps the saved UID so a replugged
    /// device returns to it.
    static func resolvedInputDevice(matching uniqueId: String?) -> AudioDeviceID {
        inputDevice(matching: uniqueId) ?? defaultInputDevice()
    }

    /// Nil is also the answer for "Default Device": the caller resolves that to the system default.
    static func outputDevice(matching uniqueId: String?) -> AudioDeviceID? {
        device(matching: uniqueId, among: allOutputDevices())
    }

    /// Falls back to the system default output, and the caller keeps the saved UID.
    static func resolvedOutputDevice(matching uniqueId: String?) -> AudioDeviceID {
        outputDevice(matching: uniqueId) ?? defaultOutputDevice()
    }

    /// Only devices with at least one input stream qualify, which is the same rule the picker's rows
    /// are built from.
    static func allInputDevices() -> [AudioDeviceID] {
        devices(carrying: kAudioDevicePropertyScopeInput)
    }

    /// A capture-only interface must not become a row the output picker offers.
    static func allOutputDevices() -> [AudioDeviceID] {
        devices(carrying: kAudioDevicePropertyScopeOutput)
    }

    static func uid(of device: AudioDeviceID) -> String? {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func device(matching uniqueId: String?, among devices: [AudioDeviceID]) -> AudioDeviceID? {
        guard let uniqueId, !uniqueId.isEmpty else { return nil }
        return devices.first { uid(of: $0) == uniqueId }
    }

    private static func devices(carrying scope: AudioObjectPropertyScope) -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices) == noErr else { return [] }
        return devices.filter { device in
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamDataSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streamDataSize) == noErr && streamDataSize > 0
        }
    }
}
