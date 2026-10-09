import Foundation

enum TranscriberEngine: String, CaseIterable {
    case apple, scribe, whisper

    var title: String { L("transcription.engine.\(rawValue)") }
    /// Pokazywane w pasku okna i w Ustawieniach: dokąd idzie dźwięk.
    var privacyNote: String { L("transcription.privacy.\(rawValue)") }
    var isLocal: Bool { self != .scribe }
}

/// Ustawienia transkrypcji w UserDefaults (bez sekretów -- klucz
/// ElevenLabs jest w Keychain, przez AgentSettings).
struct TranscriptionSettings {
    static let languages = ["pl-PL", "en-US"]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var engine: TranscriberEngine {
        get { defaults.string(forKey: "transcription.engine").flatMap(TranscriberEngine.init) ?? .apple }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "transcription.engine") }
    }

    var language: String {
        get { defaults.string(forKey: "transcription.language") ?? "pl-PL" }
        nonmutating set { defaults.set(newValue, forKey: "transcription.language") }
    }

    var whisperURL: URL {
        get { defaults.string(forKey: "transcription.whisperURL").flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:8080")! }
        nonmutating set { defaults.set(newValue.absoluteString, forKey: "transcription.whisperURL") }
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: "transcription.enabled") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "transcription.enabled") }
    }
}

enum TranscriberFactory {
    enum FactoryError: Error, CustomStringConvertible {
        case missingElevenLabsKey
        var description: String { L("transcription.error.noKey") }
    }

    static func make(_ speaker: TranscriptSpeaker, settings: TranscriptionSettings,
                     elevenLabsKey: String?) throws -> SpeechTranscriber {
        switch settings.engine {
        case .apple:
            return AppleSpeechTranscriber(language: settings.language, speaker: speaker)
        case .whisper:
            return WhisperTranscriber(baseURL: settings.whisperURL, speaker: speaker)
        case .scribe:
            guard let key = elevenLabsKey, !key.isEmpty else { throw FactoryError.missingElevenLabsKey }
            return ScribeTranscriber(apiKey: key, speaker: speaker)
        }
    }
}
