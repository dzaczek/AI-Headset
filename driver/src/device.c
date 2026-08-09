#include "device.h"

#include <mach/mach_time.h>
#include <string.h>

AIHeadsetDeviceState gDevice;

/* Host interface -- potrzebny, bo zmiany częstotliwości nie wolno
 * wykonać samowolnie: trzeba poprosić hosta, on zatrzyma IO i odda
 * sterowanie przez PerformDeviceConfigurationChange. */
static AudioServerPlugInHostRef gHost = NULL;

static const Float64 kSupportedRates[kAIHeadset_SampleRateCount] = kAIHeadset_SampleRates;

void AIHeadsetDevice_SetHost(AudioServerPlugInHostRef inHost)
{
    gHost = inHost;
}

static Boolean IsSupportedRate(Float64 inRate)
{
    for (int i = 0; i < kAIHeadset_SampleRateCount; i++) {
        if (kSupportedRates[i] == inRate) {
            return true;
        }
    }
    return false;
}

/* Zegar zależy od częstotliwości, więc po każdej zmianie trzeba go
 * przeliczyć -- inaczej HAL dostaje znaczniki czasu z poprzedniego
 * tempa i uznaje to za dryf. */
static void RecomputeClocks(void)
{
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    const double secondsPerRingBuffer = (double)kRingBufferFrames / gDevice.sampleRate;
    const double nanosPerRingBuffer   = secondsPerRingBuffer * 1e9;
    const UInt64 ticks =
        (UInt64)(nanosPerRingBuffer * (double)timebase.denom / (double)timebase.numer);
    const UInt64 now = mach_absolute_time();

    gDevice.headsetClock.hostTicksPerRingBuffer = ticks;
    gDevice.headsetClock.anchorHostTime          = now;
    gDevice.headsetClock.numberTimeStamps        = 0;
    gDevice.bridgeClock.hostTicksPerRingBuffer   = ticks;
    gDevice.bridgeClock.anchorHostTime            = now;
    gDevice.bridgeClock.numberTimeStamps          = 0;
}

OSStatus AIHeadsetDevice_PerformConfigChange(UInt64 inChangeAction)
{
    /* Częstotliwość przekazujemy jako liczbę całkowitą w akcji zmiany --
     * host nie interpretuje tej wartości, jest wyłącznie nasza. */
    const Float64 requested = (Float64)inChangeAction;
    if (IsSupportedRate(requested)) {
        gDevice.sampleRate = requested;
        RecomputeClocks();
    }
    return noErr;
}

#pragma mark - Lifecycle

void AIHeadsetDevice_Initialize(void)
{
    memset(&gDevice, 0, sizeof(gDevice));
    gDevice.sampleRate = kAIHeadset_SampleRate_Default;

    RecomputeClocks();

    AIHeadsetRingBuffer_Init(&gDevice.ringA, gDevice.ringAStorage, kRingBufferFrames, kAIHeadset_ChannelCount);
    AIHeadsetRingBuffer_Init(&gDevice.ringB, gDevice.ringBStorage, kRingBufferFrames, kAIHeadset_ChannelCount);
}

static AIHeadsetClock *ClockForDevice(AudioObjectID inDeviceObjectID)
{
    if (inDeviceObjectID == kObjectID_Device_Bridge) {
        return &gDevice.bridgeClock;
    }
    return &gDevice.headsetClock; /* default: Headset */
}

#pragma mark - IO

OSStatus AIHeadsetDevice_StartIO(AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    AIHeadsetClock *clock = ClockForDevice(inDeviceObjectID);
    if (clock->startedClientCount == 0) {
        /* Fresh timeline each time this device's IO goes from idle to running. */
        clock->anchorHostTime   = mach_absolute_time();
        clock->numberTimeStamps = 0;
        clock->ioIsRunning      = true;
    }
    clock->startedClientCount++;
    return noErr;
}

OSStatus AIHeadsetDevice_StopIO(AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    AIHeadsetClock *clock = ClockForDevice(inDeviceObjectID);
    if (clock->startedClientCount > 0) {
        clock->startedClientCount--;
    }
    if (clock->startedClientCount == 0) {
        clock->ioIsRunning = false;
    }
    return noErr;
}

