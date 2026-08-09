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
    private static let patterns: [NSRegularExpression] = {
        let raw = [
            #"\b\d{1,2}[:.]\d{2}\b"#, // times: 14:30
            #"\b\d{1,2}\s?(stycznia|lutego|marca|kwietnia|maja|czerwca|lipca|sierpnia|września|października|listopada|grudnia)\b"#,
            #"\b(jutro|pojutrze|w poniedziałek|we wtorek|w środę|w czwartek|w piątek)\b"#,
            #"\d+\s?(zł|PLN|USD|EUR|\$)"#,
            #"\b(potwierdzam|obiecuję|gwarantuję|na pewno zrobimy|umowa stoi)\b"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    static func containsCommitment(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    static let deflectionMessage = "Przekażę to koledze, on to potwierdzi."
}
