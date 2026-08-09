#ifndef AIHEADSET_RINGBUFFER_H
#define AIHEADSET_RINGBUFFER_H

#include <stdatomic.h>
#include <stdint.h>

/*
 * Lock-free single-producer/single-consumer ring buffer of interleaved
 * Float32 frames. Safe to call Write from one thread and Read from
 * exactly one other thread concurrently; not safe for multiple writers
 * or multiple readers.
 *
 * No allocation and no locking anywhere in Write/Read — both are called
 * from DoIOOperation, which runs on the coreaudiod realtime IO thread
 * (plan section 1.6).
 */
typedef struct {
    float           *data;           /* frameCapacity * channels floats, caller-owned storage */
    uint32_t         frameCapacity;  /* power of two */
    uint32_t         channels;
    _Atomic uint64_t writeIndex;     /* frames written, monotonically increasing */
    _Atomic uint64_t readIndex;      /* frames read, monotonically increasing */
} AIHeadsetRingBuffer;

/* storage must point at frameCapacity * channels floats and outlive rb.
 * frameCapacity must be a power of two. */
void AIHeadsetRingBuffer_Init(AIHeadsetRingBuffer *rb,
                               float *storage,
                               uint32_t frameCapacity,
                               uint32_t channels);

/* Copies frameCount frames from `frames` into the ring buffer. */
void AIHeadsetRingBuffer_Write(AIHeadsetRingBuffer *rb,
                                const float *frames,
                                uint32_t frameCount);

/* Copies frameCount frames into `outFrames`. Any frames not yet
 * available (underrun) are zero-filled rather than left as stale data. */
void AIHeadsetRingBuffer_Read(AIHeadsetRingBuffer *rb,
                               float *outFrames,
                               uint32_t frameCount);

#endif /* AIHEADSET_RINGBUFFER_H */
