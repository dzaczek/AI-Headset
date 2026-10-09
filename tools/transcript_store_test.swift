// Testy TranscriptStore: partial/final, akapity, przeplot mówców, retencja.
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}

let t0 = Date(timeIntervalSince1970: 1_000_000)
func seg(_ id: UUID, _ speaker: TranscriptSpeaker, _ text: String,
         at offset: TimeInterval, length: TimeInterval = 1, final: Bool = true) -> TranscriptSegment {
    TranscriptSegment(id: id, speaker: speaker, text: text,
                      start: t0.addingTimeInterval(offset), end: t0.addingTimeInterval(offset + length),
                      isFinal: final)
}
func seg(_ speaker: TranscriptSpeaker, _ text: String,
         at offset: TimeInterval, length: TimeInterval = 1, final: Bool = true) -> TranscriptSegment {
    seg(UUID(), speaker, text, at: offset, length: length, final: final)
}

// 1. Partial nadpisywany przez final tego samego id, w jednym akapicie.
do {
    let store = TranscriptStore()
    var changes: [TranscriptStore.Change] = []
    store.onChange = { changes.append($0) }
    let id = UUID()
    store.apply(seg(id, .caller, "Słyszeliście", at: 0, final: false), now: t0)
    check(store.hasPartial(in: store.paragraphs[0].id), "partial widoczny")
    store.apply(seg(id, .caller, "Słyszeliście, że akcje spadają?", at: 0, length: 2), now: t0)
    check(store.paragraphs.count == 1, "jeden akapit")
    check(store.text(of: store.paragraphs[0].id) == "Słyszeliście, że akcje spadają?", "tekst nadpisany")
    check(!store.hasPartial(in: store.paragraphs[0].id), "brak partial po final")
    check(changes == [.appended(store.paragraphs[0].id), .updated(store.paragraphs[0].id)], "zmiany: \(changes)")
}

// 2. Ten sam mówca, przerwa <= 4 s -> ten sam akapit; > 4 s -> nowy.
do {
    let store = TranscriptStore()
    store.apply(seg(.caller, "Pierwsze.", at: 0), now: t0)
    store.apply(seg(.caller, "Drugie.", at: 4.5), now: t0)        // przerwa 3,5 s
    check(store.paragraphs.count == 1, "przerwa 3,5 s w tym samym akapicie")
    check(store.text(of: store.paragraphs[0].id) == "Pierwsze. Drugie.", "teksty złączone spacją")
    store.apply(seg(.caller, "Trzecie.", at: 10), now: t0)        // przerwa 4,5 s
    check(store.paragraphs.count == 2, "przerwa 4,5 s -> nowy akapit")
}

// 3. Zmiana mówcy -> nowy akapit, nawet bez przerwy.
do {
    let store = TranscriptStore()
    store.apply(seg(.caller, "Pytanie?", at: 0), now: t0)
    store.apply(seg(.me, "Odpowiedź.", at: 1), now: t0)
    store.apply(seg(.caller, "Dzięki.", at: 2), now: t0)
    check(store.paragraphs.map(\.speaker) == [.caller, .me, .caller], "trzy akapity na przemian")
}

// 4. Przeplot: obie strony mówią naraz, partiale aktualizują własne akapity.
do {
    let store = TranscriptStore()
    let a = UUID(), b = UUID()
    store.apply(seg(a, .caller, "Ja mó", at: 0, final: false), now: t0)
    store.apply(seg(b, .me, "A ja", at: 0.5, final: false), now: t0)
    store.apply(seg(a, .caller, "Ja mówię pierwszy", at: 0, length: 2), now: t0)
    store.apply(seg(b, .me, "A ja wchodzę w słowo", at: 0.5, length: 2), now: t0)
    check(store.paragraphs.count == 2, "dwa akapity")
    check(store.text(of: store.paragraphs[0].id) == "Ja mówię pierwszy", "tekst rozmówcy nienaruszony")
    check(store.text(of: store.paragraphs[1].id) == "A ja wchodzę w słowo", "mój tekst nienaruszony")
}

// 5. Pusty partial nie tworzy akapitu.
do {
    let store = TranscriptStore()
    store.apply(seg(.caller, "   ", at: 0, final: false), now: t0)
    check(store.paragraphs.isEmpty, "pusty segment pominięty")
}

// 6. Retencja 90 min: akapity starsze niż 90 min od `now` znikają.
do {
    let store = TranscriptStore()
    var removed: [UUID] = []
    store.onChange = { if case .removed(let ids) = $0 { removed += ids } }
    store.apply(seg(.caller, "Stare.", at: 0), now: t0)
    let oldID = store.paragraphs[0].id
    store.apply(seg(.me, "Nowe.", at: 95 * 60), now: t0.addingTimeInterval(95 * 60))
    check(store.paragraphs.count == 1 && store.paragraphs[0].speaker == .me, "został tylko nowy akapit")
    check(removed == [oldID], "zgłoszone usunięcie")
    check(store.segments.count == 1, "segmenty starego akapitu usunięte")
}

if failures > 0 { exit(1) }
print("PASS transcript_store_test")
