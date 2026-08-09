import CoreAudio
import Foundation

/// Plan section 6.3: "Drift narasta powoli i objawia się dopiero po
/// 20 minutach klikaniem" -- catch it early by comparing the
/// aggregate's own sample-time progress (`AudioDeviceGetCurrentTime`)
/// against `mach_absolute_time` every 10s. >0.5% logs, >2% triggers a
/// rebuild.
final class ClockWatchdog {
    private let aggregateDeviceID: () -> AudioDeviceID?
    private let onRebuildNeeded: () -> Void
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "cat.sysop.aiheadset.clock-watchdog")

    private var baseline: (hostTime: UInt64, sampleTime: Float64)?
    private var rebuildAttempts = 0
    private var gaveUpReported = false
    private let maxRebuildAttempts = 3
    private let timebaseInfo: mach_timebase_info_data_t

    init(aggregateDeviceID: @escaping () -> AudioDeviceID?, onRebuildNeeded: @escaping () -> Void) {
        self.aggregateDeviceID = aggregateDeviceID
        self.onRebuildNeeded = onRebuildNeeded
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.timebaseInfo = info
    }

    func start() {
        rebuildAttempts = 0
        gaveUpReported = false
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        baseline = nil
    }

    private func check() {
        guard let deviceID = aggregateDeviceID(), let current = currentTime(of: deviceID) else {
            return
        }
        guard let baseline else {
            self.baseline = current
            return
        }

        let hostTicksElapsed = current.hostTime &- baseline.hostTime
        let expectedSeconds = machTicksToSeconds(hostTicksElapsed)

        // Częstotliwość MUSI być odczytana z urządzenia, nie założona.
        // Zestaw Bluetooth w profilu HFP wymusza na aggregate 16 kHz;
        // przy zaszytych 48 kHz wychodziło stąd pozorne 66,67% dryfu,
        // watchdog przebudowywał aggregate co 10 s i sam kasował
        // dźwięk, który miał chronić.
        guard let rate = nominalSampleRate(of: deviceID), rate > 0 else {
            self.baseline = current
            return
        }
        let sampleSecondsElapsed = (current.sampleTime - baseline.sampleTime) / rate
        self.baseline = current

        guard expectedSeconds > 0.5 else { return } // avoid noise on a too-short interval
        let deviation = abs(sampleSecondsElapsed - expectedSeconds) / expectedSeconds

        if deviation > 0.02 {
            // Bezpiecznik: przebudowa aggregate jest kosztowna (przerwa
            // w dźwięku) i sama zeruje zegar, więc błędna detekcja
            // potrafi się zapętlić -- co się już zdarzyło, gdy
            // częstotliwość była zaszyta na sztywno. Po kilku
            // nieskutecznych próbach lepiej zostawić dźwięk w spokoju
            // i zgłosić to raz, niż kasować go w kółko.
            guard rebuildAttempts < maxRebuildAttempts else {
                if !gaveUpReported {
                    gaveUpReported = true
                    Log.error("dryf \(String(format: "%.2f", deviation * 100))% utrzymuje się po \(maxRebuildAttempts) przebudowach -- przerywam, żeby nie kasować dźwięku w pętli")
                }
                return
            }
            rebuildAttempts += 1
            // Po przebudowie zegar startuje od zera na NOWYM urządzeniu
            // -- porównywanie z punktem odniesienia sprzed przebudowy
            // daje absurdalne odchylenia (widziane 495%).
            self.baseline = nil
            Log.error("dryf zegara \(String(format: "%.2f", deviation * 100))% przekracza 2% w \(String(format: "%.1f", expectedSeconds))s (rate \(Int(rate)) Hz) -- przebudowa \(rebuildAttempts)/\(maxRebuildAttempts)")
            onRebuildNeeded()
        } else if deviation > 0.005 {
            rebuildAttempts = 0
            gaveUpReported = false
            Log.info("dryf zegara \(String(format: "%.2f", deviation * 100))% przekracza 0,5% w \(String(format: "%.1f", expectedSeconds))s")
        } else {
            rebuildAttempts = 0
            gaveUpReported = false
        }
    }

    private func nominalSampleRate(of deviceID: AudioDeviceID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    private func currentTime(of deviceID: AudioDeviceID) -> (hostTime: UInt64, sampleTime: Float64)? {
        var timestamp = AudioTimeStamp()
        let status = AudioDeviceGetCurrentTime(deviceID, &timestamp)
        guard status == noErr else { return nil }
        return (timestamp.mHostTime, timestamp.mSampleTime)
    }

    private func machTicksToSeconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom) / 1_000_000_000.0
    }
}
