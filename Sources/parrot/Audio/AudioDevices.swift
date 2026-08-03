import CoreAudio
import Foundation

/// One input device, as CoreAudio sees it.
///
/// The `uid` is what gets stored: unlike the numeric device id it survives a
/// reboot, a re-plug and a move to another USB port, so a settings blob written
/// last week still names the same microphone today.
struct AudioInputDevice: Equatable, Identifiable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String

    var id: String { uid }
}

/// Enumerates microphones through the HAL rather than `AVCaptureDevice`.
///
/// The capture-device API only reports what it considers a camera-ish audio
/// source; aggregate devices, loopback drivers and most USB interfaces are
/// exactly the things someone opens this menu to pick, and only the HAL lists
/// them all.
enum AudioDevices {
    /// Every device with at least one input channel, in CoreAudio's own order.
    static func inputs() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasInputChannels(id),
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(deviceID: id, uid: uid, name: name)
        }
    }

    /// Resolve a stored UID to a live device, or nil if it isn't plugged in.
    static func device(uid: String) -> AudioInputDevice? {
        guard !uid.isEmpty else { return nil }
        return inputs().first { $0.uid == uid }
    }

    /// What the system would pick on its own — shown beside "System Default" so
    /// the entry says which microphone that currently is.
    static func systemDefaultInput() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        guard let uid = string(device, kAudioDevicePropertyDeviceUID),
              let name = string(device, kAudioObjectPropertyName)
        else { return nil }
        return AudioInputDevice(deviceID: device, uid: uid, name: name)
    }

    // MARK: - HAL

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    /// The only reliable way to tell an input from an output: a device is a
    /// microphone if its input stream configuration has channels in it.
    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func string(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        let name = value as String
        return name.isEmpty ? nil : name
    }
}
