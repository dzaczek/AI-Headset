// Ustawienia transkrypcji: domyślne, zapis, fabryka silników.
import AVFoundation
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}

let suite = "aiheadset-test-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }

var settings = TranscriptionSettings(defaults: defaults)
check(settings.engine == .apple, "domyślnie Apple")
check(settings.language == "pl-PL", "domyślnie polski")
check(settings.whisperURL.absoluteString == "http://127.0.0.1:8080", "domyślny adres Whisper")
check(settings.isEnabled, "domyślnie włączona")

settings.engine = .whisper
settings.whisperURL = URL(string: "http://10.0.0.5:9000")!
settings.isEnabled = false
let reread = TranscriptionSettings(defaults: defaults)
check(reread.engine == .whisper && reread.whisperURL.port == 9000 && !reread.isEnabled, "zapis i odczyt")

check(try TranscriberFactory.make(.me, settings: reread, elevenLabsKey: nil) is WhisperTranscriber, "fabryka: Whisper")
settings.engine = .apple
check(try TranscriberFactory.make(.me, settings: settings, elevenLabsKey: nil) is AppleSpeechTranscriber, "fabryka: Apple")
settings.engine = .scribe
check(try TranscriberFactory.make(.caller, settings: settings, elevenLabsKey: "k") is ScribeTranscriber, "fabryka: Scribe")
do {
    _ = try TranscriberFactory.make(.caller, settings: settings, elevenLabsKey: nil)
    check(false, "Scribe bez klucza powinien rzucić")
} catch TranscriberFactory.FactoryError.missingElevenLabsKey {
} catch {
    check(false, "zły błąd: \(error)")
}

// Bufor dla Apple: PCM16 16 kHz mono, liczba ramek = bajty / 2.
let buffer = AppleSpeechTranscriber.makeBuffer(Data(count: 3200))
check(buffer?.frameLength == 1600 && buffer?.format.sampleRate == 16000, "bufor Apple")

if failures > 0 { exit(1) }
print("PASS transcription_settings_test")
