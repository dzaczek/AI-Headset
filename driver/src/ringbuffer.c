#include "ringbuffer.h"
#include <string.h>

void AIHeadsetRingBuffer_Init(AIHeadsetRingBuffer *rb,
                               float *storage,
                               uint32_t frameCapacity,
                               uint32_t channels)
{
    rb->data          = storage;
    rb->frameCapacity = frameCapacity;
    rb->channels      = channels;
    memset(storage, 0, (size_t)frameCapacity * channels * sizeof(float));
    atomic_store_explicit(&rb->writeIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->readIndex, 0, memory_order_relaxed);
}

void AIHeadsetRingBuffer_Write(AIHeadsetRingBuffer *rb,
                                const float *frames,
                                uint32_t frameCount)
{
    const uint64_t writeIndex = atomic_load_explicit(&rb->writeIndex, memory_order_relaxed);
    const uint32_t mask       = rb->frameCapacity - 1;
    const uint32_t channels   = rb->channels;

    for (uint32_t i = 0; i < frameCount; i++) {
        const uint32_t slot = (uint32_t)((writeIndex + i) & mask);
        memcpy(&rb->data[(size_t)slot * channels],
               &frames[(size_t)i * channels],
               (size_t)channels * sizeof(float));
    }

    atomic_store_explicit(&rb->writeIndex, writeIndex + frameCount, memory_order_release);
}

void AIHeadsetRingBuffer_Read(AIHeadsetRingBuffer *rb,
                               float *outFrames,
                               uint32_t frameCount)
{
    const uint64_t writeIndex = atomic_load_explicit(&rb->writeIndex, memory_order_acquire);
    uint64_t readIndex        = atomic_load_explicit(&rb->readIndex, memory_order_relaxed);
    const uint32_t channels   = rb->channels;
    const uint32_t mask       = rb->frameCapacity - 1;

    uint64_t available = writeIndex - readIndex;
    if (available > rb->frameCapacity) {
        /* Reader fell far enough behind that the writer already
         * overwrote unread frames. Resync to the newest window instead
         * of copying stale data. */
        readIndex = writeIndex - rb->frameCapacity;
        available = rb->frameCapacity;
    }

    const uint32_t framesToCopy = (uint32_t)((available < frameCount) ? available : frameCount);

    for (uint32_t i = 0; i < framesToCopy; i++) {
        const uint32_t slot = (uint32_t)((readIndex + i) & mask);
        memcpy(&outFrames[(size_t)i * channels],
               &rb->data[(size_t)slot * channels],
               (size_t)channels * sizeof(float));
    }

    /* Underrun (nothing written yet, or writer stalled): zero-fill the
     * remainder rather than emit stale/garbage samples. */
    if (framesToCopy < frameCount) {
        memset(&outFrames[(size_t)framesToCopy * channels],
               0,
               (size_t)(frameCount - framesToCopy) * channels * sizeof(float));
    }

    atomic_store_explicit(&rb->readIndex, readIndex + framesToCopy, memory_order_release);
}
