import Foundation

/// Transkrypt bieżącej rozmowy w pamięci, ułożony w akapity. Używany
/// wyłącznie z głównego wątku. Pamięć ograniczona do ostatnich 90 min
/// -- starsza część żyje tylko w dzienniku JSONL na dysku.
final class TranscriptStore {
    enum Change: Equatable {
        case appended(UUID)
        case updated(UUID)
        case removed([UUID])
    }

    static let paragraphGap: TimeInterval = 4
    static let retention: TimeInterval = 90 * 60

    private(set) var paragraphs: [Paragraph] = []
    private(set) var segments: [UUID: TranscriptSegment] = [:]
    private var paragraphOfSegment: [UUID: UUID] = [:]

    var onChange: ((Change) -> Void)?

    func apply(_ segment: TranscriptSegment, now: Date = Date()) {
        if let paragraphID = paragraphOfSegment[segment.id],
           let index = paragraphs.firstIndex(where: { $0.id == paragraphID }) {
            segments[segment.id] = segment
            paragraphs[index].end = max(paragraphs[index].end, segment.end)
            onChange?(.updated(paragraphID))
        } else {
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            segments[segment.id] = segment
            // Dołączamy tylko do OSTATNIEGO akapitu -- jeśli w międzyczasie
            // mówił ktoś inny, to już nowa wypowiedź.
            if let last = paragraphs.last, last.speaker == segment.speaker,
               segment.start.timeIntervalSince(last.end) <= Self.paragraphGap {
                let index = paragraphs.count - 1
                paragraphs[index].segmentIDs.append(segment.id)
                paragraphs[index].end = max(last.end, segment.end)
                paragraphOfSegment[segment.id] = last.id
                onChange?(.updated(last.id))
            } else {
                let paragraph = Paragraph(id: UUID(), speaker: segment.speaker, segmentIDs: [segment.id],
                                          start: segment.start, end: segment.end)
                paragraphs.append(paragraph)
                paragraphOfSegment[segment.id] = paragraph.id
                onChange?(.appended(paragraph.id))
            }
        }
        trim(now: now)
    }

    func text(of paragraphID: UUID) -> String {
        guard let paragraph = paragraphs.first(where: { $0.id == paragraphID }) else { return "" }
        return paragraph.segmentIDs
            .compactMap { segments[$0]?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func hasPartial(in paragraphID: UUID) -> Bool {
        guard let paragraph = paragraphs.first(where: { $0.id == paragraphID }) else { return false }
        return paragraph.segmentIDs.contains { segments[$0]?.isFinal == false }
    }

    private func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let expired = paragraphs.prefix { $0.end < cutoff }
        guard !expired.isEmpty else { return }
        for paragraph in expired {
            for segmentID in paragraph.segmentIDs {
                segments[segmentID] = nil
                paragraphOfSegment[segmentID] = nil
            }
        }
        paragraphs.removeFirst(expired.count)
        onChange?(.removed(expired.map(\.id)))
    }
}
