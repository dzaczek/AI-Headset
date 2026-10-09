import Foundation

/// Kto mówi. Dwa osobne strumienie audio (mikrofon i strona rozmówców)
/// dają pewną etykietę bez rozpoznawania głosów.
enum TranscriptSpeaker: String, Codable {
    case me
    case caller
}

/// Jedna wypowiedź z silnika rozpoznawania. Segment `partial` jest
/// nadpisywany kolejnymi wersjami o tym samym `id`, aż przyjdzie final.
struct TranscriptSegment: Equatable {
    let id: UUID
    let speaker: TranscriptSpeaker
    var text: String
    let start: Date
    var end: Date
    var isFinal: Bool
}

/// Kolejne segmenty jednego mówcy bez dłuższej przerwy.
struct Paragraph: Equatable {
    let id: UUID
    let speaker: TranscriptSpeaker
    var segmentIDs: [UUID]
    var start: Date
    var end: Date
}
