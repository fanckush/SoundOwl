import CoreAudio
import Foundation

/// Thin, typed access to Core Audio object properties.
enum HAL {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        let what: String
        var description: String { "\(what) failed (\(status))" }
    }

    static func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
        if status != noErr { throw Failure(status: status, what: what()) }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as _: T.Type) throws -> T {
        var address = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { value.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, value), "reading '\(fourCC(selector))'")
        return value.load(as: T.self)
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         qualifier: [UInt8] = [], of _: T.Type) throws -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        try qualifier.withUnsafeBytes { q in
            try check(AudioObjectGetPropertyDataSize(object, &address, UInt32(q.count), q.baseAddress, &size),
                      "sizing '\(fourCC(selector))'")
        }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let values = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { values.deallocate() }
        try qualifier.withUnsafeBytes { q in
            try check(AudioObjectGetPropertyData(object, &address, UInt32(q.count), q.baseAddress, &size, values),
                      "reading '\(fourCC(selector))'")
        }
        return Array(UnsafeBufferPointer(start: values, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    static func fourCC(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "\(code)"
    }
}

/// A process Core Audio knows about, playing or not.
public struct AudioProcess: Hashable, Sendable {
    public let object: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isPlaying: Bool
}

public enum AudioProcesses {
    /// Every process with an audio client right now.
    public static func all() -> [AudioProcess] {
        let objects = (try? HAL.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                                      of: AudioObjectID.self)) ?? []
        return objects.compactMap { object in
            guard let pid = try? HAL.get(object, kAudioProcessPropertyPID, as: pid_t.self) else { return nil }
            let playing = (try? HAL.get(object, kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) ?? 0
            return AudioProcess(object: object, pid: pid, bundleID: HAL.string(object, kAudioProcessPropertyBundleID),
                                isPlaying: playing != 0)
        }
    }

    /// The processes that make an app's sound: the app itself and its helpers. Browsers and
    /// Electron apps play from helper processes (`com.google.Chrome.helper`); Safari and other
    /// WebKit apps from the shared WebKit GPU process.
    public static func processes(of bundleID: String, pid: pid_t?, in list: [AudioProcess] = all()) -> [AudioProcess] {
        let extra = sharedHelpers[bundleID] ?? []
        return list.filter { process in
            if let pid, process.pid == pid { return true }
            guard let id = process.bundleID else { return false }
            return id == bundleID || id.hasPrefix(bundleID + ".") || extra.contains(id)
        }
    }

    /// Calls `onChange` on `queue` whenever a process starts or stops being an audio client.
    /// Keep the returned object for as long as you want to hear about it.
    public static func watch(queue: DispatchQueue = .main, onChange: @escaping @Sendable () -> Void) -> AnyObject {
        PropertyWatch(kAudioHardwarePropertyProcessObjectList, queue: queue, onChange: onChange)
    }

    /// Calls `onChange` on `queue` whenever the default output device changes.
    public static func watchOutput(queue: DispatchQueue = .main, onChange: @escaping @Sendable () -> Void) -> AnyObject {
        PropertyWatch(kAudioHardwarePropertyDefaultOutputDevice, queue: queue, onChange: onChange)
    }

    static let sharedHelpers: [String: Set<String>] = [
        "com.apple.Safari": ["com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"],
        "com.apple.SafariTechnologyPreview": ["com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"],
        "com.apple.FaceTime": ["com.apple.avconferenced"],
        "com.microsoft.teams2": ["com.microsoft.teams2.helper"]
    ]
}

/// The device sound is playing through.
public struct OutputDevice: Sendable, Equatable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let sampleRate: Double
    /// True for headphones, false for speakers, nil when there's no telling (a virtual device).
    public let isHeadphones: Bool?

    public static func current() throws -> OutputDevice {
        let id = try HAL.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                             as: AudioObjectID.self)
        guard id != kAudioObjectUnknown, let uid = HAL.string(id, kAudioDevicePropertyDeviceUID) else {
            throw HAL.Failure(status: kAudioHardwareBadDeviceError, what: "finding the output device")
        }
        let rate = (try? HAL.get(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self)) ?? 0
        return OutputDevice(id: id, uid: uid, name: HAL.string(id, kAudioObjectPropertyName) ?? uid,
                            sampleRate: rate, isHeadphones: headphones(id))
    }

    private static func headphones(_ id: AudioObjectID) -> Bool? {
        let transport = (try? HAL.get(id, kAudioDevicePropertyTransportType, as: UInt32.self)) ?? 0
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            // AirPods, Bluetooth headsets. Bluetooth speakers exist, but rarely on a call.
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            // The headphone jack is a data source of the built-in output.
            let source = try? HAL.get(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput,
                                      as: UInt32.self)
            return source == fourCC("hdpn")
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            return false
        case kAudioDeviceTransportTypeUSB:
            return true
        default:
            return nil
        }
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Calls back (on `queue`) whenever a system-wide audio property changes.
final class PropertyWatch {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(_ selector: AudioObjectPropertySelector, of object: AudioObjectID = AudioObjectID(kAudioObjectSystemObject),
         queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.object = object
        address = HAL.address(selector)
        self.queue = queue
        block = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
