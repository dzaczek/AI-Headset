import AVFoundation
import Foundation

/// Plan section 3 wiring: connects ElevenLabsClient + Resampler to
/// AudioRouter's AGENT-mode buffers.
///
///   uplink:   router.uplinkBuffer -> resample -> client.sendAudioChunk   (every ~50ms, plan 3.4)
///   downlink: client `audio` event -> resample -> router.agentPlaybackBuffer
///   `interruption` -> router.agentPlaybackBuffer.clear() (plan 3.3)
///
/// NOT wired into MenuBarController yet: that requires a real
/// signed-URL endpoint or agent_id/API-key source, which plan section
/// 3.1 explicitly says must come from the caller's own backend (never
/// store the API key in the app). No such backend exists yet, so
/// wiring this into the running UI would mean fabricating credentials
/// handling that hasn't been decided. This class is ready to use once
/// that decision is made -- pass a real `signedURLProvider` and call
/// `start()`.
final class AgentSession: ElevenLabsClientDelegate {
    /// Surfaced so the UI can show the *agent's* connection state
    /// separately from the audio device state -- they're unrelated and
    /// conflating them is confusing.
    var onStateChange: ((AgentConnectionState) -> Void)?
    private(set) var state: AgentConnectionState = .disconnected

    /// Plan section 3 acceptance test: "Zmierzona latencja tury (koniec
    /// mowy rozmówcy → pierwszy sample TTS) < 1 s". Measured from the
    /// `user_transcript` event (the server's own signal that it
    /// finished transcribing the caller's utterance) to the first
    /// `audio` event of the reply.
    private(set) var lastTurnLatency: TimeInterval?
    var onTurnLatency: ((TimeInterval) -> Void)?

    /// Turn state, consumed by DeadMansSwitch (plan 6.1). True from
    /// the moment the caller's utterance is transcribed until the
    /// agent's reply has finished playing out.
    private(set) var expectingAgentSpeech = false
    private(set) var lastAudioActivity = Date()
    private var turnStartedAt: Date?
    private var agentStartedSpeaking = false

    private let client: ElevenLabsClient
    private let router: AudioRouter
    private let uplinkResampler: Resampler
    private let downlinkResampler: Resampler
    private var uplinkTimer: DispatchSourceTimer?
    private let uplinkQueue = DispatchQueue(label: "cat.sysop.aiheadset.agent-uplink")
    /// Reused for the plan 6.2 deflection message too -- it's just
    /// "synthesize this text into announcementBuffer," which is the
    /// same job regardless of which message it's playing.
    private let announcer: ConsentAnnouncer

    init(router: AudioRouter, signedURLProvider: @escaping () async throws -> URL) throws {
        self.router = router
        self.uplinkResampler = try Resampler.deviceToAgent(deviceSampleRate: router.sampleRate)
        self.downlinkResampler = try Resampler.agentToDevice(deviceSampleRate: router.sampleRate)
        self.announcer = ConsentAnnouncer(router: router)
        self.client = ElevenLabsClient(signedURLProvider: signedURLProvider)
        self.client.delegate = self
    }

    func start() {
        client.connect()
        startUplinkPump()
    }

    func stop() {
        stopUplinkPump()
        client.disconnect()
    }

    /// Podpowiedź wstrzykiwana w trakcie rozmowy -- agent uwzględni ją
    /// przy następnej wypowiedzi, nie przerywając bieżącej.
    func sendHint(_ text: String) {
        client.sendContextualUpdate(text)
        Log.info("podpowiedź do agenta: \(text)")
    }

    var isConnected: Bool { state == .connected }

    // MARK: - Uplink: Bridge.in (via router.uplinkBuffer) -> agent

