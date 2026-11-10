import Synchronization

/// A single-producer, single-consumer queue of samples. Neither side allocates or takes a lock,
/// so one side can be a Core Audio IOProc.
public final class SampleFIFO: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Samples ever written and ever read. Only the writer stores `written`, only the reader `read`.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    /// Samples the writer had to drop because the reader fell behind.
    public let dropped = Atomic<Int>(0)

    /// Room for at least `minimumCapacity` samples (rounded up to a power of two).
    public init(minimumCapacity: Int) {
        var size = 1
        while size < minimumCapacity { size <<= 1 }
        capacity = size
        mask = size - 1
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit { storage.deallocate() }

    /// Samples waiting to be read.
    public var count: Int { written.load(ordering: .acquiring) - read.load(ordering: .acquiring) }

    /// Writer side. Returns how many were written; the rest are dropped and counted.
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        let w = written.load(ordering: .relaxed)
        let r = read.load(ordering: .acquiring)
        let n = min(count, capacity - (w - r))
        copy(n, from: source, toRingAt: w)
        written.store(w + n, ordering: .releasing)
        if n < count { dropped.add(count - n, ordering: .relaxed) }
        return n
    }

    /// Reader side. Returns how many were read.
    public func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let r = read.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        let n = min(maxCount, w - r)
        var done = 0
        while done < n {
            let slot = (r + done) & mask
            let run = min(n - done, capacity - slot)
            destination.advanced(by: done).update(from: storage.advanced(by: slot), count: run)
            done += run
        }
        read.store(r + n, ordering: .releasing)
        return n
    }

    /// Reader side: forgets everything waiting.
    public func discardAll() {
        read.store(written.load(ordering: .acquiring), ordering: .releasing)
    }

    private func copy(_ n: Int, from source: UnsafePointer<Float>, toRingAt index: Int) {
        var done = 0
        while done < n {
            let slot = (index + done) & mask
            let run = min(n - done, capacity - slot)
            storage.advanced(by: slot).update(from: source.advanced(by: done), count: run)
            done += run
        }
    }
}

/// Frames addressed by their absolute position in the stream, written ahead of a reader that
/// moves at its own pace (the IOProc's clock). The reader asks which of the frames it is about
/// to play exist; anything missing it plays from elsewhere.
///
/// One writer and one reader, neither allocating nor locking.
public final class TimelineRing: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Frames before `validFrom` don't belong to the current run of writes (a restart skipped
    /// them); frames from `end` on aren't written yet.
    private let validFrom = Atomic<Int>(0)
    private let end = Atomic<Int>(0)
    /// Where the reader is. The writer never laps it.
    private let readPosition = Atomic<Int>(0)

    public init(minimumCapacity: Int) {
        var size = 1
        while size < minimumCapacity { size <<= 1 }
        capacity = size
        mask = size - 1
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit { storage.deallocate() }

    /// Writer side: the next frames start at `position`, which may skip ahead of what was
    /// written before. Frames the reader has already passed, or that would lap it, are left out.
    public func write(_ source: UnsafePointer<Float>, count: Int, at position: Int) {
        let currentEnd = end.load(ordering: .relaxed)
        if position != currentEnd {
            precondition(position > currentEnd, "the timeline only moves forward")
            // Order matters: the reader loads `end` first, so it never sees the new end with the
            // old start.
            validFrom.store(position, ordering: .releasing)
        }
        let limit = readPosition.load(ordering: .acquiring) + capacity
        let n = max(0, min(count, limit - position))
        var done = 0
        while done < n {
            let slot = (position + done) & mask
            let run = min(n - done, capacity - slot)
            storage.advanced(by: slot).update(from: source.advanced(by: done), count: run)
            done += run
        }
        end.store(position + n, ordering: .releasing)
    }

    /// Reader side: the frames of `range` that can be read, as a subrange (possibly empty).
    public func available(in range: Range<Int>) -> Range<Int> {
        let e = end.load(ordering: .acquiring)
        let v = validFrom.load(ordering: .acquiring)
        let lower = max(range.lowerBound, v), upper = min(range.upperBound, e)
        return lower < upper ? lower..<upper : range.lowerBound..<range.lowerBound
    }

    /// Reader side. Only for positions inside `available(in:)`.
    @inline(__always)
    public func frame(at position: Int) -> Float { storage[position & mask] }

    /// Reader side: the reader is done with everything before `position`.
    public func advanceReader(to position: Int) {
        readPosition.store(position, ordering: .releasing)
    }

    public var readerPosition: Int { readPosition.load(ordering: .acquiring) }
    public var writtenEnd: Int { end.load(ordering: .acquiring) }
}