OSStatus AIHeadsetDevice_GetZeroTimeStamp(AudioObjectID inDeviceObjectID,
                                           Float64 *outSampleTime,
                                           UInt64 *outHostTime,
                                           UInt64 *outSeed)
{
    AIHeadsetClock *clock = ClockForDevice(inDeviceObjectID);
    const UInt64 now = mach_absolute_time();
    /* Plan section 1.4 sketches this as a single `if`. That leaves the
     * anchor permanently behind real time after any scheduling hiccup
     * (sleep/wake, a slow IO cycle) — walk it forward in full periods
     * with a while loop instead. */
    while (now >= clock->anchorHostTime + clock->hostTicksPerRingBuffer) {
        clock->numberTimeStamps++;
        clock->anchorHostTime += clock->hostTicksPerRingBuffer;
    }
    *outSampleTime = (Float64)(clock->numberTimeStamps * kRingBufferFrames);
    *outHostTime   = clock->anchorHostTime;
    *outSeed       = 1;
    return noErr;
}

OSStatus AIHeadsetDevice_WillDoIOOperation(UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace)
{
    Boolean willDo = false;
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
        case kAudioServerPlugInIOOperationWriteMix:
            willDo = true;
            break;
        default:
            willDo = false;
            break;
    }
    if (outWillDo != NULL) {
        *outWillDo = willDo;
    }
    if (outWillDoInPlace != NULL) {
        *outWillDoInPlace = true; /* both ops are defined by the SPI to always be in-place */
    }
    return noErr;
}

OSStatus AIHeadsetDevice_DoIOOperation(AudioObjectID inStreamObjectID,
                                        UInt32 inOperationID,
                                        UInt32 inIOBufferFrameSize,
                                        void *ioMainBuffer)
{
    if (ioMainBuffer == NULL) {
        return noErr;
    }

    /* Only copying here — everything else (resample, WS, transcript)
     * belongs on a non-realtime thread (plan 1.6 / 2.2). No malloc, no
     * locks, no os_log. Cross-wired per plan section 2:
     *   Headset.out --RingA--> Bridge.in
     *   Bridge.out  --RingB--> Headset.in */
    switch (inStreamObjectID) {
        case kObjectID_Stream_Headset_Output:
            if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
                AIHeadsetRingBuffer_Write(&gDevice.ringA, (const float *)ioMainBuffer, inIOBufferFrameSize);
            }
            break;
        case kObjectID_Stream_Bridge_Input:
            if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
                AIHeadsetRingBuffer_Read(&gDevice.ringA, (float *)ioMainBuffer, inIOBufferFrameSize);
            }
            break;
        case kObjectID_Stream_Bridge_Output:
            if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
                AIHeadsetRingBuffer_Write(&gDevice.ringB, (const float *)ioMainBuffer, inIOBufferFrameSize);
            }
            break;
        case kObjectID_Stream_Headset_Input:
            if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
                AIHeadsetRingBuffer_Read(&gDevice.ringB, (float *)ioMainBuffer, inIOBufferFrameSize);
            }
            break;
        default:
            break;
    }
    return noErr;
}

#pragma mark - Property value helpers

/* Exact-size write: used for scalars/structs where a short buffer is a
 * caller bug, not something to silently truncate (plan 1.6: check
 * inDataSize before writing). outData == NULL means "size query only". */
static OSStatus WriteFixed(const void *value, UInt32 valueSize, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    if (outData != NULL) {
        if (inDataSize < valueSize) {
            return kAudioHardwareBadPropertySizeError;
        }
        memcpy(outData, value, valueSize);
    }
    if (outDataSize != NULL) {
        *outDataSize = valueSize;
    }
    return noErr;
}

/* Clamped write: used for lists (arrays of AudioObjectID, format
 * ranges, ...) where callers normally size their buffer exactly via
 * GetPropertyDataSize first, but a short buffer is tolerated rather
 * than treated as an error. */