    private func startUplinkPump() {
        let timer = DispatchSource.makeTimerSource(queue: uplinkQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50)) // plan 3.4: 40-60ms chunks
        timer.setEventHandler { [weak self] in self?.pumpUplink() }
        timer.resume()
        uplinkTimer = timer
    }

    private func stopUplinkPump() {
        uplinkTimer?.cancel()
        uplinkTimer = nil
    }

    private func pumpUplink() {
        let framesAvailable = router.uplinkBuffer.framesAvailable
        guard framesAvailable > 0 else { return }

        var interleaved = [Float](repeating: 0, count: framesAvailable * AIHeadsetConfig.channelCount)
        interleaved.withUnsafeMutableBufferPointer { buf in
            router.uplinkBuffer.read(buf.baseAddress!, frameCount: framesAvailable)
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: router.sampleRate,
                                          channels: AVAudioChannelCount(AIHeadsetConfig.channelCount)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesAvailable)),
              let channelData = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(framesAvailable)

        for ch in 0..<AIHeadsetConfig.channelCount {
            for i in 0..<framesAvailable {
                channelData[ch][i] = interleaved[i * AIHeadsetConfig.channelCount + ch]
            }
        }

        guard let resampled = try? uplinkResampler.convert(buffer),
              let int16Data = resampled.int16ChannelData else { return }
        let byteCount = Int(resampled.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return }
        let data = Data(bytes: int16Data[0], count: byteCount)
        client.sendAudioChunk(data)
    }

    // MARK: - ElevenLabsClientDelegate (downlink: agent -> router.agentPlaybackBuffer)

    func elevenLabsClient(_ client: ElevenLabsClient, didChangeState state: AgentConnectionState) {
        self.state = state
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    func elevenLabsClient(_ client: ElevenLabsClient, didReceiveAudio pcm16Mono16k: Data) {
        lastAudioActivity = Date()
        if let started = turnStartedAt, !agentStartedSpeaking {
            agentStartedSpeaking = true
            let latency = Date().timeIntervalSince(started)
            lastTurnLatency = latency
            turnStartedAt = nil
            DispatchQueue.main.async { [weak self] in
                self?.onTurnLatency?(latency)
            }
        }

        let frameCount = pcm16Mono16k.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let dst = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        pcm16Mono16k.withUnsafeBytes { raw in
            if let src = raw.bindMemory(to: Int16.self).baseAddress {
                dst.update(from: src, count: frameCount)
            }
        }

        guard let resampled = try? downlinkResampler.convert(buffer),
              let floatData = resampled.floatChannelData else { return }
        let frames = Int(resampled.frameLength)
        var interleaved = [Float](repeating: 0, count: frames * AIHeadsetConfig.channelCount)
        for ch in 0..<Int(resampled.format.channelCount) {
            for i in 0..<frames {
                interleaved[i * AIHeadsetConfig.channelCount + ch] = floatData[ch][i]
            }
        }
        interleaved.withUnsafeBufferPointer { buf in
            router.agentPlaybackBuffer.write(buf.baseAddress!, frameCount: frames)
        }
    }

    func elevenLabsClientDidReceiveInterruption(_ client: ElevenLabsClient) {
        router.agentPlaybackBuffer.clear() // plan 3.3
        // The caller cut the agent off -- the turn is over, and the
        // now-empty playback queue must not read as a fault.
        expectingAgentSpeech = false
        agentStartedSpeaking = false
        turnStartedAt = nil
    }

    func elevenLabsClient(_ client: ElevenLabsClient, didReceiveUserTranscript text: String) {
        // The caller's utterance has been transcribed -- from here the
        // agent owes a reply, and the clock for both turn latency and
        // the dead man's switch starts running.
        turnStartedAt = Date()
        agentStartedSpeaking = false
        expectingAgentSpeech = true
        lastAudioActivity = Date()
    }

    /// Called by whoever owns the playback buffer (MenuBarController's
    /// poll) once the agent's reply has drained -- ends the turn so
    /// the dead man's switch stops watching until the next one.
    func noteAgentFinishedSpeaking() {
        guard agentStartedSpeaking else { return }
        expectingAgentSpeech = false
        agentStartedSpeaking = false
    }

    func elevenLabsClient(_ client: ElevenLabsClient, didReceiveAgentResponse text: String) {
        // Transcript.swift will consume this once a session is wired in.
        if CommitmentFilter.containsCommitment(text) {
            // Plan 6.2: interrupt whatever's mid-playback immediately,
            // then substitute the deflection line.
            router.agentPlaybackBuffer.clear()
            announcer.announce(text: CommitmentFilter.deflectionMessage) {}
        }
    }

    func elevenLabsClient(_ client: ElevenLabsClient, didReceiveVADScore score: Double) {
        // Optional UI surfacing (plan 3.2); no-op for now.
    }
}
