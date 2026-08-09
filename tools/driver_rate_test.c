/*
 * Test logiki zmiany częstotliwości w sterowniku, bez ładowania go do
 * coreaudiod. Awaria pluginu HAL zabija dźwięk w całym systemie, więc
 * ta ścieżka musi być sprawdzona zanim trafi na maszynę.
 *
 * Podstawiamy własny AudioServerPlugInHostInterface i sprawdzamy, że
 * sterownik prosi hosta o zmianę zamiast ruszać częstotliwość sam.
 */
#include "../driver/src/device.h"
#include <stdio.h>
#include <string.h>

static int gRequestCount = 0;
static UInt64 gLastRequestedAction = 0;
static AudioObjectID gLastRequestedDevice = 0;

static OSStatus MockPropertiesChanged(AudioServerPlugInHostRef inHost, AudioObjectID inObjectID,
                                       UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses)
{
    (void)inHost; (void)inObjectID; (void)inNumberAddresses; (void)inAddresses;
    return 0;
}
static OSStatus MockCopyFromStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef *o)
{ (void)h; (void)k; if (o) *o = NULL; return 0; }
static OSStatus MockWriteToStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d)
{ (void)h; (void)k; (void)d; return 0; }
static OSStatus MockDeleteFromStorage(AudioServerPlugInHostRef h, CFStringRef k)
{ (void)h; (void)k; return 0; }
static OSStatus MockRequestConfigChange(AudioServerPlugInHostRef inHost, AudioObjectID inDeviceObjectID,
                                         UInt64 inChangeAction, void *inChangeInfo)
{
    (void)inHost; (void)inChangeInfo;
    gRequestCount++;
    gLastRequestedAction = inChangeAction;
    gLastRequestedDevice = inDeviceObjectID;
    return 0;
}

static AudioServerPlugInHostInterface gMockHost = {
    MockPropertiesChanged,
    MockCopyFromStorage,
    MockWriteToStorage,
    MockDeleteFromStorage,
    MockRequestConfigChange,
};

static int gFailures = 0;
static void check(int condition, const char *what)
{
    printf("%s %s\n", condition ? "[OK]  " : "[FAIL]", what);
    if (!condition) gFailures++;
}

int main(void)
{
    AudioServerPlugInHostRef host = &gMockHost;
    AIHeadsetDevice_SetHost(host);
    AIHeadsetDevice_Initialize();

    printf("=== lista dostepnych czestotliwosci ===\n");
    AudioObjectPropertyAddress ratesAddr = {
        kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    AudioValueRange ranges[16];
    UInt32 written = 0;
    OSStatus st = AIHeadsetProperties_GetData(kObjectID_Device_Headset, &ratesAddr, 0, NULL,
                                               sizeof(ranges), &written, ranges);
    const int rateCount = (int)(written / sizeof(AudioValueRange));
    check(st == 0 && rateCount == kAIHeadset_SampleRateCount, "zwrocono wszystkie wspierane czestotliwosci");
    for (int i = 0; i < rateCount; i++) printf("       %.0f Hz\n", ranges[i].mMinimum);

    printf("=== czy czestotliwosc jest ustawialna ===\n");
    AudioObjectPropertyAddress rateAddr = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    Boolean settable = false;
    AIHeadsetProperties_IsSettable(kObjectID_Device_Headset, &rateAddr, &settable);
    check(settable, "NominalSampleRate zglaszany jako ustawialny");

    printf("=== zadanie zmiany na 16000 Hz (Bluetooth HFP) ===\n");
    gRequestCount = 0;
    Float64 newRate = 16000.0;
    st = AIHeadsetProperties_SetData(kObjectID_Device_Headset, &rateAddr, 0, NULL,
                                      sizeof(newRate), &newRate);
    check(st == 0, "SetData przyjete");
    check(gRequestCount == 2, "poproszono hosta o zmiane dla OBU urzadzen (sa zwiazane ring bufferami)");
    check(gLastRequestedAction == 16000, "przekazana czestotliwosc to 16000");
    check(gDevice.sampleRate == 48000.0, "czestotliwosc NIE zmieniona przed zgoda hosta");

    printf("=== host oddaje sterowanie ===\n");
    AIHeadsetDevice_PerformConfigChange(16000);
    check(gDevice.sampleRate == 16000.0, "czestotliwosc zastosowana po PerformConfigChange");

    const UInt64 ticks16k = gDevice.headsetClock.hostTicksPerRingBuffer;
    AIHeadsetDevice_PerformConfigChange(48000);
    const UInt64 ticks48k = gDevice.headsetClock.hostTicksPerRingBuffer;
    check(gDevice.sampleRate == 48000.0, "powrot na 48000 dziala");
    check(ticks16k > ticks48k * 2, "zegar przeliczony -- okres przy 16 kHz jest ~3x dluzszy");

    printf("=== format strumienia podaza za czestotliwoscia ===\n");
    AIHeadsetDevice_PerformConfigChange(44100);
    AudioObjectPropertyAddress fmtAddr = {
        kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    written = 0;
    AIHeadsetProperties_GetData(kObjectID_Stream_Headset_Output, &fmtAddr, 0, NULL,
                                 sizeof(fmt), &written, &fmt);
    check(fmt.mSampleRate == 44100.0, "strumien raportuje biezaca czestotliwosc");

    printf("=== odrzucanie niewspieranych wartosci ===\n");
    gRequestCount = 0;
    Float64 bogus = 96000.0;
    st = AIHeadsetProperties_SetData(kObjectID_Device_Headset, &rateAddr, 0, NULL,
                                      sizeof(bogus), &bogus);
    check(st == kAudioDeviceUnsupportedFormatError, "96000 Hz odrzucone");
    check(gRequestCount == 0, "host nie byl niepokojony przy zlej wartosci");

    printf("=== odpornosc na bledne wywolania ===\n");
    st = AIHeadsetProperties_SetData(kObjectID_Device_Headset, &rateAddr, 0, NULL, 2, &bogus);
    check(st == kAudioHardwareBadPropertySizeError, "za maly bufor odrzucony zamiast czytac poza zakresem");
    st = AIHeadsetProperties_SetData(kObjectID_Device_Headset, &rateAddr, 0, NULL, sizeof(bogus), NULL);
    check(st == kAudioHardwareBadPropertySizeError, "NULL odrzucony");

    printf("\n%s\n", gFailures == 0 ? "PASS" : "SOME FAILED");
    return gFailures == 0 ? 0 : 1;
}
