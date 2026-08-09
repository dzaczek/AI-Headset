/*
 * Standalone smoke test for Faza 1 step 3 (plan section 7): drives the
 * installed "AI Headset" / "AI Headset Bridge" pair through the public
 * CoreAudio HAL client API (not part of the plugin), and checks both
 * cross-wired legs from plan section 2:
 *
 *   Headset.out --RingA--> Bridge.in
 *   Bridge.out  --RingB--> Headset.in
 *
 * Not part of the driver or daemon; a throwaway dev diagnostic.
 */
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../driver/src/config.h"

#define TEST_CHANNELS         kAIHeadset_ChannelCount
#define TONE_FREQ_HZ           440.0
#define TONE_AMPLITUDE         0.5f
#define RECORD_SECONDS         2
#define MAX_SAMPLE_RATE        48000
#define RECORD_CAPACITY_FRAMES (MAX_SAMPLE_RATE * RECORD_SECONDS)

static _Atomic double   gPhase          = 0.0;
static Float64          gSampleRate     = 48000.0;
static float             gRecordBuffer[RECORD_CAPACITY_FRAMES * TEST_CHANNELS];
static _Atomic uint32_t gRecordedFrames = 0;

static void ResetTestState(void)
{
    gPhase = 0.0;
    gRecordedFrames = 0;
}

static OSStatus PlaybackIOProc(AudioObjectID inDevice,
                                const AudioTimeStamp *inNow,
                                const AudioBufferList *inInputData,
                                const AudioTimeStamp *inInputTime,
                                AudioBufferList *outOutputData,
                                const AudioTimeStamp *inOutputTime,
                                void *inClientData)
{
    (void)inDevice;
    (void)inNow;
    (void)inInputData;
    (void)inInputTime;
    (void)inOutputTime;
    (void)inClientData;

    const double phaseStep = 2.0 * M_PI * TONE_FREQ_HZ / gSampleRate;
    double phase = gPhase;

    for (UInt32 b = 0; b < outOutputData->mNumberBuffers; b++) {
        AudioBuffer *buf = &outOutputData->mBuffers[b];
        const UInt32 channels = buf->mNumberChannels;
        const UInt32 frames = buf->mDataByteSize / (UInt32)(channels * sizeof(float));
        float *data = (float *)buf->mData;
        double p = phase;
        for (UInt32 i = 0; i < frames; i++) {
            const float sample = (float)(TONE_AMPLITUDE * sin(p));
            for (UInt32 ch = 0; ch < channels; ch++) {
                data[i * channels + ch] = sample;
            }
            p += phaseStep;
        }
        if (b == 0) {
            phase += phaseStep * frames;
        }
    }
    gPhase = fmod(phase, 2.0 * M_PI);
    return noErr;
}

static OSStatus CaptureIOProc(AudioObjectID inDevice,
                               const AudioTimeStamp *inNow,
                               const AudioBufferList *inInputData,
                               const AudioTimeStamp *inInputTime,
                               AudioBufferList *outOutputData,
                               const AudioTimeStamp *inOutputTime,
                               void *inClientData)
{
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;
    (void)inOutputTime;
    (void)inClientData;

    /* This leg isn't playing anything on this device -- leave its
     * output silent so it doesn't pollute the ring buffer the other
     * leg's assertions don't care about. */
    for (UInt32 b = 0; b < outOutputData->mNumberBuffers; b++) {
        memset(outOutputData->mBuffers[b].mData, 0, outOutputData->mBuffers[b].mDataByteSize);
    }

    for (UInt32 b = 0; b < inInputData->mNumberBuffers; b++) {
        const AudioBuffer *buf = &inInputData->mBuffers[b];
        const UInt32 channels = buf->mNumberChannels;
        const UInt32 frames = buf->mDataByteSize / (UInt32)(channels * sizeof(float));
        const float *data = (const float *)buf->mData;

        const uint32_t recorded = atomic_load_explicit(&gRecordedFrames, memory_order_relaxed);
        const uint32_t space = (recorded < RECORD_CAPACITY_FRAMES) ? (RECORD_CAPACITY_FRAMES - recorded) : 0;
        const uint32_t toCopy = (frames < space) ? frames : space;
        if (toCopy > 0 && channels == TEST_CHANNELS) {
            memcpy(&gRecordBuffer[(size_t)recorded * TEST_CHANNELS],
                   data,
                   (size_t)toCopy * channels * sizeof(float));
            atomic_store_explicit(&gRecordedFrames, recorded + toCopy, memory_order_relaxed);
        }
    }

    return noErr;
}

/* kAudioHardwarePropertyDevices deliberately excludes hidden devices
 * (that's the whole point of kAudioDevicePropertyIsHidden -- plan
 * section 1.3) so the Bridge won't turn up by enumerating it. Ask the
 * HAL to resolve the UID directly instead; it routes to our plugin's
 * kAudioPlugInPropertyTranslateUIDToDevice regardless of hidden state. */