static OSStatus WriteVariable(const void *bytes, UInt32 totalSize, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    if (outData != NULL) {
        const UInt32 writeSize = (inDataSize < totalSize) ? inDataSize : totalSize;
        if (writeSize > 0) {
            memcpy(outData, bytes, writeSize);
        }
        if (outDataSize != NULL) {
            *outDataSize = writeSize;
        }
    } else if (outDataSize != NULL) {
        *outDataSize = totalSize;
    }
    return noErr;
}

/* CFString properties hand back a new, caller-owned CFStringRef — the
 * standard CoreAudio HAL convention for string-valued properties. */
static OSStatus WriteCFString(const char *utf8, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    if (outData != NULL) {
        if (inDataSize < sizeof(CFStringRef)) {
            return kAudioHardwareBadPropertySizeError;
        }
        CFStringRef str = CFStringCreateWithCString(kCFAllocatorDefault, utf8, kCFStringEncodingUTF8);
        memcpy(outData, &str, sizeof(CFStringRef));
    }
    if (outDataSize != NULL) {
        *outDataSize = sizeof(CFStringRef);
    }
    return noErr;
}

static AudioStreamBasicDescription StreamFormatForRate(Float64 rate)
{
    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate       = rate;
    fmt.mFormatID         = kAudioFormatLinearPCM;
    fmt.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mBytesPerPacket   = kAIHeadset_ChannelCount * (kAIHeadset_BitsPerChannel / 8);
    fmt.mFramesPerPacket  = 1;
    fmt.mBytesPerFrame    = fmt.mBytesPerPacket;
    fmt.mChannelsPerFrame = kAIHeadset_ChannelCount;
    fmt.mBitsPerChannel   = kAIHeadset_BitsPerChannel;
    return fmt;
}

static Boolean IsBridgeStream(AudioObjectID objectID)
{
    return objectID == kObjectID_Stream_Bridge_Input || objectID == kObjectID_Stream_Bridge_Output;
}

static Boolean IsInputStream(AudioObjectID objectID)
{
    return objectID == kObjectID_Stream_Headset_Input || objectID == kObjectID_Stream_Bridge_Input;
}

#pragma mark - Per-object property tables

