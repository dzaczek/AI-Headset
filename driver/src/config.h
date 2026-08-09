#ifndef AIHEADSET_CONFIG_H
#define AIHEADSET_CONFIG_H

/*
 * Stable identifiers. Generated once via `uuidgen`.
 * NEVER change these UIDs after first install — apps (Zoom, Teams,
 * Signal, CoreAudio itself) remember device selection by this string,
 * not by name.
 *
 * This is PHASE 1 STEP 3 of the build order (plan section 7): the
 * "AI Headset" / "AI Headset Bridge" pair, cross-wired by two ring
 * buffers (plan section 2). Step 2 (single self-looping device) is
 * what validated the plugin skeleton before this split.
 */

#define kAIHeadset_Driver_BundleID  "cat.sysop.aiheadset.driver"
#define kAIHeadset_Daemon_BundleID  "cat.sysop.aiheadset"

#define kAIHeadset_Device_UID       "cat.sysop.aiheadset.device.72E2AC74-0B6E-4B5C-8582-B623D6979401"
#define kAIHeadset_Device_Name      "AI Headset"

#define kAIHeadset_Bridge_UID       "cat.sysop.aiheadset.bridge.335F98EA-9789-4034-8FFE-E46CBE7957AA"
#define kAIHeadset_Bridge_Name      "AI Headset Bridge"

#define kAIHeadset_Manufacturer     "sysop.cat"

/* Ring buffer size in frames. Must stay a power of two — ringbuffer.c
 * masks the index instead of using modulo. Also reported verbatim as
 * kAudioDevicePropertyZeroTimeStampPeriod. */
#define kRingBufferFrames           16384u

/* The plan (section 1.3) argued for only 44.1/48 kHz, since every extra
 * rate is another path to test. Real hardware overruled that: a
 * Bluetooth headset in the hands-free profile forces the whole
 * aggregate to 16 kHz, and a device that refuses to follow simply stops
 * passing audio. AirPods, Jabra, Sony — all of them do this. So the
 * driver now follows whatever rate it is asked for, out of this list. */
#define kAIHeadset_SampleRate_Default 48000.0

#define kAIHeadset_SampleRateCount  5
#define kAIHeadset_SampleRates      { 16000.0, 24000.0, 32000.0, 44100.0, 48000.0 }

#define kAIHeadset_ChannelCount     2u
/* Float32, matches the HAL's canonical internal format. */
#define kAIHeadset_BitsPerChannel   32u

/* TODO(faza-1 acceptance test): plan section 1.3 warns that reporting
 * zero here causes Zoom/Teams to randomly duck the user's mic because
 * their AEC misjudges the loopback path. These are placeholder values
 * (one typical IO cycle at 48 kHz) — confirm/tune once real Zoom/Teams
 * calls are run against the device. */
#define kAIHeadset_Latency_Frames       0u
#define kAIHeadset_SafetyOffset_Frames  128u

#endif /* AIHEADSET_CONFIG_H */
