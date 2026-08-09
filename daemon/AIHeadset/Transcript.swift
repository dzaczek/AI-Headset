import Foundation

/// Plan section 4: JSON Lines transcript of the current conversation,
/// written to ~/Library/Application Support/AIHeadset/sessions/. One
/// file per session, one JSON object per line, flushed immediately
/// (not buffered) so a crash mid-call doesn't lose what was already
/// said. Note generation ("Notatki generuje osobne wywołanie LLM po
/// zakończeniu, nie w trakcie rozmowy") is explicitly a separate,
/// later call in the plan and needs an LLM API decision that hasn't
/// been made -- not implemented here.
final class Transcript {
    enum Speaker: String, Codable {
        case user
        case agent
        case system
    }

    private struct Entry: Codable {
        let timestamp: Date
        let speaker: Speaker
        let text: String
    }

    let sessionID: String
    let fileURL: URL
    private let fileHandle: FileHandle
    private let encoder: JSONEncoder

    init() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        sessionID = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")

        let supportDir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
        let sessionsDir = supportDir.appendingPathComponent("AIHeadset/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        fileURL = sessionsDir.appendingPathComponent("\(sessionID).jsonl")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        fileHandle = try FileHandle(forWritingTo: fileURL)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    func append(_ speaker: Speaker, _ text: String) {
        write(Entry(timestamp: Date(), speaker: speaker, text: text))
    }

    /// Plan 6.5: "Fakt odtworzenia + timestamp zapisany w metadanych
    /// sesji" -- the consent announcement is logged as a system entry,
    /// same file, so it's part of the permanent session record.
    func recordConsentAnnouncement(text: String, playedAt: Date) {
        write(Entry(timestamp: playedAt, speaker: .system, text: "consent_announcement_played: \(text)"))
    }

    private func write(_ entry: Entry) {
        guard let data = try? encoder.encode(entry), let newline = "\n".data(using: .utf8) else { return }
        fileHandle.write(data)
        fileHandle.write(newline)
    }

    func close() {
        try? fileHandle.close()
    }
}
