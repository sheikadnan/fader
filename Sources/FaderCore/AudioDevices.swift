import CoreAudio
import Foundation

/// The system's audio devices, as far as Fader needs them.
public enum AudioDevices {

    public static let system = AudioObjectID(kAudioObjectSystemObject)

    public static var defaultOutputID: AudioObjectID {
        HAL.get(system, HAL.address(kAudioHardwarePropertyDefaultOutputDevice), default: AudioObjectID(0))
    }

    public static func uid(_ device: AudioObjectID) -> String? {
        guard device != 0 else { return nil }
        return HAL.string(device, HAL.address(kAudioDevicePropertyDeviceUID))
    }

    public static func name(_ device: AudioObjectID) -> String? {
        guard device != 0 else { return nil }
        return HAL.string(device, HAL.address(kAudioObjectPropertyName))
    }

    public static func nominalSampleRate(_ device: AudioObjectID) -> Double {
        guard device != 0 else { return 48_000 }
        let rate = HAL.get(device, HAL.address(kAudioDevicePropertyNominalSampleRate), default: Float64(0))
        return rate > 0 ? rate : 48_000
    }

    public static func isAlive(_ device: AudioObjectID) -> Bool {
        guard device != 0 else { return false }
        return HAL.get(device, HAL.address(kAudioDevicePropertyDeviceIsAlive), default: UInt32(0)) != 0
    }

    public static func outputChannelCount(_ device: AudioObjectID) -> Int {
        HAL.bufferChannelCounts(device, scope: kAudioObjectPropertyScopeOutput).reduce(0, +)
    }
}
