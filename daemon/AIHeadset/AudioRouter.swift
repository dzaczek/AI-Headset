import AudioToolbox
import CoreAudio
import Foundation

enum RouterMode {
    case pass
    case agent
    case mute
}

/// Faza 2.2/2.3 (plan): the single IOProc that runs on the daemon's
/// private aggregate device (physical device + hidden Bridge). Only
/// copies and mixes here -- no allocation, no locks held for longer
/// than a ring-buffer read/write, nothing that can block. Same
/// realtime hygiene as the plugin's own IO path (plan 1.6), because
/// this callback runs on the same kind of deadline-bound thread.
final class AudioRouter {
    private var ioProcID: AudioDeviceIOProcID?
    private let aggregateDeviceID: AudioDeviceID

    /// Read on the realtime IO thread, written from the control/main
    /// thread. A bare enum case with no associated values is a
    /// single-word store, so a plain var is safe here without a lock.
    var mode: RouterMode = .pass

    /// Plan 2.2 "odnoga": every IO cycle's Bridge.in (rozmówca) is
    /// copied here regardless of mode, for the resampler/WS-send path
    /// and for transcription. Plan section 1: "w obu trybach prowadzi
    /// transkrypcję" -- PASS mode still listens, it just doesn't talk.
    let uplinkBuffer = RingBuffer(frameCapacity: AIHeadsetConfig.uplinkCapacityFrames,
                                   channels: AIHeadsetConfig.channelCount)

    /// Transkrypcja słucha w każdym trybie, obu stron osobno -- dzięki
    /// temu wiadomo, kto mówi, bez rozpoznawania głosów. Mono, bo
    /// rozpoznawanie mowy i tak pracuje na jednym kanale; mikrofony bywają
    /// mono, strona rozmówców jest stereo.
    let callerTranscriptTap = RingBuffer(frameCapacity: AIHeadsetConfig.transcriptTapCapacityFrames, channels: 1)
    let micTranscriptTap = RingBuffer(frameCapacity: AIHeadsetConfig.transcriptTapCapacityFrames, channels: 1)
    /// Prealokowany: wątek IO nie może alokować.
    private var transcriptScratch = [Float](repeating: 0, count: 8192)

    /// AGENT mode's Bridge.out source. ElevenLabsClient (Faza 3) fills
    /// this from decoded `audio` events; `interruption` events should
    /// call `agentPlaybackBuffer.clear()`.
    let agentPlaybackBuffer = RingBuffer(frameCapacity: AIHeadsetConfig.agentPlaybackCapacityFrames,
                                          channels: AIHeadsetConfig.channelCount)

    /// Plan 6.5 consent-to-record announcement. Orthogonal to `mode`
    /// -- takes over Bridge.out whenever it has frames queued,
    /// regardless of PASS/AGENT/MUTE, because the announcement must
    /// play no matter what mode triggered it. ConsentAnnouncer fills
    /// this via local TTS.
    let announcementBuffer = RingBuffer(frameCapacity: AIHeadsetConfig.announcementCapacityFrames,
                                         channels: AIHeadsetConfig.channelCount)

    /// Testing-only hook: reports the RMS of what was read from
    /// Bridge.in and what was written to the physical monitoring
    /// output on the last IO cycle, so a test can assert the
    /// monitoring leg is wired correctly without duplicating the
    /// mixing logic. Nil by default, costs nothing in production.
    var onDebugSample: ((_ bridgeInRMS: Float, _ physicalOutRMS: Float) -> Void)?

    /// Live signal levels for the UI meters, with peak-hold decay so a
    /// menu refreshing a few times a second still shows something
    /// meaningful rather than whatever instantaneous sample it landed
    /// on. Written from the IO thread, read from the main thread: a
    /// plain Float is a single aligned word here, and a torn read on a
    /// VU meter would be invisible anyway -- not worth a lock on the
    /// realtime path.
    private(set) var uplinkLevel: Float = 0   // rozmówca -> agent
    private(set) var downlinkLevel: Float = 0 // agent -> rozmówca
    /// Poziom faktycznie zapisany do fizycznego wyjścia (słuchawek).
    /// Rozstrzyga pytanie "czy aplikacja w ogóle wysyła sygnał do
    /// słuchawek" bez zgadywania -- jeśli ten miernik się rusza, a nic
    /// nie słychać, problem jest poza aplikacją (profil BT, głośność,
    /// routing systemowy), a nie w routingu.
    private(set) var physicalOutLevel: Float = 0
    /// Poziom Twojego mikrofonu wchodzącego do routera (tryb PASS).
    /// Rozdziela "mikrofon jest cichy" od "poziom ginie dalej w torze".
    private(set) var micLevel: Float = 0

