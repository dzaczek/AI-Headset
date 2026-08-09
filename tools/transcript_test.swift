// Standalone smoke test for Transcript.swift. Not part of the daemon;
// a throwaway dev diagnostic. Pure local file I/O, no live device.
import Foundation

do {
    let transcript = try Transcript()
    print("Session file: \(transcript.fileURL.path)")
    transcript.append(.user, "Cześć, tu Jacek.")
    transcript.append(.agent, "Dzień dobry, w czym mogę pomóc?")
    transcript.recordConsentAnnouncement(text: "Ta rozmowa może być nagrywana.", playedAt: Date())
    transcript.close()

    let contents = try String(contentsOf: transcript.fileURL, encoding: .utf8)
    let lines = contents.split(separator: "\n").map(String.init)
    print("Wrote \(lines.count) lines.")

    var ok = lines.count == 3
    for line in lines {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["timestamp"] != nil, obj["speaker"] != nil, obj["text"] != nil else {
            print("FAIL: malformed line: \(line)")
            ok = false
            continue
        }
    }
    if !FileManager.default.fileExists(atPath: transcript.fileURL.path) {
        print("FAIL: session file does not exist")
        ok = false
    }
    try? FileManager.default.removeItem(at: transcript.fileURL)

    print(ok ? "PASS" : "SOME FAILED")
    exit(ok ? 0 : 1)
} catch {
    print("FAIL: \(error)")
    exit(1)
}
