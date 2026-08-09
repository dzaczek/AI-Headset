import Foundation
import os

/// SPSC ring buffer of interleaved Float32 frames, for the two branches
/// plan section 2.2 describes: the copy of Bridge.in fed to the
/// resampler/WS send path, and the agent TTS playback queue that AGENT
/// mode reads from.
///
/// The plan calls for a lock-free queue here (mirroring the driver's
/// ringbuffer.c, which genuinely must be lock-free because it runs
/// inside coreaudiod -- a crash or stall there takes down system
/// audio). This ring buffer instead runs inside our own daemon
/// process between the aggregate's IO thread and an ordinary worker
/// thread, where a short `os_unfair_lock` critical section (copying at
/// most a few hundred frames, microseconds) is standard, accepted
/// practice in production audio apps and carries far less risk than a
/// hand-rolled lock-free structure I can't verify as thoroughly here.
final class RingBuffer: @unchecked Sendable {
    private var data: [Float]
    private let frameCapacity: Int
    private let channels: Int
    private var writeIndex: UInt64 = 0
    private var readIndex: UInt64 = 0
    private var lock = os_unfair_lock()

    init(frameCapacity: Int, channels: Int) {
        precondition(frameCapacity > 0 && (frameCapacity & (frameCapacity - 1)) == 0,
                     "frameCapacity must be a power of two")
        self.frameCapacity = frameCapacity
        self.channels = channels
        self.data = [Float](repeating: 0, count: frameCapacity * channels)
    }

    func write(_ frames: UnsafePointer<Float>, frameCount: Int) {
        let mask = frameCapacity - 1
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let start = writeIndex
        data.withUnsafeMutableBufferPointer { buf in
            for i in 0..<frameCount {
                let slot = Int((start &+ UInt64(i)) & UInt64(mask))
                for ch in 0..<channels {
                    buf[slot * channels + ch] = frames[i * channels + ch]
                }
            }
        }
        writeIndex = start &+ UInt64(frameCount)
    }

    func read(_ outFrames: UnsafeMutablePointer<Float>, frameCount: Int) {
        let mask = frameCapacity - 1
        os_unfair_lock_lock(&lock)
        let writeSnapshot = writeIndex
        var start = readIndex
        os_unfair_lock_unlock(&lock)

        var available = writeSnapshot &- start
        if available > UInt64(frameCapacity) {
            start = writeSnapshot &- UInt64(frameCapacity)
            available = UInt64(frameCapacity)
        }
        let framesToCopy = Int(min(available, UInt64(frameCount)))

        data.withUnsafeMutableBufferPointer { buf in
            for i in 0..<framesToCopy {
                let slot = Int((start &+ UInt64(i)) & UInt64(mask))
                for ch in 0..<channels {
                    outFrames[i * channels + ch] = buf[slot * channels + ch]
                }
            }
        }
        if framesToCopy < frameCount {
            for i in (framesToCopy * channels)..<(frameCount * channels) {
                outFrames[i] = 0
            }
        }

        os_unfair_lock_lock(&lock)
        readIndex = start &+ UInt64(framesToCopy)
        os_unfair_lock_unlock(&lock)
    }

    /// Drops all buffered frames immediately -- used for the AGENT
    /// `interruption` event (plan 3.3): jump the reader to the writer
    /// so playback stops instantly instead of draining stale audio.
    func clear() {
        os_unfair_lock_lock(&lock)
        readIndex = writeIndex
        os_unfair_lock_unlock(&lock)
    }

    /// Frames currently buffered and unread -- used to gate playback
    /// start until the jitter buffer has enough queued (plan 3.3:
    /// 120-200ms) and by the dead man's switch (plan 6.1: empty queue
    /// mid-utterance).
    var framesAvailable: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let available = writeIndex &- readIndex
        return Int(min(available, UInt64(frameCapacity)))
    }
}
