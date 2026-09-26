import CoreAudio
import Foundation

/// The one place in the app that resolves CoreAudio devices: the system default for a selector, and
/// an input device by the UID the microphone picker saves.
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

    /// The input device carrying `uniqueId`, or nil when that UID is empty or its device is gone.
    /// Callers that must keep capture running use `inputDevice(matching:)` instead.
    static func inputDeviceIfPresent(matching uniqueId: String?) -> AudioDeviceID? {
        guard let uniqueId, !uniqueId.isEmpty else { return nil }
        return allInputDevices().first { uid(of: $0) == uniqueId }
    }

    /// The input device carrying `uniqueId`, or the system default input when that UID is nil, empty
    /// or no longer present. The caller keeps the saved UID, so a replugged device returns to it.
    static func inputDevice(matching uniqueId: String?) -> AudioDeviceID {
        inputDeviceIfPresent(matching: uniqueId) ?? defaultInputDevice()
    }

    /// Only devices with at least one input stream qualify — the same rule
    /// `OPNStreamPreferences.loadMicrophoneDeviceOptions` applies to the picker's rows.
    static func allInputDevices() -> [AudioDeviceID] {
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
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamDataSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streamDataSize) == noErr && streamDataSize > 0
        }
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
}