    /// Test wtryskujący ton PROSTO na fizyczne wyjście, z pominięciem
    /// Teamsa, sterownika i Bridge. Rozstrzyga jednoznacznie: jeśli
    /// tego nie słychać w słuchawkach, problem jest w naszej ścieżce
    /// wyjściowej albo w samym urządzeniu -- a nie gdzieś wyżej.
    private var testToneFramesRemaining = 0
    private var testTonePhase: Double = 0

    func playTestTone(seconds: Double = 2.0) {
        testTonePhase = 0
        testToneFramesRemaining = Int(seconds * sampleRate)
    }

    var isPlayingTestTone: Bool { testToneFramesRemaining > 0 }
    private let levelDecay: Float = 0.85

    private var previousMode: RouterMode = .pass
    /// 5ms ramp on AGENT -> anything-else (plan 2.3): stopping TTS
    /// must be instant, but an abrupt cut clicks, so the last bit of
    /// agent audio fades out instead of just disappearing.
    private let rampTotalFrames: Int
    private var rampFramesRemaining = 0

    /// Plan 2.2: "fizyczne wyjście ← Bridge.in + TTS agenta *
    /// monitorGain (żebyś słyszał, co mówi agent)". Bez tego nie wiesz,
    /// co agent mówi w Twoim imieniu -- a to jest tryb, w którym coś
    /// mówi Twoim głosem do klienta.
    ///
    /// Bufor jest prealokowany: ścieżka IO nie może alokować, a dźwięk
    /// agenta trzeba odczytać RAZ i użyć w dwóch miejscach (do rozmówcy
    /// i do słuchawek) -- dwukrotny odczyt z ring buffera zjadłby dane.
    private var agentScratch = [Float](repeating: 0, count: 8192 * 2)
    /// Głośność podsłuchu agenta względem rozmówcy. Docelowo
    /// regulowana w ustawieniach (plan 4).
    var agentMonitorGain: Float = 0.7

    /// Rzeczywista częstotliwość aggregate -- patrz
    /// AggregateDevice.actualSampleRate. Resampling do agenta i rampa
    /// muszą wychodzić od niej, nie od stałej z konfiguracji.
    let sampleRate: Double

    init(aggregateDeviceID: AudioDeviceID, sampleRate: Double = AIHeadsetConfig.sampleRate) {
        self.aggregateDeviceID = aggregateDeviceID
        self.sampleRate = sampleRate
        self.rampTotalFrames = max(1, Int(0.005 * sampleRate))
    }

