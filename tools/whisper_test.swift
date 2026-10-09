// WAV, zapytanie multipart, odpowiedź whisper-server, brak serwera.
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}
func u32(_ d: Data, _ at: Int) -> UInt32 { d.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }

// WAV: nagłówek 44 B, 16 kHz, mono, 16 bit.
let pcmData = Data(count: 3200)
let wav = WAV.encode(pcm16Mono16k: pcmData)
check(wav.count == 44 + 3200, "rozmiar WAV")
check(String(data: wav.prefix(4), encoding: .ascii) == "RIFF", "RIFF")
check(String(data: wav.subdata(in: 8..<12), encoding: .ascii) == "WAVE", "WAVE")
check(u32(wav, 24) == 16000, "częstotliwość 16000")
check(u32(wav, 40) == 3200, "rozmiar danych")

// Zapytanie: POST {base}/inference, multipart z plikiem i formatem json.
let request = WhisperServerAPI.request(baseURL: URL(string: "http://127.0.0.1:8080")!, wav: wav, boundary: "XYZ")
check(request.httpMethod == "POST", "POST")
check(request.url?.absoluteString == "http://127.0.0.1:8080/inference", "adres: \(request.url?.absoluteString ?? "")")
check(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=XYZ", "nagłówek")
let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
check(body.contains("name=\"file\"; filename=\"audio.wav\""), "pole pliku")
check(body.contains("name=\"response_format\"\r\n\r\njson"), "format json")
check(body.hasSuffix("--XYZ--\r\n"), "zamknięcie multipart")

// Odpowiedź.
check((try? WhisperServerAPI.parseText(Data(#"{"text":"  Dzień dobry\n"}"#.utf8))) == "Dzień dobry", "tekst przycięty")
check((try? WhisperServerAPI.parseText(Data("<html>".utf8))) == nil, "niepoprawna odpowiedź -> błąd")

// Brak serwera: błąd przez onError, bez awarii.
let transcriber = WhisperTranscriber(baseURL: URL(string: "http://127.0.0.1:9")!, speaker: .caller)
var gotError = false
transcriber.onError = { _ in gotError = true }
try transcriber.start()
let speech = (0..<16000).map { Int16(sin(Double($0) * 2 * .pi * 300 / 16000) * 0.3 * 32767) }.withUnsafeBytes { Data($0) }
transcriber.feed(pcm16Mono16k: speech + Data(count: 19200))
let deadline = Date().addingTimeInterval(5)
while !gotError && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
check(gotError, "błąd połączenia zgłoszony")
transcriber.stop()

if failures > 0 { exit(1) }
print("PASS whisper_test")
