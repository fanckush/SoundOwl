import CoreAudio
import Foundation

/// Takes over some processes' sound: a private, muting tap on them inside a private aggregate
/// device whose output is the speakers or headphones, so one IOProc reads the tapped audio and
/// writes what is heard, on one clock.
///
/// The tap is private and mutes only while it exists. If SoundOwl quits or crashes, the system
/// drops it and the app is heard directly again.
final class ProcessTap {
    let sampleRate: Double
    let bufferFrames: Int
    let output: OutputDevice

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(processes: [AudioObjectID], output: OutputDevice) throws {
        self.output = output
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "SoundOwl Live"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        do {
            try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "creating the process tap")

            let settings: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SoundOwl Live",
                kAudioAggregateDeviceUIDKey: "app.soundowl.live.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString
                ]]
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate),
                          "creating the aggregate device")
            sampleRate = (try? HAL.get(aggregate, kAudioDevicePropertyNominalSampleRate, as: Float64.self))
                ?? output.sampleRate
            bufferFrames = Int((try? HAL.get(aggregate, kAudioDevicePropertyBufferFrameSize, as: UInt32.self)) ?? 512)
        } catch {
            if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
            if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
            throw error
        }
    }

    /// Starts calling `render(input, output, frames)` on the device's real-time thread.
    func start(render: @escaping (UnsafePointer<AudioBufferList>?, UnsafeMutablePointer<AudioBufferList>?, Int) -> Void) throws {
        try HAL.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, _, output, _ in
            let list = UnsafeMutableAudioBufferListPointer(output)
            let frames = list.first.map { Int($0.mDataByteSize) / max(1, Int($0.mNumberChannels)) / 4 } ?? 0
            render(input, output, frames)
        }, "creating the IOProc")
        try HAL.check(AudioDeviceStart(aggregate, procID), "starting the aggregate device")
    }

    /// Stops in the order that never leaves the app muted without us: IOProc, device, then tap.
    func stop() {
        if let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
            self.procID = nil
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
