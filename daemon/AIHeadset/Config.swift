import Foundation

/// Mirrors driver/src/config.h. Kept in sync by hand — the driver (C)
/// and daemon (Swift) don't share a build system in this phase, so
/// these constants are deliberately duplicated rather than bridged.
enum AIHeadsetConfig {
    static let deviceUID = "cat.sysop.aiheadset.device.72E2AC74-0B6E-4B5C-8582-B623D6979401"
    static let bridgeUID = "cat.sysop.aiheadset.bridge.335F98EA-9789-4034-8FFE-E46CBE7957AA"

    /// Faza 2.1 (plan): the daemon's private aggregate device combining
    /// the Bridge with whichever physical device is selected for
    /// monitoring. Never shown in the system's device pickers.
    static let aggregateUID = "cat.sysop.aiheadset.aggregate"
    static let aggregateName = "AI Headset Internal"

    static let channelCount = 2
    static let sampleRate: Double = 48000

    /// Plan section 3.3: ~2s playback jitter buffer for agent TTS,
    /// rounded up to a power of two (RingBuffer requires it).
    static let agentPlaybackCapacityFrames = 131072 // ~2.7s @ 48kHz

    /// Depth of the Bridge.in tap that feeds the resample/WS-send path
    /// (plan 2.2's "odnoga"). Generous relative to the 40-60ms chunks
    /// plan 3.4 calls for -- the send-side worker just needs to not
    /// starve while it drains this.
    static let uplinkCapacityFrames = 16384 // ~341ms @ 48kHz

    /// Bufory transkrypcji (mono): pompa czyta je co ~50 ms, więc
    /// ~1,4 s zapasu @ 48 kHz wystarcza z nawiązką.
    static let transcriptTapCapacityFrames = 65536

    /// Plan 6.5: consent-to-record announcement. A few seconds is
    /// plenty for a short sentence; rounded up to a power of two.
    static let announcementCapacityFrames = 262144 // ~5.5s @ 48kHz
}
