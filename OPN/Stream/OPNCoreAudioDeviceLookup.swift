import CoreAudio
import Foundation

/// The one place in the app that resolves CoreAudio devices: the system default for a selector, and
/// an input device by the UID the microphone picker saves.
///
/// Enumerating here rather than at each call site matters because the Settings mic test and the
/// streaming capture path must agree on which device a UID names. When they disagreed, a user could
/// pass a pre-flight mic test on their chosen microphone and still stream from the built-in one.
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

    /// The input device carrying `uniqueId`, or `nil` when that UID is empty or its device is not
    /// currently connected. Callers that want the "capture must keep running" behaviour use
    /// `inputDevice(matching:)` instead.
    static func inputDeviceIfPresent(matching uniqueId: String?) -> AudioDeviceID? {
        guard let uniqueId, !uniqueId.isEmpty else { return nil }
        return allInputDevices().first { uid(of: $0) == uniqueId }
    }

    /// The input device carrying `uniqueId`, falling back to the system default input when that UID
    /// is nil, empty or no longer present.
    ///
    /// The fallback is the whole point: a UID saved for a headset that was unplugged must leave
    /// capture running on the default rather than failing to open a unit at all. The caller keeps the
    /// saved UID so a re-plugged device returns to the user's choice.
    static func inputDevice(matching uniqueId: String?) -> AudioDeviceID {
        inputDeviceIfPresent(matching: uniqueId) ?? defaultInputDevice()
    }

    /// Only devices with at least one input stream qualify, which is the same rule
    /// `OPNStreamPreferences.loadMicrophoneDeviceOptions` applies — so a device the picker offers is
    /// exactly a device this lookup can resolve.
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
