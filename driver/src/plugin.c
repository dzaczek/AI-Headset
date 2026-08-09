/*
 * CFPlugIn entry point + AudioServerPlugInDriverInterface vtable.
 * This file is pure COM/CFPlugIn boilerplate and object-graph wiring;
 * all device behavior (properties, clock, IO) lives in device.c
 * (plan section 4 file layout).
 */
#include "device.h"

#pragma mark - Forward declarations (must match AudioServerPlugInDriverInterface exactly)

static HRESULT AIHeadset_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG   AIHeadset_AddRef(void *inDriver);
static ULONG   AIHeadset_Release(void *inDriver);

static OSStatus AIHeadset_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus AIHeadset_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                        CFDictionaryRef inDescription,
                                        const AudioServerPlugInClientInfo *inClientInfo,
                                        AudioObjectID *outDeviceObjectID);
static OSStatus AIHeadset_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus AIHeadset_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inDeviceObjectID,
                                           const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus AIHeadset_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inDeviceObjectID,
                                              const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus AIHeadset_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                             AudioObjectID inDeviceObjectID,
                                                             UInt64 inChangeAction,
                                                             void *inChangeInfo);
static OSStatus AIHeadset_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                            AudioObjectID inDeviceObjectID,
                                                            UInt64 inChangeAction,
                                                            void *inChangeInfo);

static Boolean AIHeadset_HasProperty(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress);
static OSStatus AIHeadset_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inObjectID,
                                              pid_t inClientProcessID,
                                              const AudioObjectPropertyAddress *inAddress,
                                              Boolean *outIsSettable);
static OSStatus AIHeadset_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inObjectID,
                                               pid_t inClientProcessID,
                                               const AudioObjectPropertyAddress *inAddress,
                                               UInt32 inQualifierDataSize,
                                               const void *inQualifierData,
                                               UInt32 *outDataSize);
static OSStatus AIHeadset_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress *inAddress,
                                           UInt32 inQualifierDataSize,
                                           const void *inQualifierData,
                                           UInt32 inDataSize,
                                           UInt32 *outDataSize,
                                           void *outData);
static OSStatus AIHeadset_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress *inAddress,
                                           UInt32 inQualifierDataSize,
                                           const void *inQualifierData,
                                           UInt32 inDataSize,
                                           const void *inData);

static OSStatus AIHeadset_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus AIHeadset_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus AIHeadset_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inDeviceObjectID,
                                            UInt32 inClientID,
                                            Float64 *outSampleTime,
                                            UInt64 *outHostTime,
                                            UInt64 *outSeed);
static OSStatus AIHeadset_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                             AudioObjectID inDeviceObjectID,
                                             UInt32 inClientID,
                                             UInt32 inOperationID,
                                             Boolean *outWillDo,
                                             Boolean *outWillDoInPlace);
static OSStatus AIHeadset_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inDeviceObjectID,
                                            UInt32 inClientID,
                                            UInt32 inOperationID,
                                            UInt32 inIOBufferFrameSize,
                                            const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus AIHeadset_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID,
                                         AudioObjectID inStreamObjectID,
                                         UInt32 inClientID,
                                         UInt32 inOperationID,
                                         UInt32 inIOBufferFrameSize,
                                         const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                         void *ioMainBuffer,
                                         void *ioSecondaryBuffer);
static OSStatus AIHeadset_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inDeviceObjectID,
                                          UInt32 inClientID,
                                          UInt32 inOperationID,
                                          UInt32 inIOBufferFrameSize,
                                          const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

#pragma mark - The COM object

/* Classic CFPlugIn COM layout: the first field of "the object" is a
 * pointer to the vtable, and AudioServerPlugInDriverRef is a pointer
 * to that field — i.e. a pointer to a pointer to the vtable. A static
 * singleton is enough here: coreaudiod loads one instance of this
 * plug-in per process. */
static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    AIHeadset_QueryInterface,
    AIHeadset_AddRef,
    AIHeadset_Release,
    AIHeadset_Initialize,
    AIHeadset_CreateDevice,
    AIHeadset_DestroyDevice,
    AIHeadset_AddDeviceClient,
    AIHeadset_RemoveDeviceClient,
    AIHeadset_PerformDeviceConfigurationChange,
    AIHeadset_AbortDeviceConfigurationChange,
    AIHeadset_HasProperty,
    AIHeadset_IsPropertySettable,
    AIHeadset_GetPropertyDataSize,
    AIHeadset_GetPropertyData,
    AIHeadset_SetPropertyData,
    AIHeadset_StartIO,
    AIHeadset_StopIO,
    AIHeadset_GetZeroTimeStamp,
    AIHeadset_WillDoIOOperation,
    AIHeadset_BeginIOOperation,
    AIHeadset_DoIOOperation,
    AIHeadset_EndIOOperation,
};

static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef        gDriverRef    = &gInterfacePtr;
static ULONG                             gRefCount     = 1;
static AudioServerPlugInHostRef          gHost         = NULL;

#pragma mark - Factory (referenced by name from Info.plist CFPlugInFactories)

void *AIHeadset_Create(CFAllocatorRef allocator, CFUUIDRef typeUUID);

void *AIHeadset_Create(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    (void)allocator;
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    gRefCount += 1;
    return gDriverRef;
}

#pragma mark - IUnknown

static HRESULT AIHeadset_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
    (void)inDriver;
    if (outInterface == NULL) {
        return E_NOINTERFACE;
    }
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) {
        return E_NOINTERFACE;
    }
    HRESULT result = 0;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        gRefCount += 1;
        *outInterface = gDriverRef;
    } else {
        result = E_NOINTERFACE;
    }
    CFRelease(requested);
    return result;
}