static AudioObjectID FindDeviceByUID(const char *uid)
{
    CFStringRef target = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, sizeof(target), &target, &size, &device);
    CFRelease(target);
    return device;
}

/* Plays a tone on playDevice's output and checks it arrives on
 * recordDevice's input. Returns 1 on pass, 0 on fail. */
static int RunLoopbackLeg(const char *label, AudioObjectID playDevice, AudioObjectID recordDevice)
{
    printf("\n=== %s ===\n", label);
    ResetTestState();

    Float64 rate = 0;
    UInt32 rateSize = sizeof(rate);
    AudioObjectPropertyAddress rateAddr = {
        kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(playDevice, &rateAddr, 0, NULL, &rateSize, &rate) == noErr && rate > 0) {
        gSampleRate = rate;
    }

    AudioDeviceIOProcID playProcID = NULL;
    AudioDeviceIOProcID recordProcID = NULL;

    OSStatus st = AudioDeviceCreateIOProcID(playDevice, PlaybackIOProc, NULL, &playProcID);
    if (st != noErr) {
        fprintf(stderr, "FAIL: AudioDeviceCreateIOProcID(play) error %d\n", (int)st);
        return 0;
    }
    st = AudioDeviceCreateIOProcID(recordDevice, CaptureIOProc, NULL, &recordProcID);
    if (st != noErr) {
        fprintf(stderr, "FAIL: AudioDeviceCreateIOProcID(record) error %d\n", (int)st);
        AudioDeviceDestroyIOProcID(playDevice, playProcID);
        return 0;
    }

    AudioDeviceStart(playDevice, playProcID);
    AudioDeviceStart(recordDevice, recordProcID);

    printf("Running for %d s (writing a %.0f Hz tone)...\n", RECORD_SECONDS, TONE_FREQ_HZ);
    sleep(RECORD_SECONDS);

    AudioDeviceStop(playDevice, playProcID);
    AudioDeviceStop(recordDevice, recordProcID);
    AudioDeviceDestroyIOProcID(playDevice, playProcID);
    AudioDeviceDestroyIOProcID(recordDevice, recordProcID);

    const uint32_t recorded = atomic_load_explicit(&gRecordedFrames, memory_order_relaxed);
    printf("Captured %u frames.\n", recorded);
    if (recorded < (uint32_t)(gSampleRate * 0.5)) {
        fprintf(stderr, "FAIL: too few frames captured -- devices may not be running IO\n");
        return 0;
    }

    uint32_t skip = (uint32_t)(gSampleRate * 0.3);
    if (skip >= recorded) {
        skip = 0;
    }
    double sumSquares = 0.0;
    uint32_t n = 0;
    for (uint32_t i = skip; i < recorded; i++) {
        for (uint32_t ch = 0; ch < TEST_CHANNELS; ch++) {
            const float s = gRecordBuffer[(size_t)i * TEST_CHANNELS + ch];
            sumSquares += (double)s * (double)s;
            n++;
        }
    }
    const double rms = (n > 0) ? sqrt(sumSquares / n) : 0.0;
    const double expectedRms = TONE_AMPLITUDE / sqrt(2.0);
    printf("Captured RMS = %.4f (expected ~%.4f)\n", rms, expectedRms);

    if (rms > expectedRms * 0.5 && rms < expectedRms * 1.5) {
        printf("PASS: %s\n", label);
        return 1;
    }
    fprintf(stderr, "FAIL: captured RMS (%.4f) not consistent with expected loopback (%.4f)\n", rms, expectedRms);
    return 0;
}

int main(void)
{
    const AudioObjectID headset = FindDeviceByUID(kAIHeadset_Device_UID);
    const AudioObjectID bridge  = FindDeviceByUID(kAIHeadset_Bridge_UID);

    if (headset == kAudioObjectUnknown) {
        fprintf(stderr, "FAIL: AI Headset device (UID %s) not found\n", kAIHeadset_Device_UID);
        return 1;
    }
    if (bridge == kAudioObjectUnknown) {
        fprintf(stderr, "FAIL: AI Headset Bridge device (UID %s) not found\n", kAIHeadset_Bridge_UID);
        return 1;
    }
    printf("AI Headset AudioObjectID = %u, AI Headset Bridge AudioObjectID = %u\n", headset, bridge);

    int passA = RunLoopbackLeg("Leg 1: Headset.out -> RingA -> Bridge.in", headset, bridge);
    int passB = RunLoopbackLeg("Leg 2: Bridge.out -> RingB -> Headset.in", bridge, headset);

    printf("\n%s\n", (passA && passB) ? "ALL PASS" : "SOME FAILED");
    return (passA && passB) ? 0 : 1;
}
