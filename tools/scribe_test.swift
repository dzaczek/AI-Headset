// Kodowanie i dekodowanie wiadomości Scribe realtime.
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}

let message = ScribeProtocol.audioMessage(Data([1, 2, 3, 4]), commit: false)
let json = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any] ?? [:]
check(json["message_type"] as? String == "input_audio_chunk", "typ")
check(json["audio_base_64"] as? String == Data([1, 2, 3, 4]).base64EncodedString(), "base64")
check(json["commit"] as? Bool == false, "commit false")
check(json["sample_rate"] as? Int == 16000, "16 kHz")

let commit = try JSONSerialization.jsonObject(with: Data(ScribeProtocol.audioMessage(Data(), commit: true).utf8)) as? [String: Any] ?? [:]
check(commit["commit"] as? Bool == true && commit["audio_base_64"] as? String == "", "commit z pustym audio")

check(ScribeProtocol.parse(#"{"message_type":"session_started","session_id":"x"}"#) == .sessionStarted, "start")
check(ScribeProtocol.parse(#"{"message_type":"partial_transcript","text":"Dzień"}"#) == .partial("Dzień"), "partial")
check(ScribeProtocol.parse(#"{"message_type":"committed_transcript","text":"Dzień dobry"}"#) == .committed("Dzień dobry"), "committed")
if case .error = ScribeProtocol.parse(#"{"message_type":"input_error","error":"bad audio"}"#) {} else { check(false, "input_error") }
check(ScribeProtocol.parse(#"{"message_type":"committed_transcript_with_timestamps","words":[]}"#) == nil, "nieobsługiwany typ pominięty")
check(ScribeProtocol.parse("nie json") == nil, "śmieci pominięte")
check(ScribeProtocol.endpoint.absoluteString == "wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime", "endpoint")

if failures > 0 { exit(1) }
print("PASS scribe_test")
