import Foundation

/// Plan 6.2: "Agent nie potwierdza terminów, cen ani zakresu prac. To
/// dwa mechanizmy, nie jeden: system prompt agenta, filtr po stronie
/// klienta." The system prompt half is agent-dashboard configuration,
/// not code. This is the client-side half -- a blunt, regex/keyword
/// safety net on `agent_response` text, not real NLU. It will have
/// false positives and false negatives; tune the patterns once real
/// conversations show what it actually needs to catch. The plan is
/// explicit that the prompt alone "nie wystarcza" (isn't enough), so
/// this exists even though it's crude.
enum CommitmentFilter {
    /// Both languages' patterns are always active, never switched on the
    /// app's UI language. A filter that only guards the language your
    /// Mac happens to be set to fails exactly when it matters most --
    /// an English-speaking client on a Polish Mac -- and calls routinely
    /// mix languages mid-sentence. Running both costs a handful of
    /// regex passes per agent turn, which is nothing next to the
    /// WebSocket round-trip.
    private static let patterns: [NSRegularExpression] = {
        let languageNeutral = [
            #"\b\d{1,2}[:.]\d{2}\b"#,        // times: 14:30
            #"\d+\s?(zł|PLN|USD|EUR|GBP)"#,  // amount before the unit
            #"[$£€]\s?\d+"#,                 // symbol before the amount: $500
        ]
        let polish = [
            #"\b\d{1,2}\s?(stycznia|lutego|marca|kwietnia|maja|czerwca|lipca|sierpnia|września|października|listopada|grudnia)\b"#,
            #"\b(jutro|pojutrze|w poniedziałek|we wtorek|w środę|w czwartek|w piątek)\b"#,
            #"\b(potwierdzam|obiecuję|gwarantuję|na pewno zrobimy|umowa stoi|daję słowo)\b"#,
        ]
        let english = [
            #"\b\d{1,2}(st|nd|rd|th)?\s?(of\s)?(january|february|march|april|may|june|july|august|september|october|november|december)\b"#,
            #"\b(january|february|march|april|may|june|july|august|september|october|november|december)\s\d{1,2}\b"#,
            #"\b(tomorrow|the day after tomorrow|next week|by (monday|tuesday|wednesday|thursday|friday)|on (monday|tuesday|wednesday|thursday|friday))\b"#,
            #"\b(i promise|i guarantee|i confirm|we'?ll definitely|we will definitely|it'?s a deal|you have my word|guaranteed)\b"#,
        ]
        return (languageNeutral + polish + english)
            .compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    static func containsCommitment(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// Spoken out to the other party, so it is localized -- and computed
    /// rather than stored, because a `static let` would freeze whatever
    /// language was current at first access.
    static var deflectionMessage: String { L("filter.deflection") }
}