    func start() throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) { [weak self] _, inInputData, _, outOutputData, _ in
            self?.process(inInputData: inInputData, outOutputData: outOutputData)
        }
        guard status == noErr, let procID else {
            throw AggregateDeviceError.creationFailed(status)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
            throw AggregateDeviceError.creationFailed(startStatus)
        }
    }

    func stop() {
        guard let procID = ioProcID else { return }
        AudioDeviceStop(aggregateDeviceID, procID)
        AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        ioProcID = nil
    }

    /// Jednorazowy zrzut układu buforów przy pierwszym cyklu IO. Cała
    /// logika routingu opiera się na założeniu, że Bridge jest OSTATNIM
    /// buforem po obu stronach; gdy to założenie nie zachodzi, dźwięk
    /// po prostu nie dociera i nie ma tego jak zobaczyć z zewnątrz.
    private var didLogLayout = false

    private func process(inInputData: UnsafePointer<AudioBufferList>, outOutputData: UnsafeMutablePointer<AudioBufferList>) {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let output = UnsafeMutableAudioBufferListPointer(outOutputData)
        let channels = AIHeadsetConfig.channelCount

        if !didLogLayout {
            didLogLayout = true
            let ins = input.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ", ")
            let outs = output.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ", ")
            Log.info("układ buforów IO -- wejścia [\(ins)] wyjścia [\(outs)]")
            if output.count < 2 {
                Log.error("tylko \(output.count) bufor(y) wyjściowe -- brak fizycznego wyjścia w aggregate, monitoring nie zadziała")
            }
            if input.isEmpty {
                Log.error("brak buforów wejściowych -- Bridge.in nie dociera")
            }
        }

        // The aggregate's stream order follows the sub-device list it
        // was created with ([physical, bridge]), so Bridge is always
        // the *last* buffer on each side. The physical device
        // contributes zero buffers on a side it has no channels for,
        // so the index can't be hardcoded as 0/1.
        for buffer in output {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        guard let bridgeOut = output.last else { return }

        // Transkrypcja: rozmówcy (Bridge.in) i mikrofon, w każdym trybie.
        feedTranscriptTaps(caller: input.last, mic: input.count > 1 ? input[0] : nil)

        var bridgeInRMS: Float = 0
        var physicalOutRMS: Float = 0

        if testToneFramesRemaining > 0 {
            // Ton testowy zastępuje monitoring na czas trwania testu.
            writeTestTone(into: output)
        } else if let bridgeIn = input.last {
            // Monitoring: rozmówca (Bridge.in) always goes to every
            // physical output buffer (plan 2.2 -- "zawsze: monitoring").
            for i in 0..<(output.count - 1) {
                copy(from: bridgeIn, to: output[i])
            }
            // Tap for the resampler/WS-send path -- always runs,
            // independent of mode (plan section 1: both modes transcribe).
            if let data = bridgeIn.mData {
                let frameCount = Int(bridgeIn.mDataByteSize) / (channels * MemoryLayout<Float>.size)
                uplinkBuffer.write(data.assumingMemoryBound(to: Float.self), frameCount: frameCount)
                uplinkLevel = max(rms(bridgeIn), uplinkLevel * levelDecay)
            }
            if onDebugSample != nil {
                bridgeInRMS = rms(bridgeIn)
            }
        }

        if previousMode == .agent && mode != .agent {
            rampFramesRemaining = rampTotalFrames
        }
        previousMode = mode

        let bridgeOutFrameCount = Int(bridgeOut.mDataByteSize) / (channels * MemoryLayout<Float>.size)
        if let dst = bridgeOut.mData?.assumingMemoryBound(to: Float.self) {
            if announcementBuffer.framesAvailable > 0 {
                // Consent announcement overrides everything else on
                // Bridge.out until it's done playing (plan 6.5).
                announcementBuffer.read(dst, frameCount: bridgeOutFrameCount)
            } else if rampFramesRemaining > 0 {
                rampAgentTail(into: dst, frameCount: bridgeOutFrameCount, channels: channels)
            } else {
                switch mode {
                case .pass:
                    if input.count > 1 {
                        // Physical mic contributed a buffer -> relay it.
                        copy(from: input[0], to: bridgeOut)
                        micLevel = max(rms(input[0]), micLevel * levelDecay)
                    } else {
                        micLevel *= levelDecay
                    }
                    // else: no physical input on this sub-device -- Bridge.out
                    // stays silent, which is the honest behavior.
                case .agent:
                    agentPlaybackBuffer.read(dst, frameCount: bridgeOutFrameCount)
                    // Ten sam materiał domieszany do słuchawek -- czytamy
                    // z bufora tylko raz, powyżej, i tu już tylko
                    // kopiujemy to, co trafiło do rozmówcy.
                    mixAgentIntoMonitoring(from: dst, frameCount: bridgeOutFrameCount,
                                            channels: channels, output: output)
                case .mute:
                    break // already zeroed above.
                }
            }
        }

        // Downlink meter reflects what actually reached Bridge.out --
        // i.e. what the far end hears from the agent, after mode
        // gating and ramping, not merely what arrived over the socket.
        if mode == .agent, let dst = bridgeOut.mData {
            var sum: Float = 0
            let count = Int(bridgeOut.mDataByteSize) / MemoryLayout<Float>.size
            if count > 0 {
                let samples = dst.assumingMemoryBound(to: Float.self)
                for i in 0..<count { sum += samples[i] * samples[i] }
                downlinkLevel = max((sum / Float(count)).squareRoot(), downlinkLevel * levelDecay)
            }
        } else {
            downlinkLevel *= levelDecay
        }

        // Poziom fizycznego wyjścia mierzymy raz, po zapisaniu
        // wszystkiego -- niezależnie od tego, czy grał monitoring, ton
        // testowy, czy nic. Pomiar zaszyty w jednej gałęzi milczał przy
        // pozostałych i sam w sobie fałszował diagnostykę.
        if output.count > 1 {
            physicalOutRMS = rms(output[0])
            physicalOutLevel = max(physicalOutRMS, physicalOutLevel * levelDecay)
        } else {
            physicalOutLevel *= levelDecay
        }

        onDebugSample?(bridgeInRMS, physicalOutRMS)
    }

    /// Wpisuje ton 440 Hz do wszystkich fizycznych buforów wyjściowych
    /// (czyli wszystkich poza Bridge, który jest ostatni).
    private func writeTestTone(into output: UnsafeMutableAudioBufferListPointer) {
        guard output.count > 1 else { return }
        let step = 2.0 * Double.pi * 440.0 / sampleRate
        var framesWritten = 0

        for i in 0..<(output.count - 1) {
            let buffer = output[i]
            guard let data = buffer.mData else { continue }
            let ch = Int(buffer.mNumberChannels)
            guard ch > 0 else { continue }
            let dst = data.assumingMemoryBound(to: Float.self)
            let frames = min(Int(buffer.mDataByteSize) / (ch * MemoryLayout<Float>.size),
                              testToneFramesRemaining)
            var phase = testTonePhase
            for f in 0..<frames {
                let sample = Float(0.35 * sin(phase))
                for c in 0..<ch { dst[f * ch + c] = sample }
                phase += step
            }
            framesWritten = max(framesWritten, frames)
            if i == output.count - 2 { testTonePhase = phase }
        }
        testToneFramesRemaining = max(0, testToneFramesRemaining - framesWritten)
    }

    /// Domieszuje głos agenta do wszystkich fizycznych wyjść, na
    /// wierzch monitoringu rozmówcy (który jest już tam wpisany).
    /// Sumujemy z ograniczeniem, żeby suma dwóch głosów nie przesterowała.
    /// Wewnętrzne (nie prywatne), żeby dało się to sprawdzić bez
    /// urządzenia audio -- test z prawdziwym aggregate wymaga wolnego
    /// CoreAudio, a sama arytmetyka miksowania jest testowalna wprost.
    func mixAgentIntoMonitoring(from source: UnsafePointer<Float>,
                                         frameCount: Int,
                                         channels: Int,
                                         output: UnsafeMutableAudioBufferListPointer) {
        guard output.count > 1, agentMonitorGain > 0 else { return }

        for i in 0..<(output.count - 1) {
            let buffer = output[i]
            guard let data = buffer.mData else { continue }
            let dstChannels = Int(buffer.mNumberChannels)
            guard dstChannels > 0 else { continue }
            let dst = data.assumingMemoryBound(to: Float.self)
            let dstFrames = Int(buffer.mDataByteSize) / (dstChannels * MemoryLayout<Float>.size)
            let frames = min(frameCount, dstFrames)

            for f in 0..<frames {
                // Źródło jest w formacie Bridge (stereo); przy wyjściu
                // mono uśredniamy, jak w copy().
                var sample: Float = 0
                if channels == 1 {
                    sample = source[f]
                } else {
                    var sum: Float = 0
                    for c in 0..<channels { sum += source[f * channels + c] }
                    sample = sum / Float(channels)
                }
                sample *= agentMonitorGain

                for c in 0..<dstChannels {
                    let idx = f * dstChannels + c
                    let mixed = dst[idx] + sample
                    dst[idx] = max(-1.0, min(1.0, mixed))
                }
            }
        }
    }

    private func rampAgentTail(into dst: UnsafeMutablePointer<Float>, frameCount: Int, channels: Int) {
        var scratch = [Float](repeating: 0, count: frameCount * channels)
        scratch.withUnsafeMutableBufferPointer { buf in
            agentPlaybackBuffer.read(buf.baseAddress!, frameCount: frameCount)
        }
        for i in 0..<frameCount {
            guard rampFramesRemaining > 0 else {
                break // rest of dst is already silence from the memset above.
            }
            let gain = Float(rampFramesRemaining) / Float(rampTotalFrames)
            for ch in 0..<channels {
                dst[i * channels + ch] = scratch[i * channels + ch] * gain
            }
            rampFramesRemaining -= 1
        }
    }

    /// Kopiuje z uwzględnieniem liczby kanałów. Surowe `memcpy` działa
    /// tylko wtedy, gdy oba bufory mają ten sam układ -- a to nie jest
    /// regułą: mikrofony bywają mono (wbudowany w MacBooku, każdy
    /// zestaw Bluetooth w profilu HFP), podczas gdy Bridge jest zawsze
    /// stereo. Wpisanie mono w stereo bajt w bajt daje szum i połowę
    /// bufora ciszy.
    /// Wywoływane z wątku IO; osobno dostępne dla testów.
    func feedTranscriptTaps(caller: AudioBuffer?, mic: AudioBuffer?) {
        if let caller { writeMono(caller, to: callerTranscriptTap) }
        if let mic { writeMono(mic, to: micTranscriptTap) }
    }

    private func writeMono(_ buffer: AudioBuffer, to tap: RingBuffer) {
        guard let data = buffer.mData else { return }
        let channelCount = Int(buffer.mNumberChannels)
        guard channelCount > 0 else { return }
        let src = data.assumingMemoryBound(to: Float.self)
        let frames = min(Int(buffer.mDataByteSize) / (channelCount * MemoryLayout<Float>.size), transcriptScratch.count)
        guard frames > 0 else { return }
        if channelCount == 1 {
            tap.write(src, frameCount: frames)
            return
        }
        transcriptScratch.withUnsafeMutableBufferPointer { dst in
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channelCount { sum += src[i * channelCount + ch] }
                dst[i] = sum / Float(channelCount)
            }
            tap.write(dst.baseAddress!, frameCount: frames)
        }
    }

    private func copy(from source: AudioBuffer, to destination: AudioBuffer) {
        guard let srcData = source.mData, let dstData = destination.mData else { return }
        let srcChannels = Int(source.mNumberChannels)
        let dstChannels = Int(destination.mNumberChannels)
        guard srcChannels > 0, dstChannels > 0 else { return }

        if srcChannels == dstChannels {
            memcpy(dstData, srcData, Int(min(source.mDataByteSize, destination.mDataByteSize)))
            return
        }

        let src = srcData.assumingMemoryBound(to: Float.self)
        let dst = dstData.assumingMemoryBound(to: Float.self)
        let srcFrames = Int(source.mDataByteSize) / (srcChannels * MemoryLayout<Float>.size)
        let dstFrames = Int(destination.mDataByteSize) / (dstChannels * MemoryLayout<Float>.size)
        let frames = min(srcFrames, dstFrames)

        if srcChannels == 1 {
            // Mono -> wszystkie kanały docelowe.
            for i in 0..<frames {
                let sample = src[i]
                for ch in 0..<dstChannels { dst[i * dstChannels + ch] = sample }
            }
        } else if dstChannels == 1 {
            // Wielokanałowe -> mono: średnia, żeby nie zgubić strony.
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<srcChannels { sum += src[i * srcChannels + ch] }
                dst[i] = sum / Float(srcChannels)
            }
        } else {
            // Inne kombinacje: kopiuj wspólne kanały, resztę zostaw ciszą.
            let common = min(srcChannels, dstChannels)
            for i in 0..<frames {
                for ch in 0..<common { dst[i * dstChannels + ch] = src[i * srcChannels + ch] }
            }
        }
    }

    private func rms(_ buffer: AudioBuffer) -> Float {
        guard let data = buffer.mData else { return 0 }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return 0 }
        let samples = data.assumingMemoryBound(to: Float.self)
        var sum: Float = 0
        for i in 0..<count {
            sum += samples[i] * samples[i]
        }
        return (sum / Float(count)).squareRoot()
    }
}
