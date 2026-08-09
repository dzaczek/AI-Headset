import CoreAudio
import Foundation

enum AggregateDeviceError: Error, CustomStringConvertible {
    case creationFailed(OSStatus)
    case destructionFailed(OSStatus)
    case circularDevice(String)

    var description: String {
        switch self {
        case .creationFailed(let status):
            return "AudioHardwareCreateAggregateDevice failed: \(status)"
        case .destructionFailed(let status):
            return "AudioHardwareDestroyAggregateDevice failed: \(status)"
        case .circularDevice(let uid):
            return "odmowa: \(uid) to nasze własne urządzenie -- aggregate zawierający je tworzy pętlę i psuje audio"
        }
    }
}

/// Faza 2.1 (plan): a private aggregate combining the hidden Bridge
/// device with a physical device, so both share one clock and the
/// daemon drives them with a single IOProc instead of opening two
/// devices separately and fighting their independent clocks.
final class AggregateDevice {
    private(set) var deviceID: AudioDeviceID?

    /// Rzeczywista częstotliwość, na jakiej pracuje aggregate. NIE jest
    /// to AIHeadsetConfig.sampleRate: CoreAudio potrafi ustalić ją na
    /// podstawie sub-urządzeń (44,1 kHz przy głośnikach wbudowanych,
    /// 16 kHz przy zestawie Bluetooth w HFP) i nie pozwala jej zmienić.
    /// Resampling do agenta MUSI wychodzić od tej wartości, inaczej
    /// dźwięk idzie w złym tempie i wysokości. Testy oparte na RMS tego
    /// nie wykrywają -- RMS jest taki sam niezależnie od tempa.
    private(set) var actualSampleRate: Float64 = AIHeadsetConfig.sampleRate

    /// Destroys any existing aggregate and rebuilds it against the
    /// given physical device(s) + the hidden Bridge. Changing the
    /// monitoring output means tearing down and recreating this
    /// (plan 2.1: expect 100-200ms of silence — callers should do this
    /// on a mute, not mid-sentence).
    ///
    /// `outputDeviceUID` and `inputDeviceUID` are separate because
    /// plan section 4's menu design has independent "Wyjście
    /// monitorujące" / "Wejście mikrofonu" pickers -- real hardware
    /// backs that up too: this Mac's built-in mic and speakers are two
    /// distinct CoreAudio devices, not one duplex device. Pass the
    /// same UID for both (or leave `inputDeviceUID` nil) for a single
    /// duplex device like a real USB headset, matching plan 2.1's
    /// simpler one-physical-device example. Either way the Bridge ends
    /// up last in the sub-device list, which is the only ordering
    /// AudioRouter relies on.
    @discardableResult
    func create(outputDeviceUID: String, inputDeviceUID: String?) throws -> AudioDeviceID {
        // Twarda bramka: aggregate zawierający nasze własne urządzenie
        // zamyka pętlę i skutkuje tym, że macOS nie potrafi używać
        // "AI Headset" w ogóle. Trafiło się w praktyce, gdy domyślnym
        // wyjściem systemu było właśnie AI Headset.
        guard !AudioDeviceUtil.isOwnDevice(outputDeviceUID) else {
            throw AggregateDeviceError.circularDevice(outputDeviceUID)
        }
        if let inputDeviceUID, AudioDeviceUtil.isOwnDevice(inputDeviceUID) {
            throw AggregateDeviceError.circularDevice(inputDeviceUID)
        }

        if deviceID != nil {
            try destroy()
        }

        var subDeviceList: [[String: Any]] = [
            [kAudioSubDeviceUIDKey as String: outputDeviceUID,
             kAudioSubDeviceDriftCompensationKey as String: 0],
        ]
        if let inputDeviceUID, inputDeviceUID != outputDeviceUID {
            subDeviceList.append([kAudioSubDeviceUIDKey as String: inputDeviceUID,
                                   kAudioSubDeviceDriftCompensationKey as String: 1])
        }
        subDeviceList.append([kAudioSubDeviceUIDKey as String: AIHeadsetConfig.bridgeUID,
                               kAudioSubDeviceDriftCompensationKey as String: 1])

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: AIHeadsetConfig.aggregateName,
            kAudioAggregateDeviceUIDKey as String: AIHeadsetConfig.aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey as String: subDeviceList,
        ]

        var aggregateID = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else {
            throw AggregateDeviceError.creationFailed(status)
        }
        deviceID = aggregateID

        // Kolejność sub-urządzeń przesądza o kolejności buforów w
        // IOProc, a cała logika routingu zakłada Bridge na końcu.
        let uids = subDeviceList.compactMap { $0[kAudioSubDeviceUIDKey as String] as? String }
        Log.info("aggregate zbudowany (id=\(aggregateID)), sub-urządzenia w kolejności: \(uids.joined(separator: " -> "))")

        alignSampleRate(aggregateID)
        return aggregateID
    }

    /// Cały tor (bufory, Resampler, ustawienia agenta) jest zbudowany
    /// wokół 48 kHz. Aggregate potrafi jednak przyjąć częstotliwość
    /// najsłabszego ogniwa: zestaw Bluetooth w profilu HFP zjeżdża na
    /// 16 kHz i wtedy resampling liczy się ze złej podstawy, a dźwięk
    /// agenta idzie w złym tempie. Próbujemy wymusić 48 kHz; jeśli się
    /// nie da, mówimy o tym wprost zamiast po cichu grać nie tak.
    private func alignSampleRate(_ deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var current: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &current) == noErr else { return }

        actualSampleRate = current
        if current == AIHeadsetConfig.sampleRate {
            Log.info("aggregate pracuje na \(Int(current)) Hz -- zgodnie z założeniem")
            return
        }

        Log.info("aggregate pracuje na \(Int(current)) Hz, próbuję ustawić \(Int(AIHeadsetConfig.sampleRate)) Hz")
        var desired = AIHeadsetConfig.sampleRate
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                                 UInt32(MemoryLayout<Float64>.size), &desired)

        var after: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &after)

        if after > 0 { actualSampleRate = after }
        if status == noErr && after == AIHeadsetConfig.sampleRate {
            Log.info("ustawiono \(Int(after)) Hz")
        } else {
            Log.error("nie udało się ustawić \(Int(AIHeadsetConfig.sampleRate)) Hz (status \(status), nadal \(Int(after)) Hz) -- przy zestawie Bluetooth w trybie HFP to normalne; dźwięk agenta może iść w złym tempie, rozważ mikrofon inny niż BT")
        }
    }

    func destroy() throws {
        guard let id = deviceID else { return }
        let status = AudioHardwareDestroyAggregateDevice(id)
        deviceID = nil
        guard status == noErr else {
            throw AggregateDeviceError.destructionFailed(status)
        }
    }
}