static ULONG AIHeadset_AddRef(void *inDriver)
{
    (void)inDriver;
    gRefCount += 1;
    return gRefCount;
}

static ULONG AIHeadset_Release(void *inDriver)
{
    (void)inDriver;
    if (gRefCount > 0) {
        gRefCount -= 1;
    }
    return gRefCount;
}

#pragma mark - Basic operations

static OSStatus AIHeadset_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    gHost = inHost;
    AIHeadsetDevice_SetHost(inHost);
    AIHeadsetDevice_Initialize();
    return noErr;
}

static OSStatus AIHeadset_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                        CFDictionaryRef inDescription,
                                        const AudioServerPlugInClientInfo *inClientInfo,
                                        AudioObjectID *outDeviceObjectID)
{
    (void)inDriver;
    (void)inDescription;
    (void)inClientInfo;
    (void)outDeviceObjectID;
    /* This slice only publishes the one static device from Initialize(). */
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AIHeadset_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AIHeadset_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inDeviceObjectID,
                                           const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientInfo;
    return noErr;
}

static OSStatus AIHeadset_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inDeviceObjectID,
                                              const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientInfo;
    return noErr;
}

static OSStatus AIHeadset_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                             AudioObjectID inDeviceObjectID,
                                                             UInt64 inChangeAction,
                                                             void *inChangeInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inChangeInfo;
    /* Host zatrzymał IO i pozwala zastosować zmianę -- to jedyny
     * moment, w którym wolno ruszyć częstotliwość. */
    return AIHeadsetDevice_PerformConfigChange(inChangeAction);
}

static OSStatus AIHeadset_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                            AudioObjectID inDeviceObjectID,
                                                            UInt64 inChangeAction,
                                                            void *inChangeInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inChangeAction;
    (void)inChangeInfo;
    return noErr;
}

#pragma mark - Property operations (delegate to device.c)

static Boolean AIHeadset_HasProperty(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress)
{
    (void)inDriver;
    (void)inClientProcessID;
    return AIHeadsetProperties_HasProperty(inObjectID, inAddress);
}

static OSStatus AIHeadset_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inObjectID,
                                              pid_t inClientProcessID,
                                              const AudioObjectPropertyAddress *inAddress,
                                              Boolean *outIsSettable)
{
    (void)inDriver;
    (void)inClientProcessID;
    return AIHeadsetProperties_IsSettable(inObjectID, inAddress, outIsSettable);
}

static OSStatus AIHeadset_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inObjectID,
                                               pid_t inClientProcessID,
                                               const AudioObjectPropertyAddress *inAddress,
                                               UInt32 inQualifierDataSize,
                                               const void *inQualifierData,
                                               UInt32 *outDataSize)
{
    (void)inDriver;
    (void)inClientProcessID;
    return AIHeadsetProperties_GetDataSize(inObjectID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
}

static OSStatus AIHeadset_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress *inAddress,
                                           UInt32 inQualifierDataSize,
                                           const void *inQualifierData,
                                           UInt32 inDataSize,
                                           UInt32 *outDataSize,
                                           void *outData)
{
    (void)inDriver;
    (void)inClientProcessID;
    return AIHeadsetProperties_GetData(inObjectID, inAddress, inQualifierDataSize, inQualifierData,
                                        inDataSize, outDataSize, outData);
}

static OSStatus AIHeadset_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress *inAddress,
                                           UInt32 inQualifierDataSize,
                                           const void *inQualifierData,
                                           UInt32 inDataSize,
                                           const void *inData)
{
    (void)inDriver;
    (void)inClientProcessID;
    return AIHeadsetProperties_SetData(inObjectID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData);
}

#pragma mark - IO operations (delegate to device.c)

static OSStatus AIHeadset_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver;
    return AIHeadsetDevice_StartIO(inDeviceObjectID, inClientID);
}

static OSStatus AIHeadset_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver;
    return AIHeadsetDevice_StopIO(inDeviceObjectID, inClientID);
}

static OSStatus AIHeadset_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inDeviceObjectID,
                                            UInt32 inClientID,
                                            Float64 *outSampleTime,
                                            UInt64 *outHostTime,
                                            UInt64 *outSeed)
{
    (void)inDriver;
    (void)inClientID;
    return AIHeadsetDevice_GetZeroTimeStamp(inDeviceObjectID, outSampleTime, outHostTime, outSeed);
}

static OSStatus AIHeadset_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                             AudioObjectID inDeviceObjectID,
                                             UInt32 inClientID,
                                             UInt32 inOperationID,
                                             Boolean *outWillDo,
                                             Boolean *outWillDoInPlace)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    return AIHeadsetDevice_WillDoIOOperation(inOperationID, outWillDo, outWillDoInPlace);
}

static OSStatus AIHeadset_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inDeviceObjectID,
                                            UInt32 inClientID,
                                            UInt32 inOperationID,
                                            UInt32 inIOBufferFrameSize,
                                            const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return noErr;
}

static OSStatus AIHeadset_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID,
                                         AudioObjectID inStreamObjectID,
                                         UInt32 inClientID,
                                         UInt32 inOperationID,
                                         UInt32 inIOBufferFrameSize,
                                         const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                         void *ioMainBuffer,
                                         void *ioSecondaryBuffer)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    (void)inIOCycleInfo;
    (void)ioSecondaryBuffer;
    return AIHeadsetDevice_DoIOOperation(inStreamObjectID, inOperationID, inIOBufferFrameSize, ioMainBuffer);
}

static OSStatus AIHeadset_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inDeviceObjectID,
                                          UInt32 inClientID,
                                          UInt32 inOperationID,
                                          UInt32 inIOBufferFrameSize,
                                          const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return noErr;
}