static OSStatus ComputePlugInProperty(const AudioObjectPropertyAddress *addr,
                                       UInt32 inQualifierDataSize, const void *inQualifierData,
                                       UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: {
            AudioClassID v = kAudioObjectClassID;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyClass: {
            AudioClassID v = kAudioPlugInClassID;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyOwner: {
            AudioObjectID v = kAudioObjectUnknown;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyManufacturer:
            return WriteCFString(kAIHeadset_Manufacturer, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyName:
            return WriteCFString(kAIHeadset_Device_Name " Plugin", inDataSize, outDataSize, outData);
        case kAudioPlugInPropertyBundleID:
            return WriteCFString(kAIHeadset_Driver_BundleID, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID ids[2] = { kObjectID_Device_Headset, kObjectID_Device_Bridge };
            return WriteVariable(ids, sizeof(ids), inDataSize, outDataSize, outData);
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID result = kAudioObjectUnknown;
            if (inQualifierData != NULL && inQualifierDataSize >= sizeof(CFStringRef)) {
                CFStringRef uid = *(const CFStringRef *)inQualifierData;
                if (uid != NULL) {
                    if (CFStringCompare(uid, CFSTR(kAIHeadset_Device_UID), 0) == kCFCompareEqualTo) {
                        result = kObjectID_Device_Headset;
                    } else if (CFStringCompare(uid, CFSTR(kAIHeadset_Bridge_UID), 0) == kCFCompareEqualTo) {
                        result = kObjectID_Device_Bridge;
                    }
                }
            }
            return WriteFixed(&result, sizeof(result), inDataSize, outDataSize, outData);
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus ComputeDeviceProperty(AudioObjectID objectID, const AudioObjectPropertyAddress *addr,
                                       UInt32 inQualifierDataSize, const void *inQualifierData,
                                       UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    (void)inQualifierDataSize;
    (void)inQualifierData;

    const Boolean isBridge = (objectID == kObjectID_Device_Bridge);

    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: {
            AudioClassID v = kAudioObjectClassID;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyClass: {
            AudioClassID v = kAudioDeviceClassID;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyOwner: {
            AudioObjectID v = kAudioObjectPlugInObject;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyName:
            return WriteCFString(isBridge ? kAIHeadset_Bridge_Name : kAIHeadset_Device_Name,
                                  inDataSize, outDataSize, outData);
        case kAudioObjectPropertyManufacturer:
            return WriteCFString(kAIHeadset_Manufacturer, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID headsetIds[2] = { kObjectID_Stream_Headset_Input, kObjectID_Stream_Headset_Output };
            AudioObjectID bridgeIds[2]  = { kObjectID_Stream_Bridge_Input, kObjectID_Stream_Bridge_Output };
            return WriteVariable(isBridge ? bridgeIds : headsetIds, sizeof(headsetIds), inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyControlList:
            /* No volume/mute controls yet — plan 1.2 lists them optional. */
            return WriteVariable(NULL, 0, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyDeviceUID:
            return WriteCFString(isBridge ? kAIHeadset_Bridge_UID : kAIHeadset_Device_UID,
                                  inDataSize, outDataSize, outData);
        case kAudioDevicePropertyModelUID:
            return WriteCFString(isBridge ? kAIHeadset_Driver_BundleID ".bridge.model"
                                           : kAIHeadset_Driver_BundleID ".model",
                                  inDataSize, outDataSize, outData);
        case kAudioDevicePropertyTransportType: {
            /* USB, not Virtual — Zoom/Teams filter virtual-transport
             * devices out of their pickers (plan section 1.3). The
             * Bridge is hidden anyway, but keeping both USB keeps the
             * clock/latency story identical between the two. */
            UInt32 v = kAudioDeviceTransportTypeUSB;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyClockDomain: {
            UInt32 v = 1; /* non-zero and shared across both devices, per plan 1.3 */
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyDeviceIsAlive: {
            UInt32 v = 1;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyDeviceIsRunning: {
            const AIHeadsetClock *clock = isBridge ? &gDevice.bridgeClock : &gDevice.headsetClock;
            UInt32 v = clock->ioIsRunning ? 1u : 0u;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: {
            UInt32 v = 1;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyLatency: {
            UInt32 v = kAIHeadset_Latency_Frames;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertySafetyOffset: {
            UInt32 v = kAIHeadset_SafetyOffset_Frames;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyZeroTimeStampPeriod: {
            UInt32 v = kRingBufferFrames;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyIsHidden: {
            /* This is the whole point of the split (plan section 2):
             * the Bridge is only ever opened by our own daemon, never
             * shown to Zoom/Teams/Signal device pickers. */
            UInt32 v = isBridge ? 1u : 0u;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyNominalSampleRate:
            return WriteFixed(&gDevice.sampleRate, sizeof(gDevice.sampleRate), inDataSize, outDataSize, outData);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange ranges[kAIHeadset_SampleRateCount];
            for (int i = 0; i < kAIHeadset_SampleRateCount; i++) {
                ranges[i].mMinimum = kSupportedRates[i];
                ranges[i].mMaximum = kSupportedRates[i];
            }
            return WriteVariable(ranges, sizeof(ranges), inDataSize, outDataSize, outData);
        }
        case kAudioDevicePropertyStreams: {
            AudioObjectID headsetIn[1]   = { kObjectID_Stream_Headset_Input };
            AudioObjectID headsetOut[1]  = { kObjectID_Stream_Headset_Output };
            AudioObjectID headsetBoth[2] = { kObjectID_Stream_Headset_Input, kObjectID_Stream_Headset_Output };
            AudioObjectID bridgeIn[1]    = { kObjectID_Stream_Bridge_Input };
            AudioObjectID bridgeOut[1]   = { kObjectID_Stream_Bridge_Output };
            AudioObjectID bridgeBoth[2]  = { kObjectID_Stream_Bridge_Input, kObjectID_Stream_Bridge_Output };
            if (addr->mScope == kAudioObjectPropertyScopeInput) {
                return WriteVariable(isBridge ? bridgeIn : headsetIn, sizeof(headsetIn), inDataSize, outDataSize, outData);
            }
            if (addr->mScope == kAudioObjectPropertyScopeOutput) {
                return WriteVariable(isBridge ? bridgeOut : headsetOut, sizeof(headsetOut), inDataSize, outDataSize, outData);
            }
            return WriteVariable(isBridge ? bridgeBoth : headsetBoth, sizeof(headsetBoth), inDataSize, outDataSize, outData);
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus ComputeStreamProperty(AudioObjectID objectID, const AudioObjectPropertyAddress *addr,
                                       UInt32 inQualifierDataSize, const void *inQualifierData,
                                       UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    (void)inQualifierDataSize;
    (void)inQualifierData;

    const Boolean isInput  = IsInputStream(objectID);
    const Boolean isBridge = IsBridgeStream(objectID);

    switch (addr->mSelector) {
        case kAudioObjectPropertyBaseClass: {
            AudioClassID v = kAudioObjectClassID;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyClass: {
            AudioClassID v = kAudioStreamClassID;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyOwner: {
            AudioObjectID v = isBridge ? kObjectID_Device_Bridge : kObjectID_Device_Headset;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioObjectPropertyOwnedObjects:
            return WriteVariable(NULL, 0, inDataSize, outDataSize, outData);
        case kAudioStreamPropertyIsActive: {
            UInt32 v = 1;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioStreamPropertyDirection: {
            UInt32 v = isInput ? 1u : 0u; /* 0 = output, 1 = input, per SPI docs */
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioStreamPropertyTerminalType: {
            /* The Bridge doesn't terminate in a physical transducer —
             * it's a line-level hop to the daemon — so it gets Line
             * rather than Headphones/Microphone. */
            UInt32 v;
            if (isBridge) {
                v = kAudioStreamTerminalTypeLine;
            } else {
                v = isInput ? kAudioStreamTerminalTypeHeadsetMicrophone : kAudioStreamTerminalTypeHeadphones;
            }
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioStreamPropertyStartingChannel: {
            UInt32 v = 1;
            return WriteFixed(&v, sizeof(v), inDataSize, outDataSize, outData);
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription fmt = StreamFormatForRate(gDevice.sampleRate);
            return WriteFixed(&fmt, sizeof(fmt), inDataSize, outDataSize, outData);
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription ranges[kAIHeadset_SampleRateCount];
            for (int i = 0; i < kAIHeadset_SampleRateCount; i++) {
                ranges[i].mFormat = StreamFormatForRate(kSupportedRates[i]);
                ranges[i].mSampleRateRange = (AudioValueRange){ kSupportedRates[i], kSupportedRates[i] };
            }
            return WriteVariable(ranges, sizeof(ranges), inDataSize, outDataSize, outData);
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus ComputeProperty(AudioObjectID objectID, const AudioObjectPropertyAddress *addr,
                                 UInt32 inQualifierDataSize, const void *inQualifierData,
                                 UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    switch (objectID) {
        case kAudioObjectPlugInObject:
            return ComputePlugInProperty(addr, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
        case kObjectID_Device_Headset:
        case kObjectID_Device_Bridge:
            return ComputeDeviceProperty(objectID, addr, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
        case kObjectID_Stream_Headset_Input:
        case kObjectID_Stream_Headset_Output:
        case kObjectID_Stream_Bridge_Input:
        case kObjectID_Stream_Bridge_Output:
            return ComputeStreamProperty(objectID, addr, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
        default:
            return kAudioHardwareBadObjectError;
    }
}

#pragma mark - Public property entry points

Boolean AIHeadsetProperties_HasProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress)
{
    UInt32 size = 0;
    const OSStatus status = ComputeProperty(inObjectID, inAddress, 0, NULL, 0, &size, NULL);
    return status == noErr;
}

OSStatus AIHeadsetProperties_IsSettable(AudioObjectID inObjectID,
                                         const AudioObjectPropertyAddress *inAddress,
                                         Boolean *outIsSettable)
{
    if (outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!AIHeadsetProperties_HasProperty(inObjectID, inAddress)) {
        *outIsSettable = false;
        return kAudioHardwareUnknownPropertyError;
    }

    /* Częstotliwość MUSI być ustawialna. Bluetooth w profilu hands-free
     * wymusza na aggregate 16 kHz i urządzenie, które odmawia zmiany,
     * po prostu przestaje przepuszczać dźwięk. */
    switch (inAddress->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outIsSettable = true;
            break;
        default:
            *outIsSettable = false;
            break;
    }
    return noErr;
}

OSStatus AIHeadsetProperties_GetDataSize(AudioObjectID inObjectID,
                                          const AudioObjectPropertyAddress *inAddress,
                                          UInt32 inQualifierDataSize,
                                          const void *inQualifierData,
                                          UInt32 *outDataSize)
{
    return ComputeProperty(inObjectID, inAddress, inQualifierDataSize, inQualifierData, 0, outDataSize, NULL);
}

OSStatus AIHeadsetProperties_GetData(AudioObjectID inObjectID,
                                      const AudioObjectPropertyAddress *inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void *inQualifierData,
                                      UInt32 inDataSize,
                                      UInt32 *outDataSize,
                                      void *outData)
{
    UInt32 written = 0;
    const OSStatus status =
        ComputeProperty(inObjectID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, &written, outData);
    if (outDataSize != NULL) {
        *outDataSize = written;
    }
    return status;
}

/* Zmiany częstotliwości nie wolno wykonać od ręki: najpierw prosimy
 * hosta, on zatrzymuje IO i oddaje sterowanie przez
 * PerformDeviceConfigurationChange. Samowolna zmiana w trakcie pracy
 * rozjeżdża HAL-owi zegar i bufory. */
static OSStatus RequestSampleRateChange(AudioObjectID inObjectID, Float64 inRate)
{
    if (!IsSupportedRate(inRate)) {
        return kAudioDeviceUnsupportedFormatError;
    }
    if (inRate == gDevice.sampleRate) {
        return noErr; /* już tyle mamy */
    }
    if (gHost == NULL) {
        return kAudioHardwareNotReadyError;
    }

    /* Oba urządzenia są związane ring bufferami, więc muszą iść w tym
     * samym tempie -- prosimy o zmianę dla obu. */
    (void)inObjectID;
    gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device_Headset, (UInt64)inRate, NULL);
    gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device_Bridge, (UInt64)inRate, NULL);
    return noErr;
}

OSStatus AIHeadsetProperties_SetData(AudioObjectID inObjectID,
                                      const AudioObjectPropertyAddress *inAddress,
                                      UInt32 inQualifierDataSize,
                                      const void *inQualifierData,
                                      UInt32 inDataSize,
                                      const void *inData)
{
    (void)inQualifierDataSize;
    (void)inQualifierData;

    if (!AIHeadsetProperties_HasProperty(inObjectID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    switch (inAddress->mSelector) {
        case kAudioDevicePropertyNominalSampleRate: {
            if (inData == NULL || inDataSize < sizeof(Float64)) {
                return kAudioHardwareBadPropertySizeError;
            }
            Float64 rate = 0;
            memcpy(&rate, inData, sizeof(Float64));
            return RequestSampleRateChange(inObjectID, rate);
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (inData == NULL || inDataSize < sizeof(AudioStreamBasicDescription)) {
                return kAudioHardwareBadPropertySizeError;
            }
            AudioStreamBasicDescription format;
            memcpy(&format, inData, sizeof(format));
            /* Zmieniamy tylko częstotliwość -- reszta formatu jest
             * stała (Float32, packed, stereo) i nie negocjujemy jej. */
            if (format.mFormatID != kAudioFormatLinearPCM ||
                format.mChannelsPerFrame != kAIHeadset_ChannelCount ||
                format.mBitsPerChannel != kAIHeadset_BitsPerChannel) {
                return kAudioDeviceUnsupportedFormatError;
            }
            return RequestSampleRateChange(inObjectID, format.mSampleRate);
        }
        default:
            return kAudioHardwareIllegalOperationError;
    }
}
