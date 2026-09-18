import CoreAudio
import Foundation

/// Thin, typed wrappers over the Core Audio HAL property API.
///
/// Everything in this file is a pure translation of the C API into Swift
/// shapes. No policy lives here.
public enum HAL {

    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    // MARK: Scalar properties

    public static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, default fallback: T) -> T {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        var value = fallback
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return fallback }
        return value
    }

    @discardableResult
    public static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    // MARK: Array properties

    public static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ type: T.Type) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }

        let stride = MemoryLayout<T>.stride
        let count = Int(size) / stride
        guard count > 0 else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw) == noErr else { return [] }

        return (0..<count).map { raw.load(fromByteOffset: $0 * stride, as: T.self) }
    }

    // MARK: String properties

    public static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    // MARK: Stream configuration

    /// Channel counts per buffer for the given scope, in HAL order.
    public static func bufferChannelCounts(_ object: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw) == noErr else { return [] }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    public static func streamFormat(_ object: AudioObjectID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
        let addr = address(kAudioDevicePropertyStreamFormat, scope: scope)
        var address = addr
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var value = AudioStreamBasicDescription()
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    // MARK: Listeners

    /// Owns a Core Audio property listener so it can be removed deterministically.
    public final class Listener {
        private let object: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock
        private var installed = false

        public init?(
            object: AudioObjectID,
            address: AudioObjectPropertyAddress,
            queue: DispatchQueue,
            handler: @escaping () -> Void
        ) {
            self.object = object
            self.address = address
            self.queue = queue
            self.block = { _, _ in handler() }
            let status = AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block)
            guard status == noErr else { return nil }
            installed = true
        }

        public func cancel() {
            guard installed else { return }
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            installed = false
        }

        deinit { cancel() }
    }
}

// MARK: - Diagnostics

/// Renders an `OSStatus` as `'abcd'` when it is a four-char code, so failures
/// from the HAL are readable in logs instead of raw integers.
public func fourCharString(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "\(status)" }
    return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
}
