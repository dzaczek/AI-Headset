#ifndef AIHEADSET_DEVICE_H
#define AIHEADSET_DEVICE_H

#include <CoreAudio/AudioServerPlugIn.h>
#include "config.h"
#include "ringbuffer.h"

/*
 * Object IDs for PHASE 1 STEP 3 (plan section 7 / table 1.2): the
 * "AI Headset" / "AI Headset Bridge" pair, cross-wired by two ring
 * buffers instead of one device looping back on itself (step 2).
 *
 * kAudioObjectPlugInObject (=1) is fixed by the SPI; the rest are ours
 * to assign, matching the plan's table exactly.
 *
 * Data flow (plan section 2):
 *   AI Headset.out  --RingA-->  Bridge.in     (rozmówca -> użytkownik/agent)
 *   Bridge.out      --RingB-->  AI Headset.in (użytkownik/agent -> rozmówca)
 */
enum {
    kObjectID_Device_Headset        = 2,
    kObjectID_Stream_Headset_Input  = 3,
    kObjectID_Stream_Headset_Output = 4,
    kObjectID_Device_Bridge         = 5,
    kObjectID_Stream_Bridge_Input   = 6,
    kObjectID_Stream_Bridge_Output  = 7,
};

typedef struct {
    Boolean ioIsRunning;
    UInt32  startedClientCount;

    /* Clock: mach ticks per full ring-buffer period, and the anchor
     * GetZeroTimeStamp advances in whole-period jumps (plan 1.4).
     * Each device gets its own independent clock and its own
     * start/stop lifecycle -- the daemon's private aggregate device
     * (Faza 2) is what reconciles drift between them, not the plugin. */
    UInt64 hostTicksPerRingBuffer;
    UInt64 anchorHostTime;
    UInt64 numberTimeStamps;
} AIHeadsetClock;

typedef struct {
    Float64 sampleRate;

    AIHeadsetClock headsetClock;
    AIHeadsetClock bridgeClock;

    /* Audio storage, sized once at compile time -- no malloc on the IO
     * path (plan section 1.6). */
    float               ringAStorage[kRingBufferFrames * kAIHeadset_ChannelCount]; /* Headset.out -> Bridge.in */
    float               ringBStorage[kRingBufferFrames * kAIHeadset_ChannelCount]; /* Bridge.out -> Headset.in */
    AIHeadsetRingBuffer ringA;
    AIHeadsetRingBuffer ringB;
} AIHeadsetDeviceState;

extern AIHeadsetDeviceState gDevice;

void AIHeadsetDevice_Initialize(void);

/* Both devices share one rate on purpose: they are a bonded pair joined
 * by the ring buffers, so a rate change on one has to move the other or
 * the buffers would be written and read at different speeds. */
void AIHeadsetDevice_SetHost(AudioServerPlugInHostRef inHost);
OSStatus AIHeadsetDevice_PerformConfigChange(UInt64 inChangeAction);

/* IO */
OSStatus AIHeadsetDevice_StartIO(AudioObjectID inDeviceObjectID, UInt32 inClientID);
OSStatus AIHeadsetDevice_StopIO(AudioObjectID inDeviceObjectID, UInt32 inClientID);
OSStatus AIHeadsetDevice_GetZeroTimeStamp(AudioObjectID inDeviceObjectID,
                                           Float64 *outSampleTime,
                                           UInt64 *outHostTime,
                                           UInt64 *outSeed);
OSStatus AIHeadsetDevice_WillDoIOOperation(UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
OSStatus AIHeadsetDevice_DoIOOperation(AudioObjectID inStreamObjectID,
                                        UInt32 inOperationID,
                                        UInt32 inIOBufferFrameSize,
                                        void *ioMainBuffer);

/*
 * Properties. inObjectID is one of kAudioObjectPlugInObject or one of
 * the object IDs above. Every unrecognized (object, selector) pair
 * returns kAudioHardwareUnknownPropertyError — never crashes (plan 1.6).
 */
Boolean  AIHeadsetProperties_HasProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress);

OSStatus AIHeadsetProperties_IsSettable(AudioObjectID inObjectID,
                                         const AudioObjectPropertyAddress *inAddress,
                                         Boolean *outIsSettable);

OSStatus AIHeadsetProperties_GetDataSize(AudioObjectID inObjectID,
                                          const AudioObjectPropertyAddress *inAddress,
                                          UInt32 inQualifierDataSize,
                                          const void *inQualifierData,
                                          UInt32 *outDataSize);

OSStatus AIHeadsetProperties_GetData(AudioObjectID inObjectID,
                                      const AudioObjectPropertyAddress *inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void *inQualifierData,
                                      UInt32 inDataSize,
                                      UInt32 *outDataSize,
                                      void *outData);

OSStatus AIHeadsetProperties_SetData(AudioObjectID inObjectID,
                                      const AudioObjectPropertyAddress *inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void *inQualifierData,
                                      UInt32 inDataSize,
                                      const void *inData);

#endif /* AIHEADSET_DEVICE_H */
