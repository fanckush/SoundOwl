import Foundation

/// Float samples in a scratch file, one file per channel, readable and writable at any offset.
///
/// Holds the 16 kHz model input and the 48 kHz restored audio of a recording, so an hour-long
/// file costs disk space instead of memory. Reads and writes use `pread`/`pwrite`, which are safe
/// from any thread. The files are unlinked as soon as they are open, so the space comes back when
/// the store is released, even if the app crashes.
public final class PCMStore: @unchecked Sendable {
    public let count: Int
    public let channelCount: Int
    public let directory: URL
    private let descriptors: [Int32]

    /// Creates `channels` zero-filled files of `count` samples in `directory`.
    public init(directory: URL, name: String, channels: Int, count: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.count = count
        channelCount = channels
        self.directory = directory
        descriptors = try (0..<channels).map { c in
            let path = directory.appending(path: "\(name)-\(c).f32").path
            let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
            guard fd >= 0, ftruncate(fd, off_t(count * MemoryLayout<Float>.size)) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
            }
            unlink(path)
            return fd
        }
    }

    deinit {
        for fd in descriptors { close(fd) }
    }

    public func write(_ samples: [Float], channel: Int, at offset: Int) throws {
        precondition(offset >= 0 && offset + samples.count <= count, "write past the end of the store")
        let bytes = samples.count * MemoryLayout<Float>.size
        let written = samples.withUnsafeBytes { pwrite(descriptors[channel], $0.baseAddress, bytes, off_t(offset * 4)) }
        guard written == bytes else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Gives the disk space under `range` back to the system; it reads as silence afterwards.
    /// Only whole filesystem blocks inside the range are freed, so a few samples at either edge
    /// may keep their values.
    public func discard(channel: Int, range: Range<Int>) {
        let range = range.clamped(to: 0..<count)
        let block = 4096
        let start = (range.lowerBound * 4 + block - 1) / block * block
        let end = range.upperBound * 4 / block * block
        guard end > start else { return }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(end - start))
        _ = fcntl(descriptors[channel], F_PUNCHHOLE, &hole)
    }

    public func read(channel: Int, range: Range<Int>) throws -> [Float] {
        let range = range.clamped(to: 0..<count)
        var samples = [Float](repeating: 0, count: range.count)
        let bytes = range.count * MemoryLayout<Float>.size
        let read = samples
            .withUnsafeMutableBytes { pread(descriptors[channel], $0.baseAddress, bytes, off_t(range.lowerBound * 4)) }
        guard read == bytes else { throw CocoaError(.fileReadUnknown) }
        return samples
    }
}
