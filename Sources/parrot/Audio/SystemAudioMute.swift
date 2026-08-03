import AudioToolbox
import CoreAudio
import Foundation

/// Silences the Mac's output for the length of a recording, and puts it back.
///
/// Two ways to do it, because not every device has the first: `kAudioDevicePropertyMute`
/// is a switch a device either implements or doesn't — the built-in speakers do,
/// plenty of USB interfaces and aggregates don't — so where it's missing the
/// virtual main volume goes to zero instead and the level that was there is
/// restored afterwards.
///
/// Whichever it used, the device is remembered rather than looked up again:
/// plugging in headphones mid-sentence changes the default output, and
/// restoring the *new* one would leave the old one silent for good.
final class SystemAudioMute {
    /// What was done, and so what has to be undone. Nil means nothing was —
    /// no device, no way to silence it, or it was already silent.
    private enum Undo {
        case unmute(AudioDeviceID)
        case volume(AudioDeviceID, Float32)
    }

    private var undo: Undo?

    var isMuted: Bool { undo != nil }

    /// Silence the current default output. A no-op if the Mac is already
    /// muted — restoring would then turn audio *on* at the end of a recording,
    /// which is the one outcome nobody asked for.
    func mute() {
        guard undo == nil, let device = Self.defaultOutput() else { return }

        if let muted = Self.isMuted(device) {
            guard !muted else { return }
            if Self.setMuted(device, true) {
                undo = .unmute(device)
                return
            }
        }

        guard let level = Self.volume(device), level > 0 else { return }
        guard Self.setVolume(device, 0) else { return }
        undo = .volume(device, level)
    }

    /// Put the output back the way it was. Safe to call when nothing was muted,
    /// which is how the recording paths can call it unconditionally.
    func restore() {
        switch undo {
        case .unmute(let device):
            _ = Self.setMuted(device, false)
        case .volume(let device, let level):
            _ = Self.setVolume(device, level)
        case nil:
            break
        }
        undo = nil
    }

    // MARK: - HAL

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Nil when the device has no mute switch at all — the signal to fall back
    /// to volume rather than to assume it's unmuted.
    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = Self.address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    private static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var address = Self.address(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue
        else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
    }

    /// The volume the slider in the menu bar moves — a single number across
    /// however many channels the device actually has, which is what makes it a
    /// usable stand-in for a mute switch.
    private static func volume(_ device: AudioDeviceID) -> Float32? {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func setVolume(_ device: AudioDeviceID, _ level: Float32) -> Bool {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue
        else { return false }
        var value = level
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
        ) == noErr
    }
}
