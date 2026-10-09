# Transkrypcja i okno transkryptora — plan wdrożenia (podprojekt 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transkrypcja na żywo obu stron rozmowy (ja / rozmówcy) w każdym trybie, trzy silniki do wyboru, wyświetlana w natywnym oknie transkryptora z paskiem Liquid Glass.

**Architecture:** `AudioRouter` zapisuje dźwięk rozmówców i mikrofonu do dwóch nowych buforów mono. `TranscriptionSession` co 50 ms opróżnia je, resampluje do PCM16 16 kHz i karmi dwie instancje `SpeechTranscriber` (Apple / ElevenLabs Scribe / Whisper). Segmenty trafiają do `TranscriptStore` (akapity) i dziennika JSONL; okno to `NSPanel` z `NSTableView` akapitów i szklanym paskiem sterowania.

**Tech Stack:** Swift 6.2 (swiftc, bez Xcode), AppKit, AVFoundation, Speech, URLSession (HTTP + WebSocket), CoreAudio. Bez zależności zewnętrznych.

**Spec:** `docs/superpowers/specs/2026-10-08-transkryptor-weryfikator-design.md` (sekcja 1 + „Testy”)

## Global Constraints

- Minimalny macOS 13.0 (`LSMinimumSystemVersion`), build uniwersalny arm64 + x86_64 (`make daemon`).
- Liquid Glass (`NSGlassEffectView`) tylko na macOS 26+, w innym razie `NSVisualEffectView`; nigdy w warstwie treści (transkrypt).
- Na wątku IO (`AudioRouter.process`) żadnych alokacji ani blokad poza zapisem do `RingBuffer`.
- Klucze wyłącznie w Keychain; testy z `AIHEADSET_TEST_KEYCHAIN_SUFFIX`.
- Każdy tekst UI przez `L("klucz")` z wpisem w `pl.lproj` i `en.lproj`.
- Mówcy: `me` („Ja”/„Me”) i `caller` („Rozmówcy”/„Others”).
- Nowy akapit: zmiana mówcy albo przerwa > 4 s. W pamięci ostatnie 90 min.
- Tekst w oknie najpóźniej 3 s po wypowiedzi (kryterium sukcesu 1).
- Kolor nie jest jedynym nośnikiem znaczenia; status ma też tekst.

## Review Focus

1. Mikrofon mono (MacBook, Bluetooth HFP) i stereo — bufor transkrypcji ma dostać poprawny sygnał mono w obu przypadkach (test w Task 2).
2. Silnik niedostępny: brak serwera Whisper, brak klucza ElevenLabs, brak zgody na rozpoznawanie mowy — komunikat w oknie, brak awarii, dźwięk działa (testy w Task 5, 7; status w Task 9).
3. Przebudowa urządzeń audio w trakcie rozmowy (`rebuildAudio`) — transkrypt w oknie zostaje, transkrypcja wznawia się na nowym routerze (test w Task 3, okablowanie w Task 9).
4. Rozmowa dłuższa niż 90 min — stare akapity znikają z pamięci, aplikacja nie rośnie bez końca (test w Task 1).
5. Obie strony mówią naraz — częściowe segmenty dwóch mówców przeplatają się bez mieszania tekstu (test w Task 1).

---

## File Structure

| Plik | Odpowiedzialność |
|---|---|
| `daemon/AIHeadset/TranscriptModel.swift` (nowy) | `TranscriptSpeaker`, `TranscriptSegment`, `Paragraph` |
| `daemon/AIHeadset/TranscriptStore.swift` (nowy) | akapity, aktualizacje partial/final, retencja 90 min |
| `daemon/AIHeadset/AudioRouter.swift` (zmiana) | dwa bufory mono dla transkrypcji |
| `daemon/AIHeadset/Config.swift` (zmiana) | pojemność buforów transkrypcji |
| `daemon/AIHeadset/Resampler.swift` (zmiana) | `monoDeviceToSpeech` |
| `daemon/AIHeadset/SpeechTranscriber.swift` (nowy) | protokół silnika |
| `daemon/AIHeadset/TranscriptionSession.swift` (nowy) | pompa buforów → silniki → magazyn + dziennik |
| `daemon/AIHeadset/Transcript.swift` (zmiana) | mówca `caller` w dzienniku JSONL |
| `daemon/AIHeadset/SilenceSegmenter.swift` (nowy) | cięcie PCM16 na wypowiedzi po ciszy |
| `daemon/AIHeadset/WhisperTranscriber.swift` (nowy) | WAV, multipart do `whisper-server`, silnik |
| `daemon/AIHeadset/ScribeTranscriber.swift` (nowy) | protokół i silnik ElevenLabs Scribe realtime |
| `daemon/AIHeadset/AppleSpeechTranscriber.swift` (nowy) | silnik `SFSpeechRecognizer` na urządzeniu |
| `daemon/AIHeadset/TranscriptionSettings.swift` (nowy) | ustawienia transkrypcji + fabryka silników |
| `daemon/AIHeadset/SettingsWindowController.swift` (zmiana) | okno z panelami w pasku narzędzi |
| `daemon/AIHeadset/AgentSettingsPane.swift` (nowy) | dotychczasowa zawartość Ustawień jako panel |
| `daemon/AIHeadset/TranscriptionSettingsPane.swift` (nowy) | panel Transkrypcja |
| `daemon/AIHeadset/Glass.swift` (nowy) | szkło z awaryjnym materiałem |
| `daemon/AIHeadset/TranscriptWindowController.swift` (nowy) | okno, pasek, tabela akapitów, auto-przewijanie |
| `daemon/AIHeadset/MenuBarController.swift` (zmiana) | cykl życia transkrypcji, pozycja menu ⌘⇧T |
| `daemon/AIHeadset/Info.plist` (zmiana) | `NSSpeechRecognitionUsageDescription` |
| `daemon/AIHeadset/Resources/{pl,en}.lproj/Localizable.strings` (zmiana) | teksty |
| `tools/run_tests.sh` (nowy), `Makefile` (zmiana) | `make test` |
| `tools/*_test.swift` (nowe) | testy jednostkowe |

---

### Task 1: Model transkryptu, magazyn akapitów i `make test`

**Files:**
- Create: `daemon/AIHeadset/TranscriptModel.swift`
- Create: `daemon/AIHeadset/TranscriptStore.swift`
- Create: `tools/run_tests.sh`
- Modify: `Makefile` (cel `test`, `.PHONY`)
- Test: `tools/transcript_store_test.swift`

**Interfaces:**
- Produces:
  - `enum TranscriptSpeaker: String, Codable { case me, caller }`
  - `struct TranscriptSegment: Equatable { let id: UUID; let speaker: TranscriptSpeaker; var text: String; let start: Date; var end: Date; var isFinal: Bool }`
  - `struct Paragraph: Equatable { let id: UUID; let speaker: TranscriptSpeaker; var segmentIDs: [UUID]; var start: Date; var end: Date }`
  - `final class TranscriptStore { enum Change: Equatable { case appended(UUID), updated(UUID), removed([UUID]) }; static let paragraphGap: TimeInterval; static let retention: TimeInterval; private(set) var paragraphs: [Paragraph]; private(set) var segments: [UUID: TranscriptSegment]; var onChange: ((Change) -> Void)?; func apply(_ segment: TranscriptSegment, now: Date = Date()); func text(of paragraphID: UUID) -> String; func hasPartial(in paragraphID: UUID) -> Bool }`
  - `tools/run_tests.sh` — tablica `TESTS` z wpisami `"nazwa_testu: pliki zależności"`; kolejne zadania dopisują wpisy.

- [ ] **Step 1: Napisz harness testów**

`tools/run_tests.sh`:

```bash
#!/bin/bash
# Buduje i uruchamia testy jednostkowe z tools/. Wpis = nazwa testu
# (tools/<nazwa>.swift) i pliki aplikacji, których używa. Test jest
# kopiowany jako main.swift, bo tylko tam swiftc pozwala na kod
# najwyższego poziomu przy kompilacji wielu plików.
#
# Bez sieci i bez urządzeń audio. Klucze w osobnym koncie Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

A=daemon/AIHeadset
TESTS=(
    "transcript_store_test: $A/TranscriptModel.swift $A/TranscriptStore.swift"
)

OUT=build/tests
mkdir -p "$OUT"
failed=0
for entry in "${TESTS[@]}"; do
    name="${entry%%:*}"
    deps="${entry#*:}"
    dir="$OUT/$name"
    mkdir -p "$dir"
    cp "tools/$name.swift" "$dir/main.swift"
    # shellcheck disable=SC2086
    if ! swiftc -o "$dir/$name" "$dir/main.swift" $deps 2>"$dir/build.log"; then
        echo "BUILD FAIL  $name"
        cat "$dir/build.log"
        failed=1
        continue
    fi
    if (cd "$dir" && AIHEADSET_TEST_KEYCHAIN_SUFFIX=unit-test "./$name"); then
        echo "PASS        $name"
    else
        echo "FAIL        $name"
        failed=1
    fi
done
exit $failed
```

Run: `chmod +x tools/run_tests.sh`

W `Makefile` dopisz `test` do `.PHONY` i na końcu pliku:

```make
# Testy jednostkowe (bez sieci i bez urządzeń audio). Lista w
# tools/run_tests.sh.
test:
	./tools/run_tests.sh
```

- [ ] **Step 2: Napisz test, który nie przejdzie**

`tools/transcript_store_test.swift`:

```swift
// Testy TranscriptStore: partial/final, akapity, przeplot mówców, retencja.
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}

let t0 = Date(timeIntervalSince1970: 1_000_000)
func seg(_ id: UUID = UUID(), _ speaker: TranscriptSpeaker, _ text: String,
         at offset: TimeInterval, length: TimeInterval = 1, final: Bool = true) -> TranscriptSegment {
    TranscriptSegment(id: id, speaker: speaker, text: text,
                      start: t0.addingTimeInterval(offset), end: t0.addingTimeInterval(offset + length),
                      isFinal: final)
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
```

- [ ] **Step 3: Uruchom i sprawdź, że nie przechodzi**

Run: `make test`
Expected: `BUILD FAIL  transcript_store_test` (`cannot find 'TranscriptStore' in scope`)

- [ ] **Step 4: Zaimplementuj model i magazyn**

`daemon/AIHeadset/TranscriptModel.swift`:

```swift
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
```

`daemon/AIHeadset/TranscriptStore.swift`:

```swift
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
```

- [ ] **Step 5: Uruchom testy**

Run: `make test`
Expected: `PASS        transcript_store_test`

- [ ] **Step 6: Commit**

```bash
git add tools/run_tests.sh tools/transcript_store_test.swift Makefile daemon/AIHeadset/TranscriptModel.swift daemon/AIHeadset/TranscriptStore.swift
git commit -m "Magazyn transkryptu z akapitami i retencją 90 min, cel make test"
```

---

### Task 2: Bufory transkrypcji w routerze (mono, każdy tryb)

**Files:**
- Modify: `daemon/AIHeadset/Config.swift` (nowa stała)
- Modify: `daemon/AIHeadset/AudioRouter.swift` (właściwości po `uplinkBuffer`; wywołanie w `process` po `guard let bridgeOut`)
- Modify: `tools/run_tests.sh` (wpis)
- Test: `tools/router_tap_test.swift`

**Interfaces:**
- Produces:
  - `AIHeadsetConfig.transcriptTapCapacityFrames: Int` (65536)
  - `AudioRouter.callerTranscriptTap: RingBuffer` (channels: 1)
  - `AudioRouter.micTranscriptTap: RingBuffer` (channels: 1)
  - `AudioRouter.feedTranscriptTaps(caller: AudioBuffer?, mic: AudioBuffer?)`

- [ ] **Step 1: Napisz test**

`tools/router_tap_test.swift`:

```swift
// Bufory transkrypcji: stereo i mono trafiają jako mono, uplink agenta nietknięty.
import AudioToolbox
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}

let router = AudioRouter(aggregateDeviceID: 0)

// Rozmówcy: stereo, lewy = rampa, prawy = 0 -> mono = rampa / 2.
var stereo = [Float](repeating: 0, count: 512)
for i in 0..<256 { stereo[i * 2] = Float(i) / 256 }
// Mikrofon: mono (MacBook, Bluetooth HFP).
var mono = (0..<128).map { Float($0) / 128 }

stereo.withUnsafeMutableBytes { s in
    mono.withUnsafeMutableBytes { m in
        let caller = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(s.count), mData: s.baseAddress)
        let mic = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(m.count), mData: m.baseAddress)
        router.feedTranscriptTaps(caller: caller, mic: mic)
    }
}

check(router.callerTranscriptTap.framesAvailable == 256, "256 ramek rozmówców")
var callerOut = [Float](repeating: 0, count: 256)
callerOut.withUnsafeMutableBufferPointer { router.callerTranscriptTap.read($0.baseAddress!, frameCount: 256) }
check(abs(callerOut[100] - Float(100) / 256 / 2) < 1e-6, "stereo uśrednione do mono: \(callerOut[100])")

check(router.micTranscriptTap.framesAvailable == 128, "128 ramek mikrofonu")
var micOut = [Float](repeating: 0, count: 128)
micOut.withUnsafeMutableBufferPointer { router.micTranscriptTap.read($0.baseAddress!, frameCount: 128) }
check(abs(micOut[64] - 0.5) < 1e-6, "mono bez zmian: \(micOut[64])")

check(router.uplinkBuffer.framesAvailable == 0, "uplink agenta nie dostał nic z tej ścieżki")

// Brak mikrofonu w aggregate -> nil, bez awarii.
router.feedTranscriptTaps(caller: nil, mic: nil)

if failures > 0 { exit(1) }
print("PASS router_tap_test")
```

Dopisz do `TESTS` w `tools/run_tests.sh`:

```bash
    "router_tap_test: $A/AudioRouter.swift $A/RingBuffer.swift $A/Config.swift $A/Log.swift $A/AggregateDevice.swift $A/AudioDeviceUtil.swift"
```

- [ ] **Step 2: Uruchom i sprawdź, że nie przechodzi**

Run: `make test`
Expected: `BUILD FAIL  router_tap_test` (`value of type 'AudioRouter' has no member 'feedTranscriptTaps'`). Jeśli kompilacja zgłosi brak innego typu z `daemon/AIHeadset`, dopisz jego plik do wpisu testu.

- [ ] **Step 3: Zaimplementuj**

W `Config.swift`, po `uplinkCapacityFrames`:

```swift
    /// Bufory transkrypcji (mono): pompa czyta je co ~50 ms, więc
    /// ~1,4 s zapasu @ 48 kHz wystarcza z nawiązką.
    static let transcriptTapCapacityFrames = 65536
```

W `AudioRouter.swift`, po deklaracji `uplinkBuffer`:

```swift
    /// Transkrypcja słucha w każdym trybie, obu stron osobno -- dzięki
    /// temu wiadomo, kto mówi, bez rozpoznawania głosów. Mono, bo
    /// rozpoznawanie mowy i tak pracuje na jednym kanale; mikrofony bywają
    /// mono, strona rozmówców jest stereo.
    let callerTranscriptTap = RingBuffer(frameCapacity: AIHeadsetConfig.transcriptTapCapacityFrames, channels: 1)
    let micTranscriptTap = RingBuffer(frameCapacity: AIHeadsetConfig.transcriptTapCapacityFrames, channels: 1)
    /// Prealokowany: wątek IO nie może alokować.
    private var transcriptScratch = [Float](repeating: 0, count: 8192)
```

W `process(...)`, bezpośrednio po `guard let bridgeOut = output.last else { return }`:

```swift
        // Transkrypcja: rozmówcy (Bridge.in) i mikrofon, w każdym trybie.
        feedTranscriptTaps(caller: input.last, mic: input.count > 1 ? input[0] : nil)
```

Na końcu klasy (przed `private func copy`):

```swift
    /// Wywoływane z wątku IO; osobno dostępne dla testów.
    func feedTranscriptTaps(caller: AudioBuffer?, mic: AudioBuffer?) {
        if let caller { writeMono(caller, to: callerTranscriptTap) }
        if let mic { writeMono(mic, to: micTranscriptTap) }
    }

    private func writeMono(_ buffer: AudioBuffer, to tap: RingBuffer) {
        guard let data = buffer.mData else { return }
        let channelCount = Int(buffer.mNumberChannels)
        guard channelCount > 0 else { return }
        let src = data.assumingMemoryBound(to: Float.self)
        let frames = min(Int(buffer.mDataByteSize) / (channelCount * MemoryLayout<Float>.size), transcriptScratch.count)
        guard frames > 0 else { return }
        if channelCount == 1 {
            tap.write(src, frameCount: frames)
            return
        }
        transcriptScratch.withUnsafeMutableBufferPointer { dst in
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channelCount { sum += src[i * channelCount + ch] }
                dst[i] = sum / Float(channelCount)
            }
            tap.write(dst.baseAddress!, frameCount: frames)
        }
    }
```

- [ ] **Step 4: Uruchom testy i build**

Run: `make test && ./build.sh`
Expected: `PASS router_tap_test`, `PASS transcript_store_test`, `Gotowe: build/AIHeadset.app`

- [ ] **Step 5: Commit**

```bash
git add daemon/AIHeadset/Config.swift daemon/AIHeadset/AudioRouter.swift tools/router_tap_test.swift tools/run_tests.sh
git commit -m "Router: bufory mono dla transkrypcji rozmówców i mikrofonu w każdym trybie"
```

---

### Task 3: Protokół silnika i sesja transkrypcji (pompa)

**Files:**
- Create: `daemon/AIHeadset/SpeechTranscriber.swift`
- Create: `daemon/AIHeadset/TranscriptionSession.swift`
- Modify: `daemon/AIHeadset/Resampler.swift` (nowa fabryka w rozszerzeniu)
- Modify: `daemon/AIHeadset/Transcript.swift` (`case caller`)
- Modify: `tools/run_tests.sh`
- Test: `tools/transcription_session_test.swift`

**Interfaces:**
- Consumes: `AudioRouter.callerTranscriptTap`, `.micTranscriptTap`, `.sampleRate`; `TranscriptStore.apply`; `Transcript.append(_:_:)`
- Produces:
  - `protocol SpeechTranscriber: AnyObject { var onSegment: ((TranscriptSegment) -> Void)? { get set }; var onError: ((Error) -> Void)? { get set }; func start() throws; func feed(pcm16Mono16k: Data); func stop() }`
  - `Resampler.monoDeviceToSpeech(deviceSampleRate: Double) throws -> Resampler`
  - `final class TranscriptionSession { var onError: ((TranscriptSpeaker, Error) -> Void)?; init(router: AudioRouter, store: TranscriptStore, journal: Transcript?, makeTranscriber: (TranscriptSpeaker) throws -> SpeechTranscriber) throws; func start() throws; func stop(); func pumpOnce() }`
  - `Transcript.Speaker.caller`

- [ ] **Step 1: Napisz test**

`tools/transcription_session_test.swift`:

```swift
// Pompa: bufor rozmówców -> resampling -> właściwy silnik; segment -> magazyn.
import AVFoundation
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}

final class FakeTranscriber: SpeechTranscriber {
    var onSegment: ((TranscriptSegment) -> Void)?
    var onError: ((Error) -> Void)?
    var started = false, stopped = false
    var bytes = 0
    func start() throws { started = true }
    func feed(pcm16Mono16k: Data) { bytes += pcm16Mono16k.count }
    func stop() { stopped = true }
}

let router = AudioRouter(aggregateDeviceID: 0, sampleRate: 48000)
let store = TranscriptStore()
var fakes: [TranscriptSpeaker: FakeTranscriber] = [:]
let session = try TranscriptionSession(router: router, store: store, journal: nil) { speaker in
    let fake = FakeTranscriber()
    fakes[speaker] = fake
    return fake
}
try session.start()
check(fakes[.caller]?.started == true && fakes[.me]?.started == true, "oba silniki wystartowały")

// 300 ms tonu 440 Hz po stronie rozmówców, w trzech porcjach jak z wątku IO.
var tone = (0..<4800).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000)) * 0.3 }
for _ in 0..<3 {
    tone.withUnsafeBufferPointer { router.callerTranscriptTap.write($0.baseAddress!, frameCount: 4800) }
    session.pumpOnce()
}
let callerBytes = fakes[.caller]?.bytes ?? 0
// 14400 ramek @ 48 kHz = 4800 ramek @ 16 kHz = 9600 B; konwerter trzyma
// kilka ms na filtr, więc dopuszczamy niedomiar.
check(callerBytes > 8000 && callerBytes <= 9600, "rozmówcy: \(callerBytes) B PCM16 16 kHz")
check(callerBytes % 2 == 0, "pełne próbki Int16")
check(fakes[.me]?.bytes == 0, "mikrofon cichy -> nic do silnika 'me'")

// Segment z silnika trafia do magazynu na głównym wątku.
fakes[.caller]?.onSegment?(TranscriptSegment(id: UUID(), speaker: .caller, text: "Dzień dobry",
                                             start: Date(), end: Date(), isFinal: true))
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
check(store.paragraphs.count == 1, "segment w magazynie")

// Przebudowa audio: stop starej sesji, nowa na nowym routerze, magazyn zostaje.
session.stop()
check(fakes[.caller]?.stopped == true && fakes[.me]?.stopped == true, "oba silniki zatrzymane")
let router2 = AudioRouter(aggregateDeviceID: 0, sampleRate: 44100)
let session2 = try TranscriptionSession(router: router2, store: store, journal: nil) { _ in FakeTranscriber() }
try session2.start()
check(store.paragraphs.count == 1, "transkrypt przeżył przebudowę")
session2.stop()

if failures > 0 { exit(1) }
print("PASS transcription_session_test")
```

Wpis w `tools/run_tests.sh`:

```bash
    "transcription_session_test: $A/TranscriptionSession.swift $A/SpeechTranscriber.swift $A/TranscriptModel.swift $A/TranscriptStore.swift $A/Transcript.swift $A/Resampler.swift $A/AudioRouter.swift $A/RingBuffer.swift $A/Config.swift $A/Log.swift $A/AggregateDevice.swift $A/AudioDeviceUtil.swift"
```

- [ ] **Step 2: Uruchom i sprawdź, że nie przechodzi**

Run: `make test`
Expected: `BUILD FAIL  transcription_session_test` (`cannot find type 'SpeechTranscriber'`)

- [ ] **Step 3: Zaimplementuj**

`daemon/AIHeadset/SpeechTranscriber.swift`:

```swift
import Foundation

/// Silnik rozpoznawania mowy dla JEDNEGO mówcy. `feed` jest wołane z
/// kolejki sesji transkrypcji (szeregowo); `onSegment`/`onError` mogą
/// przyjść z dowolnego wątku -- sesja przekazuje je na główny.
protocol SpeechTranscriber: AnyObject {
    var onSegment: ((TranscriptSegment) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func start() throws
    /// PCM16 LE, mono, 16 kHz.
    func feed(pcm16Mono16k: Data)
    func stop()
}
```

W `Resampler.swift`, wewnątrz `extension Resampler`:

```swift
    /// Bufor transkrypcji (Float32 mono, częstotliwość urządzenia) ->
    /// format silników rozpoznawania (PCM16 mono 16 kHz).
    static func monoDeviceToSpeech(deviceSampleRate: Double) throws -> Resampler {
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: deviceSampleRate, channels: 1),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                                channels: 1, interleaved: true) else {
            throw ResamplerError.converterCreationFailed
        }
        return try Resampler(from: inputFormat, to: outputFormat)
    }
```

W `Transcript.swift`, w `enum Speaker` po `case agent`:

```swift
        /// Strona rozmówców (Bridge.in); `user` to mikrofon użytkownika.
        case caller
```

`daemon/AIHeadset/TranscriptionSession.swift`:

```swift
import AVFoundation
import Foundation

/// Pompa transkrypcji: co ~50 ms opróżnia bufory routera, resampluje do
/// PCM16 16 kHz i karmi silnik każdego mówcy. Segmenty trafiają do
/// magazynu (główny wątek) i -- gotowe -- do dziennika JSONL.
///
/// Działa niezależnie od trybu i od agenta głosowego. Przy przebudowie
/// audio sesję się zatrzymuje i tworzy nową na nowym routerze; magazyn
/// (a więc i okno) zostaje.
final class TranscriptionSession {
    var onError: ((TranscriptSpeaker, Error) -> Void)?

    private struct Stream {
        let speaker: TranscriptSpeaker
        let tap: RingBuffer
        let resampler: Resampler
        let transcriber: SpeechTranscriber
    }

    private let store: TranscriptStore
    private let journal: Transcript?
    private let streams: [Stream]
    private let format: AVAudioFormat
    private let queue = DispatchQueue(label: "cat.sysop.aiheadset.transcription")
    private var timer: DispatchSourceTimer?

    init(router: AudioRouter, store: TranscriptStore, journal: Transcript?,
         makeTranscriber: (TranscriptSpeaker) throws -> SpeechTranscriber) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: router.sampleRate, channels: 1) else {
            throw Resampler.ResamplerError.converterCreationFailed
        }
        self.format = format
        self.store = store
        self.journal = journal
        self.streams = try [(TranscriptSpeaker.caller, router.callerTranscriptTap),
                            (TranscriptSpeaker.me, router.micTranscriptTap)].map { speaker, tap in
            Stream(speaker: speaker, tap: tap,
                   resampler: try Resampler.monoDeviceToSpeech(deviceSampleRate: router.sampleRate),
                   transcriber: try makeTranscriber(speaker))
        }
        for stream in streams {
            let speaker = stream.speaker
            stream.transcriber.onSegment = { [weak self] segment in
                DispatchQueue.main.async { self?.deliver(segment) }
            }
            stream.transcriber.onError = { [weak self] error in
                Log.error("transkrypcja (\(speaker.rawValue)): \(error)")
                DispatchQueue.main.async { self?.onError?(speaker, error) }
            }
        }
    }

    func start() throws {
        for stream in streams {
            stream.tap.clear() // nie transkrybujemy dźwięku sprzed startu
            try stream.transcriber.start()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.pumpOnce() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {} // dokończ ewentualną porcję w locie
        streams.forEach { $0.transcriber.stop() }
    }

    /// Jedna porcja dla każdego mówcy. Publiczne dla testów; w działaniu
    /// woła je timer na `queue`.
    func pumpOnce() {
        for stream in streams {
            let frames = stream.tap.framesAvailable
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            stream.tap.read(channel, frameCount: frames)
            guard let converted = try? stream.resampler.convert(buffer),
                  let samples = converted.int16ChannelData?[0],
                  converted.frameLength > 0 else { continue }
            stream.transcriber.feed(pcm16Mono16k: Data(bytes: samples, count: Int(converted.frameLength) * 2))
        }
    }

    private func deliver(_ segment: TranscriptSegment) {
        store.apply(segment)
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if segment.isFinal, !text.isEmpty {
            journal?.append(segment.speaker == .me ? .user : .caller, text)
        }
    }
}
```

Sprawdź w `RingBuffer.swift`, że `clear()` i `framesAvailable` istnieją (istnieją: `func clear()`, `framesAvailable` używane przez `AgentSession`).

- [ ] **Step 4: Uruchom testy**

Run: `make test`
Expected: trzy `PASS`

- [ ] **Step 5: Commit**

```bash
git add daemon/AIHeadset/SpeechTranscriber.swift daemon/AIHeadset/TranscriptionSession.swift daemon/AIHeadset/Resampler.swift daemon/AIHeadset/Transcript.swift tools/transcription_session_test.swift tools/run_tests.sh
git commit -m "Sesja transkrypcji: pompa buforów do silników, segmenty do magazynu i dziennika"
```

---

### Task 4: Cięcie wypowiedzi po ciszy

**Files:**
- Create: `daemon/AIHeadset/SilenceSegmenter.swift`
- Modify: `tools/run_tests.sh`
- Test: `tools/silence_segmenter_test.swift`

**Interfaces:**
- Produces: `struct SilenceSegmenter { init(sampleRate: Double = 16000, threshold: Float = 0.015, minSilence: TimeInterval = 0.5, maxChunk: TimeInterval = 5, minSpeech: TimeInterval = 0.3); mutating func append(_ pcm16: Data) -> [Data]; mutating func flush() -> Data? }` — zwraca zamknięte fragmenty zawierające mowę (z końcową ciszą), sama cisza jest odrzucana.

- [ ] **Step 1: Napisz test**

`tools/silence_segmenter_test.swift`:

```swift
// Cięcie PCM16 na wypowiedzi: mowa + cisza, sama cisza, długi monolog.
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}

func pcm(tone seconds: Double, amplitude: Double = 0.3) -> Data {
    let samples = (0..<Int(seconds * 16000)).map { Int16(sin(Double($0) * 2 * .pi * 300 / 16000) * amplitude * 32767) }
    return samples.withUnsafeBytes { Data($0) }
}
func pcm(silence seconds: Double) -> Data { Data(count: Int(seconds * 16000) * 2) }

/// Podaje dane porcjami po 50 ms, jak pompa transkrypcji.
func feed(_ segmenter: inout SilenceSegmenter, _ data: Data) -> [Data] {
    var chunks: [Data] = []
    var offset = 0
    while offset < data.count {
        let end = min(offset + 1600, data.count)
        chunks += segmenter.append(data.subdata(in: offset..<end))
        offset = end
    }
    return chunks
}

// 1 s mowy + 0,6 s ciszy -> jeden fragment ~1,5 s (mowa + 0,5 s ciszy).
do {
    var s = SilenceSegmenter()
    let chunks = feed(&s, pcm(tone: 1.0) + pcm(silence: 0.6))
    check(chunks.count == 1, "jeden fragment, jest \(chunks.count)")
    let seconds = Double(chunks.first?.count ?? 0) / 32000
    check(abs(seconds - 1.5) < 0.05, "długość \(seconds) s")
}

// Sama cisza -> nic, i bufor nie rośnie (flush pusty).
do {
    var s = SilenceSegmenter()
    check(feed(&s, pcm(silence: 3)).isEmpty, "cisza nie daje fragmentów")
    check(s.flush() == nil, "flush po ciszy pusty")
}

// 12 s monologu -> fragmenty po 5 s, reszta przez flush.
do {
    var s = SilenceSegmenter()
    let chunks = feed(&s, pcm(tone: 12))
    check(chunks.count == 2, "dwa pełne fragmenty, jest \(chunks.count)")
    check(chunks.allSatisfy { abs(Double($0.count) / 32000 - 5) < 0.02 }, "po 5 s")
    let rest = s.flush()
    check(abs(Double(rest?.count ?? 0) / 32000 - 2) < 0.02, "reszta 2 s przez flush")
}

// Trzask krótszy niż 0,3 s -> nie jest mową.
do {
    var s = SilenceSegmenter()
    check(feed(&s, pcm(tone: 0.1) + pcm(silence: 1)).isEmpty, "krótki trzask odrzucony")
}

if failures > 0 { exit(1) }
print("PASS silence_segmenter_test")
```

Wpis: `"silence_segmenter_test: $A/SilenceSegmenter.swift"`

- [ ] **Step 2: Uruchom i sprawdź, że nie przechodzi**

Run: `make test`
Expected: `BUILD FAIL  silence_segmenter_test`

- [ ] **Step 3: Zaimplementuj**

`daemon/AIHeadset/SilenceSegmenter.swift`:

```swift
import Foundation

/// Tnie strumień PCM16 mono na wypowiedzi: fragment zamyka się po
/// `minSilence` ciszy następującej po co najmniej `minSpeech` mowy, albo
/// po `maxChunk` niezależnie od wszystkiego. Sama cisza (i krótkie
/// trzaski) jest odrzucana, żeby nie płacić za transkrypcję niczego.
///
/// Prosty próg RMS w ramkach 10 ms -- wystarcza na mikrofon i dźwięk z
/// komunikatora, które i tak mają już tłumienie szumu.
struct SilenceSegmenter {
    private let sampleRate: Double
    private let threshold: Float
    private let minSilenceSamples: Int
    private let maxChunkSamples: Int
    private let minSpeechSamples: Int
    private let frameBytes: Int

    private var pending = Data()
    private var current = Data()
    private var speechSamples = 0
    private var trailingSilenceSamples = 0

    init(sampleRate: Double = 16000, threshold: Float = 0.015, minSilence: TimeInterval = 0.5,
         maxChunk: TimeInterval = 5, minSpeech: TimeInterval = 0.3) {
        self.sampleRate = sampleRate
        self.threshold = threshold
        self.minSilenceSamples = Int(minSilence * sampleRate)
        self.maxChunkSamples = Int(maxChunk * sampleRate)
        self.minSpeechSamples = Int(minSpeech * sampleRate)
        self.frameBytes = Int(sampleRate / 100) * 2
    }

    mutating func append(_ pcm16: Data) -> [Data] {
        pending.append(pcm16)
        var chunks: [Data] = []
        while pending.count >= frameBytes {
            let frame = Data(pending.prefix(frameBytes))
            pending = Data(pending.dropFirst(frameBytes))
            let frameSamples = frameBytes / 2
            current.append(frame)
            if Self.rms(frame) >= threshold {
                speechSamples += frameSamples
                trailingSilenceSamples = 0
            } else {
                trailingSilenceSamples += frameSamples
            }

            let hasSpeech = speechSamples >= minSpeechSamples
            if (hasSpeech && trailingSilenceSamples >= minSilenceSamples) || current.count / 2 >= maxChunkSamples {
                if hasSpeech { chunks.append(current) }
                reset()
            } else if !hasSpeech && trailingSilenceSamples >= minSilenceSamples {
                reset() // sama cisza albo trzask -- nie trzymamy
            }
        }
        return chunks
    }

    mutating func flush() -> Data? {
        defer { reset(); pending = Data() }
        return speechSamples >= minSpeechSamples ? current : nil
    }

    private mutating func reset() {
        current = Data()
        speechSamples = 0
        trailingSilenceSamples = 0
    }

    private static func rms(_ frame: Data) -> Float {
        frame.withUnsafeBytes { raw -> Float in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum: Float = 0
            for sample in samples {
                let value = Float(sample) / 32768
                sum += value * value
            }
            return (sum / Float(samples.count)).squareRoot()
        }
    }
}
```

- [ ] **Step 4: Uruchom testy**

Run: `make test`
Expected: cztery `PASS`

- [ ] **Step 5: Commit**

```bash
git add daemon/AIHeadset/SilenceSegmenter.swift tools/silence_segmenter_test.swift tools/run_tests.sh
git commit -m "Cięcie wypowiedzi po ciszy dla silników Whisper i Scribe"
```

---

### Task 5: Silnik Whisper (lokalny `whisper-server`)

**Files:**
- Create: `daemon/AIHeadset/WhisperTranscriber.swift`
- Modify: `tools/run_tests.sh`
- Test: `tools/whisper_test.swift`

**Interfaces:**
- Consumes: `SpeechTranscriber`, `SilenceSegmenter`, `TranscriptSegment`
- Produces:
  - `enum WAV { static func encode(pcm16Mono16k: Data) -> Data }`
  - `enum WhisperServerAPI { enum APIError: Error { case http(Int), invalidResponse }; static func request(baseURL: URL, wav: Data, boundary: String) -> URLRequest; static func parseText(_ data: Data) throws -> String }`
  - `final class WhisperTranscriber: SpeechTranscriber { init(baseURL: URL, speaker: TranscriptSpeaker, session: URLSession = .shared) }`

- [ ] **Step 1: Napisz test**

`tools/whisper_test.swift`:

```swift
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
```

Wpis: `"whisper_test: $A/WhisperTranscriber.swift $A/SilenceSegmenter.swift $A/SpeechTranscriber.swift $A/TranscriptModel.swift $A/Log.swift"`

- [ ] **Step 2: Uruchom i sprawdź, że nie przechodzi**

Run: `make test`
Expected: `BUILD FAIL  whisper_test`

- [ ] **Step 3: Zaimplementuj**

`daemon/AIHeadset/WhisperTranscriber.swift`:

```swift
import Foundation

/// PCM16 mono 16 kHz w kontenerze WAV -- tego oczekuje whisper-server.
enum WAV {
    static func encode(pcm16Mono16k pcm: Data) -> Data {
        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le32(16)
        le16(1)            // PCM
        le16(1)            // mono
        le32(16000)        // częstotliwość
        le32(16000 * 2)    // bajty na sekundę
        le16(2)            // bajty na ramkę
        le16(16)           // bity na próbkę
        data.append(contentsOf: Array("data".utf8)); le32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

/// whisper.cpp `whisper-server`: POST /inference, multipart z plikiem
/// audio, odpowiedź `{"text": "..."}`. Język ustawia się przy starcie
/// serwera (`-l pl`).
enum WhisperServerAPI {
    enum APIError: Error, CustomStringConvertible {
        case http(Int)
        case invalidResponse
        var description: String {
            switch self {
            case .http(let code): return "whisper-server HTTP \(code)"
            case .invalidResponse: return "whisper-server: nieoczekiwana odpowiedź"
            }
        }
    }

    static func request(baseURL: URL, wav: Data, boundary: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n".utf8))
        field("response_format", "json")
        field("temperature", "0.0")
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    static func parseText(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw APIError.invalidResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Lokalny Whisper: tnie dźwięk po ciszy i wysyła każdą wypowiedź do
/// whisper-server. Tylko segmenty final (Whisper nie daje partiali).
/// Zapytania idą po kolei, żeby wypowiedzi nie przestawiały się.
final class WhisperTranscriber: SpeechTranscriber {
    var onSegment: ((TranscriptSegment) -> Void)?
    var onError: ((Error) -> Void)?

    private let baseURL: URL
    private let speaker: TranscriptSpeaker
    private let session: URLSession
    private var segmenter = SilenceSegmenter()
    private var chain: Task<Void, Never>?
    private var stopped = true

    init(baseURL: URL, speaker: TranscriptSpeaker, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.speaker = speaker
        self.session = session
    }

    func start() throws {
        stopped = false
    }

    func feed(pcm16Mono16k: Data) {
        guard !stopped else { return }
        for chunk in segmenter.append(pcm16Mono16k) { send(chunk) }
    }

    func stop() {
        if let rest = segmenter.flush() { send(rest) }
        stopped = true
    }

    private func send(_ chunk: Data) {
        let end = Date()
        let start = end.addingTimeInterval(-Double(chunk.count) / 32000)
        let request = WhisperServerAPI.request(baseURL: baseURL, wav: WAV.encode(pcm16Mono16k: chunk),
                                               boundary: UUID().uuidString)
        let previous = chain
        chain = Task { [weak self, session, speaker] in
            await previous?.value
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw WhisperServerAPI.APIError.http(http.statusCode)
                }
                let text = try WhisperServerAPI.parseText(data)
                guard !text.isEmpty else { return }
                self?.onSegment?(TranscriptSegment(id: UUID(), speaker: speaker, text: text,
                                                   start: start, end: end, isFinal: true))
            } catch {
                self?.onError?(error)
            }
        }
    }
}
```

- [ ] **Step 4: Uruchom testy**

Run: `make test`
Expected: pięć `PASS`

- [ ] **Step 5: Commit**

```bash
git add daemon/AIHeadset/WhisperTranscriber.swift tools/whisper_test.swift tools/run_tests.sh
git commit -m "Silnik transkrypcji: lokalny whisper-server"
```

---

### Task 6: Silnik ElevenLabs Scribe (realtime)

Protokół zweryfikowany 2026-10-09 w dokumentacji ElevenLabs („Server-side streaming”): `wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime`, nagłówek `xi-api-key`, wysyłane `{"message_type":"input_audio_chunk","audio_base_64":…,"commit":bool,"sample_rate":16000}`, odbierane `session_started`, `partial_transcript{text}`, `committed_transcript{text}`, `input_error`.

**Files:**
- Create: `daemon/AIHeadset/ScribeTranscriber.swift`
- Modify: `tools/run_tests.sh`
- Test: `tools/scribe_test.swift`

**Interfaces:**
- Consumes: `SpeechTranscriber`, `SilenceSegmenter`
- Produces:
  - `enum ScribeProtocol { static let endpoint: URL; enum Event: Equatable { case sessionStarted, partial(String), committed(String), error(String) }; static func audioMessage(_ pcm16: Data, commit: Bool) -> String; static func parse(_ text: String) -> Event? }`
  - `final class ScribeTranscriber: SpeechTranscriber { init(apiKey: String, speaker: TranscriptSpeaker) }`

- [ ] **Step 1: Napisz test**

`tools/scribe_test.swift`:

```swift
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
```

Wpis: `"scribe_test: $A/ScribeTranscriber.swift $A/SilenceSegmenter.swift $A/SpeechTranscriber.swift $A/TranscriptModel.swift $A/Log.swift"`

- [ ] **Step 2: Uruchom i sprawdź, że nie przechodzi**

Run: `make test`
Expected: `BUILD FAIL  scribe_test`

- [ ] **Step 3: Zaimplementuj**

`daemon/AIHeadset/ScribeTranscriber.swift`:

```swift
import Foundation

/// ElevenLabs Scribe realtime -- kształt wiadomości zweryfikowany w
/// dokumentacji „Server-side streaming” (2026-10-09).
enum ScribeProtocol {
    static let endpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime")!

    enum Event: Equatable {
        case sessionStarted
        case partial(String)
        case committed(String)
        case error(String)
    }

    static func audioMessage(_ pcm16: Data, commit: Bool) -> String {
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": pcm16.base64EncodedString(),
            "commit": commit,
            "sample_rate": 16000,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ text: String) -> Event? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["message_type"] as? String else { return nil }
        switch type {
        case "session_started": return .sessionStarted
        case "partial_transcript": return .partial(json["text"] as? String ?? "")
        case "committed_transcript": return .committed(json["text"] as? String ?? "")
        default:
            if type.contains("error") {
                return .error((json["error"] as? String) ?? (json["message"] as? String) ?? type)
            }
            return nil
        }
    }
}

/// Strumień do Scribe: dźwięk leci na bieżąco, a koniec wypowiedzi
/// (cisza wg SilenceSegmenter) wysyła commit -- wtedy serwer zwraca
/// `committed_transcript`. Partiale aktualizują bieżący segment.
final class ScribeTranscriber: SpeechTranscriber {
    var onSegment: ((TranscriptSegment) -> Void)?
    var onError: ((Error) -> Void)?

    private let apiKey: String
    private let speaker: TranscriptSpeaker
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var segmenter = SilenceSegmenter()
    private let lock = NSLock()
    private var currentID: UUID?
    private var currentStart = Date()
    private var stopped = true

    init(apiKey: String, speaker: TranscriptSpeaker) {
        self.apiKey = apiKey
        self.speaker = speaker
    }

    func start() throws {
        stopped = false
        connect()
    }

    func feed(pcm16Mono16k: Data) {
        guard let task, !stopped else { return }
        task.send(.string(ScribeProtocol.audioMessage(pcm16Mono16k, commit: false))) { _ in }
        if !segmenter.append(pcm16Mono16k).isEmpty {
            task.send(.string(ScribeProtocol.audioMessage(Data(), commit: true))) { _ in }
        }
    }

    func stop() {
        stopped = true
        task?.send(.string(ScribeProtocol.audioMessage(Data(), commit: true))) { _ in }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func connect() {
        var request = URLRequest(url: ScribeProtocol.endpoint)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                guard !self.stopped else { return }
                self.onError?(error)
                // Jedna próba ponownego połączenia po 2 s -- zerwane
                // połączenie w trakcie rozmowy nie może zakończyć transkrypcji.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.connect()
                }
            case .success(let message):
                if case .string(let text) = message, let event = ScribeProtocol.parse(text) {
                    self.handle(event)
                }
                self.receive(on: task)
            }
        }
    }

    private func handle(_ event: ScribeProtocol.Event) {
        switch event {
        case .sessionStarted:
            Log.info("Scribe: sesja rozpoczęta (\(speaker.rawValue))")
        case .partial(let text):
            guard !text.isEmpty else { return }
            emit(text, isFinal: false)
        case .committed(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emit(text, isFinal: true) }
            lock.lock(); currentID = nil; lock.unlock()
        case .error(let message):
            onError?(NSError(domain: "Scribe", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }

    private func emit(_ text: String, isFinal: Bool) {
        lock.lock()
        if currentID == nil { currentID = UUID(); currentStart = Date() }
        let id = currentID!
        let start = currentStart
        lock.unlock()
        onSegment?(TranscriptSegment(id: id, speaker: speaker, text: text, start: start, end: Date(), isFinal: isFinal))
    }
}
```

- [ ] **Step 4: Uruchom testy**

Run: `make test`
Expected: sześć `PASS`

- [ ] **Step 5: Commit**

```bash
git add daemon/AIHeadset/ScribeTranscriber.swift tools/scribe_test.swift tools/run_tests.sh
git commit -m "Silnik transkrypcji: ElevenLabs Scribe realtime"
```

---

### Task 7: Silnik Apple (na urządzeniu), ustawienia i fabryka silników

**Files:**
- Create: `daemon/AIHeadset/AppleSpeechTranscriber.swift`
- Create: `daemon/AIHeadset/TranscriptionSettings.swift`
- Modify: `daemon/AIHeadset/Info.plist` (klucz zgody)
- Modify: `daemon/AIHeadset/Resources/pl.lproj/Localizable.strings`, `en.lproj/Localizable.strings`
- Modify: `tools/run_tests.sh`
- Test: `tools/transcription_settings_test.swift`

**Interfaces:**
- Consumes: `SpeechTranscriber`, `SilenceSegmenter`, `WhisperTranscriber`, `ScribeTranscriber`, `AgentSettings.apiKey`
- Produces:
  - `final class AppleSpeechTranscriber: SpeechTranscriber { enum AppleSpeechError: Error { case notAuthorized, unsupportedLanguage, onDeviceUnavailable }; init(language: String, speaker: TranscriptSpeaker); static func makeBuffer(_ pcm16: Data) -> AVAudioPCMBuffer? }`
  - `enum TranscriberEngine: String, CaseIterable { case apple, scribe, whisper }`
  - `struct TranscriptionSettings { init(defaults: UserDefaults = .standard); var engine: TranscriberEngine; var language: String; var whisperURL: URL; var isEnabled: Bool; static let languages: [String] }` — klucze `transcription.engine`, `transcription.language`, `transcription.whisperURL`, `transcription.enabled`; domyślnie `.apple`, `"pl-PL"`, `http://127.0.0.1:8080`, `true`.
  - `enum TranscriberFactory { enum FactoryError: Error { case missingElevenLabsKey }; static func make(_ speaker: TranscriptSpeaker, settings: TranscriptionSettings, elevenLabsKey: String?) throws -> SpeechTranscriber }`
  - `extension TranscriberEngine { var title: String; var privacyNote: String; var isLocal: Bool }`

- [ ] **Step 1: Napisz test**

`tools/transcription_settings_test.swift`:

```swift
// Ustawienia transkrypcji: domyślne, zapis, fabryka silników.
import AVFoundation
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}

let suite = "aiheadset-test-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }

var settings = TranscriptionSettings(defaults: defaults)
check(settings.engine == .apple, "domyślnie Apple")
check(settings.language == "pl-PL", "domyślnie polski")
check(settings.whisperURL.absoluteString == "http://127.0.0.1:8080", "domyślny adres Whisper")
check(settings.isEnabled, "domyślnie włączona")

settings.engine = .whisper
settings.whisperURL = URL(string: "http://10.0.0.5:9000")!
settings.isEnabled = false
let reread = TranscriptionSettings(defaults: defaults)
check(reread.engine == .whisper && reread.whisperURL.port == 9000 && !reread.isEnabled, "zapis i odczyt")

check(try TranscriberFactory.make(.me, settings: reread, elevenLabsKey: nil) is WhisperTranscriber, "fabryka: Whisper")
settings.engine = .apple
check(try TranscriberFactory.make(.me, settings: settings, elevenLabsKey: nil) is AppleSpeechTranscriber, "fabryka: Apple")
settings.engine = .scribe
check(try TranscriberFactory.make(.caller, settings: settings, elevenLabsKey: "k") is ScribeTranscriber, "fabryka: Scribe")
do {
    _ = try TranscriberFactory.make(.caller, settings: settings, elevenLabsKey: nil)
    check(false, "Scribe bez klucza powinien rzucić")
} catch TranscriberFactory.FactoryError.missingElevenLabsKey {
} catch {
    check(false, "zły błąd: \(error)")
}

// Bufor dla Apple: PCM16 16 kHz mono, liczba ramek = bajty / 2.
let buffer = AppleSpeechTranscriber.makeBuffer(Data(count: 3200))
check(buffer?.frameLength == 1600 && buffer?.format.sampleRate == 16000, "bufor Apple")

if failures > 0 { exit(1) }
print("PASS transcription_settings_test")
```

Wpis: `"transcription_settings_test: $A/TranscriptionSettings.swift $A/AppleSpeechTranscriber.swift $A/WhisperTranscriber.swift $A/ScribeTranscriber.swift $A/SilenceSegmenter.swift $A/SpeechTranscriber.swift $A/TranscriptModel.swift $A/Log.swift $A/Strings.swift"`

- [ ] **Step 2: Uruchom i sprawdź, że nie przechodzi**

Run: `make test`
Expected: `BUILD FAIL  transcription_settings_test`

- [ ] **Step 3: Zaimplementuj silnik Apple**

`daemon/AIHeadset/AppleSpeechTranscriber.swift`:

```swift
import AVFoundation
import Speech

/// Rozpoznawanie mowy Apple, wyłącznie na urządzeniu (dźwięk nie
/// opuszcza Maca). Jedno zadanie rozpoznawania = jedna wypowiedź:
/// po ciszy (SilenceSegmenter) albo po 45 s zadanie jest kończone i
/// startuje następne -- dzięki temu segmenty mają rozmiar zdań, a nie
/// minut, i nie trafiamy w limit długości zadania.
final class AppleSpeechTranscriber: SpeechTranscriber {
    enum AppleSpeechError: Error, CustomStringConvertible {
        case notAuthorized, unsupportedLanguage, onDeviceUnavailable
        var description: String {
            switch self {
            case .notAuthorized: return L("transcription.error.speechDenied")
            case .unsupportedLanguage: return L("transcription.error.language")
            case .onDeviceUnavailable: return L("transcription.error.onDevice")
            }
        }
    }

    var onSegment: ((TranscriptSegment) -> Void)?
    var onError: ((Error) -> Void)?

    private let language: String
    private let speaker: TranscriptSpeaker
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var segmenter = SilenceSegmenter(maxChunk: 45)
    private var stopped = true

    init(language: String, speaker: TranscriptSpeaker) {
        self.language = language
        self.speaker = speaker
    }

    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    static func makeBuffer(_ pcm16: Data) -> AVAudioPCMBuffer? {
        let frames = pcm16.count / 2
        guard frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.int16ChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { raw in
            if let src = raw.bindMemory(to: Int16.self).baseAddress { dst.update(from: src, count: frames) }
        }
        return buffer
    }

    func start() throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw AppleSpeechError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            throw AppleSpeechError.unsupportedLanguage
        }
        guard recognizer.supportsOnDeviceRecognition else { throw AppleSpeechError.onDeviceUnavailable }
        self.recognizer = recognizer
        stopped = false
        beginTask()
    }

    func feed(pcm16Mono16k: Data) {
        guard !stopped, let buffer = Self.makeBuffer(pcm16Mono16k) else { return }
        request?.append(buffer)
        if !segmenter.append(pcm16Mono16k).isEmpty {
            // Koniec wypowiedzi: zamknij zadanie (przyjdzie wynik final)
            // i od razu otwórz następne na dalszy dźwięk.
            request?.endAudio()
            beginTask()
        }
    }

    func stop() {
        stopped = true
        request?.endAudio()
        request = nil
        task = nil
    }

    private func beginTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let id = UUID()
        let start = Date()
        let speaker = self.speaker
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                self?.onSegment?(TranscriptSegment(id: id, speaker: speaker, text: text, start: start,
                                                   end: Date(), isFinal: result.isFinal))
            } else if let error = error as NSError?,
                      // 1110 = „nie wykryto mowy”, 301 = zadanie anulowane -- to nie są awarie.
                      ![1110, 301].contains(error.code) {
                self?.onError?(error)
            }
        }
        self.request = request
    }
}
```

- [ ] **Step 4: Zaimplementuj ustawienia i fabrykę**

`daemon/AIHeadset/TranscriptionSettings.swift`:

```swift
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
```

- [ ] **Step 5: Info.plist i teksty**

W `daemon/AIHeadset/Info.plist`, obok `NSMicrophoneUsageDescription`:

```xml
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>AI Headset transcribes your calls on this Mac so you can follow, summarize and fact-check them.</string>
```

Dopisz na końcu `pl.lproj/Localizable.strings`:

```
/* Transcription */
"transcription.engine.apple" = "Apple — na tym Macu";
"transcription.engine.scribe" = "ElevenLabs Scribe — w chmurze";
"transcription.engine.whisper" = "Whisper — lokalny serwer";
"transcription.privacy.apple" = "Dźwięk nie opuszcza tego Maca.";
"transcription.privacy.scribe" = "Dźwięk jest wysyłany do ElevenLabs.";
"transcription.privacy.whisper" = "Dźwięk idzie do serwera Whisper pod podanym adresem.";
"transcription.error.speechDenied" = "Brak zgody na rozpoznawanie mowy — włącz ją w Ustawieniach systemowych.";
"transcription.error.language" = "Ten język nie jest obsługiwany przez rozpoznawanie mowy Apple.";
"transcription.error.onDevice" = "Rozpoznawanie mowy na urządzeniu jest niedostępne dla tego języka.";
"transcription.error.noKey" = "Scribe potrzebuje klucza API ElevenLabs (Ustawienia → Agent głosowy).";
"transcription.language.pl-PL" = "Polski";
"transcription.language.en-US" = "Angielski";
"speaker.me" = "Ja";
"speaker.caller" = "Rozmówcy";
```

Dopisz na końcu `en.lproj/Localizable.strings`:

```
/* Transcription */
"transcription.engine.apple" = "Apple — on this Mac";
"transcription.engine.scribe" = "ElevenLabs Scribe — in the cloud";
"transcription.engine.whisper" = "Whisper — local server";
"transcription.privacy.apple" = "Audio never leaves this Mac.";
"transcription.privacy.scribe" = "Audio is sent to ElevenLabs.";
"transcription.privacy.whisper" = "Audio goes to the Whisper server at the address below.";
"transcription.error.speechDenied" = "Speech recognition is not allowed — turn it on in System Settings.";
"transcription.error.language" = "Apple speech recognition does not support this language.";
"transcription.error.onDevice" = "On-device speech recognition is unavailable for this language.";
"transcription.error.noKey" = "Scribe needs an ElevenLabs API key (Settings → Voice Agent).";
"transcription.language.pl-PL" = "Polish";
"transcription.language.en-US" = "English";
"speaker.me" = "Me";
"speaker.caller" = "Others";
```

- [ ] **Step 6: Uruchom testy, lint tekstów i build**

Run: `make test && plutil -lint daemon/AIHeadset/Resources/*.lproj/Localizable.strings daemon/AIHeadset/Info.plist && ./build.sh`
Expected: siedem `PASS`, `OK` ×3, `Gotowe`

- [ ] **Step 7: Commit**

```bash
git add daemon/AIHeadset/AppleSpeechTranscriber.swift daemon/AIHeadset/TranscriptionSettings.swift daemon/AIHeadset/Info.plist daemon/AIHeadset/Resources tools/transcription_settings_test.swift tools/run_tests.sh
git commit -m "Silnik transkrypcji Apple na urządzeniu, ustawienia i fabryka silników"
```

---

### Task 8: Ustawienia z panelami: Agent głosowy + Transkrypcja

**Files:**
- Create: `daemon/AIHeadset/AgentSettingsPane.swift`
- Create: `daemon/AIHeadset/TranscriptionSettingsPane.swift`
- Modify: `daemon/AIHeadset/SettingsWindowController.swift` (cała zawartość)
- Modify: `daemon/AIHeadset/Resources/{pl,en}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `TranscriptionSettings`, `TranscriberEngine`, `AppleSpeechTranscriber.requestAuthorization`
- Produces:
  - `SettingsWindowController(onSave: @escaping () -> Void, onTranscriptionChange: @escaping () -> Void)` — nowy drugi parametr; `func show(pane: SettingsWindowController.Pane? = nil)`, `enum Pane: Int { case voiceAgent, transcription }`
  - `final class AgentSettingsPane: NSViewController` (init `onSave:`)
  - `final class TranscriptionSettingsPane: NSViewController` (init `onChange:`)

- [ ] **Step 1: Przenieś dotychczasowy formularz do panelu**

Utwórz `daemon/AIHeadset/AgentSettingsPane.swift` z CAŁEJ obecnej zawartości `SettingsWindowController.swift` (commit `2f8d4ef`), wprowadzając tylko te zmiany:

1. Nagłówek klasy: `final class AgentSettingsPane: NSViewController {` (bez `NSWindowDelegate`).
2. Zamiast `convenience init(onSave:)` z tworzeniem okna:

```swift
    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        title = L("settings.pane.voiceAgent")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nieużywane") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        buildUI()
        refreshAgents()
        runHealthCheck()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        view.window?.makeFirstResponder(nil) // zapis pola w trakcie edycji
    }
```

3. W `buildUI()` zamień `guard let contentView = window?.contentView else { return }` na `let contentView = view`.
4. Usuń `func windowWillClose(_:)`.
5. `private var onSave: (() -> Void)?` → `private let onSave: () -> Void`; wywołania `onSave?()` → `onSave()`.

- [ ] **Step 2: Napisz panel Transkrypcja**

`daemon/AIHeadset/TranscriptionSettingsPane.swift`:

```swift
import AppKit
import Speech

/// Panel „Transkrypcja”: silnik (przyciski radiowe -- 3 wzajemnie
/// wykluczające się opcje, HIG toggles.md › Radio buttons), język, adres
/// serwera Whisper (tylko dla Whisper), notka prywatności i stan zgody
/// na rozpoznawanie mowy (tylko dla Apple). Zmiany obowiązują od razu.
final class TranscriptionSettingsPane: NSViewController {
    private let settings = TranscriptionSettings()
    private let onChange: () -> Void
    private var engineButtons: [TranscriberEngine: NSButton] = [:]
    private let languagePopUp = NSPopUpButton()
    private let whisperField = NSTextField()
    private let privacyLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = NSButton()
    private var whisperRow: NSGridRow?
    private var permissionRow: NSGridRow?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        title = L("settings.pane.transcription")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nieużywane") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))

        let engineStack = NSStackView()
        engineStack.orientation = .vertical
        engineStack.alignment = .leading
        engineStack.spacing = 6
        for engine in TranscriberEngine.allCases {
            let button = NSButton(radioButtonWithTitle: engine.title, target: self, action: #selector(engineChanged(_:)))
            button.tag = TranscriberEngine.allCases.firstIndex(of: engine)!
            engineButtons[engine] = button
            engineStack.addArrangedSubview(button)
        }

        for code in TranscriptionSettings.languages {
            languagePopUp.addItem(withTitle: L("transcription.language.\(code)"))
            languagePopUp.lastItem?.representedObject = code
        }
        languagePopUp.target = self
        languagePopUp.action = #selector(languageChanged)

        whisperField.placeholderString = "http://127.0.0.1:8080"
        whisperField.target = self
        whisperField.action = #selector(whisperCommitted)
        whisperField.cell?.sendsActionOnEndEditing = true
        whisperField.widthAnchor.constraint(equalToConstant: 320).isActive = true

        for label in [privacyLabel, permissionLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 320
        }
        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionButton.action = #selector(permissionClicked)
        let permissionStack = NSStackView(views: [permissionLabel, permissionButton])
        permissionStack.orientation = .vertical
        permissionStack.alignment = .leading

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("settings.transcription.engine")), engineStack],
            [NSGridCell.emptyContentView, privacyLabel],
            [NSTextField(labelWithString: L("settings.transcription.language")), languagePopUp],
            [NSTextField(labelWithString: L("settings.transcription.whisperURL")), whisperField],
            [NSTextField(labelWithString: L("settings.transcription.permission")), permissionStack],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        grid.row(at: 1).topPadding = -4
        whisperRow = grid.row(at: 3)
        permissionRow = grid.row(at: 4)

        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        render() // stan zgody mógł się zmienić w Ustawieniach systemowych
    }

    private func render() {
        let engine = settings.engine
        for (candidate, button) in engineButtons { button.state = candidate == engine ? .on : .off }
        if let index = TranscriptionSettings.languages.firstIndex(of: settings.language) {
            languagePopUp.selectItem(at: index)
        }
        whisperField.stringValue = settings.whisperURL.absoluteString
        privacyLabel.stringValue = engine.privacyNote
        whisperRow?.isHidden = engine != .whisper
        permissionRow?.isHidden = engine != .apple

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            permissionLabel.stringValue = L("settings.transcription.permissionOK")
            permissionButton.isHidden = true
        case .notDetermined:
            permissionLabel.stringValue = L("settings.transcription.permissionAsk")
            permissionButton.title = L("settings.transcription.permissionRequest")
            permissionButton.isHidden = false
        default:
            permissionLabel.stringValue = L("transcription.error.speechDenied")
            permissionButton.title = L("settings.transcription.permissionOpen")
            permissionButton.isHidden = false
        }
    }

    @objc private func engineChanged(_ sender: NSButton) {
        settings.engine = TranscriberEngine.allCases[sender.tag]
        render()
        onChange()
    }

    @objc private func languageChanged() {
        guard let code = languagePopUp.selectedItem?.representedObject as? String else { return }
        settings.language = code
        onChange()
    }

    @objc private func whisperCommitted() {
        let text = whisperField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "http" || url.scheme == "https" else {
            whisperField.stringValue = settings.whisperURL.absoluteString // zły adres -> wróć do poprzedniego
            NSSound.beep()
            return
        }
        guard url != settings.whisperURL else { return }
        settings.whisperURL = url
        onChange()
    }

    @objc private func permissionClicked() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            AppleSpeechTranscriber.requestAuthorization { [weak self] _ in
                self?.render()
                self?.onChange()
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

- [ ] **Step 3: Okno z paskiem paneli**

Zastąp całą zawartość `daemon/AIHeadset/SettingsWindowController.swift`:

```swift
import AppKit

/// Okno Ustawień (⌘,) z panelami w pasku narzędzi (HIG settings.md):
/// pasek nieedytowalny, aktywny panel zaznaczony, tytuł okna = nazwa
/// panelu, otwiera się na ostatnio używanym panelu, bez minimalizacji
/// i powiększania. Kolejne panele (Modele, Narzędzia, Agenci, Notatki)
/// dochodzą razem ze swoimi funkcjami.
final class SettingsWindowController: NSWindowController {
    enum Pane: Int { case voiceAgent, transcription }

    private let tabs = NSTabViewController()
    private static let lastPaneKey = "settings.lastPane"

    /// `onSave` -- zmiana poświadczeń agenta głosowego.
    /// `onTranscriptionChange` -- zmiana ustawień transkrypcji.
    convenience init(onSave: @escaping () -> Void, onTranscriptionChange: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        self.init(window: window)

        tabs.tabStyle = .toolbar
        let voice = NSTabViewItem(viewController: AgentSettingsPane(onSave: onSave))
        voice.image = NSImage(systemSymbolName: "person.wave.2", accessibilityDescription: nil)
        let transcription = NSTabViewItem(viewController: TranscriptionSettingsPane(onChange: onTranscriptionChange))
        transcription.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        tabs.addTabViewItem(voice)
        tabs.addTabViewItem(transcription)
        tabs.selectedTabViewItemIndex = UserDefaults.standard.integer(forKey: Self.lastPaneKey)
        window.contentViewController = tabs
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            UserDefaults.standard.set(self.tabs.selectedTabViewItemIndex, forKey: Self.lastPaneKey)
        }
    }

    func show(pane: Pane? = nil) {
        if let pane { tabs.selectedTabViewItemIndex = pane.rawValue }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
```

`NSTabViewController` z `.toolbar` sam ustawia tytuł okna na `title` aktywnego panelu.

W `MenuBarController.openSettings()` zamień tworzenie kontrolera na:

```swift
            settingsWindowController = SettingsWindowController(onSave: { [weak self] in
                // Credentials may have changed -- AGENT mode may now be
                // available, and the agent list may now be fetchable.
                self?.refreshAgentList()
                self?.rebuildMenu()
            }, onTranscriptionChange: { [weak self] in
                self?.restartTranscription()
            })
```

i `showWindow`/`makeKeyAndOrderFront` na `settingsWindowController?.show()`. Do czasu Task 9 dodaj w `MenuBarController` pustą metodę (Task 9 wypełnia jej treść):

```swift
    private func restartTranscription() {}
```

Teksty — `pl.lproj`:

```
"settings.pane.voiceAgent" = "Agent głosowy";
"settings.pane.transcription" = "Transkrypcja";
"settings.transcription.engine" = "Silnik:";
"settings.transcription.language" = "Język:";
"settings.transcription.whisperURL" = "Serwer Whisper:";
"settings.transcription.permission" = "Zgoda:";
"settings.transcription.permissionOK" = "✓ Rozpoznawanie mowy dozwolone.";
"settings.transcription.permissionAsk" = "macOS jeszcze nie pytał o zgodę na rozpoznawanie mowy.";
"settings.transcription.permissionRequest" = "Poproś o zgodę";
"settings.transcription.permissionOpen" = "Otwórz Ustawienia systemowe";
```

`en.lproj`:

```
"settings.pane.voiceAgent" = "Voice Agent";
"settings.pane.transcription" = "Transcription";
"settings.transcription.engine" = "Engine:";
"settings.transcription.language" = "Language:";
"settings.transcription.whisperURL" = "Whisper server:";
"settings.transcription.permission" = "Permission:";
"settings.transcription.permissionOK" = "✓ Speech recognition allowed.";
"settings.transcription.permissionAsk" = "macOS has not asked for speech recognition permission yet.";
"settings.transcription.permissionRequest" = "Request Permission";
"settings.transcription.permissionOpen" = "Open System Settings";
```

Usuń z obu plików nieużywany już klucz `settings.title` tylko jeśli `grep -rn '"settings.title"' daemon/AIHeadset/*.swift` nic nie zwraca.

- [ ] **Step 4: Build i podgląd paneli**

Run: `make test && ./build.sh`
Expected: wszystkie `PASS`, `Gotowe`.

Podgląd bez uruchamiania aplikacji: zbuduj program, który tworzy `SettingsWindowController(onSave: {}, onTranscriptionChange: {})`, woła `show(pane:)` dla obu paneli i zapisuje `contentView` do PNG przez `cacheDisplay` (wzór: `$CLAUDE_JOB_DIR/tmp/render/main.swift` z sesji 2026-10-08), kompilowany z `SettingsWindowController.swift AgentSettingsPane.swift TranscriptionSettingsPane.swift TranscriptionSettings.swift AppleSpeechTranscriber.swift WhisperTranscriber.swift ScribeTranscriber.swift SilenceSegmenter.swift SpeechTranscriber.swift TranscriptModel.swift AgentConfigClient.swift AgentSettings.swift KeychainStore.swift Strings.swift ConfigHealthCheck.swift Log.swift`, z katalogami `.lproj` obok pliku wykonywalnego i `AIHEADSET_TEST_KEYCHAIN_SUFFIX=render-test`. Sprawdź: etykiety wyrównane do prawej, przy Whisper widać pole adresu, przy Apple wiersz zgody.

- [ ] **Step 5: Commit**

```bash
git add daemon/AIHeadset/SettingsWindowController.swift daemon/AIHeadset/AgentSettingsPane.swift daemon/AIHeadset/TranscriptionSettingsPane.swift daemon/AIHeadset/MenuBarController.swift daemon/AIHeadset/Resources
git commit -m "Ustawienia z panelami: Agent głosowy i Transkrypcja"
```

---

### Task 9: Okno transkryptora i cykl życia transkrypcji

**Files:**
- Create: `daemon/AIHeadset/Glass.swift`
- Create: `daemon/AIHeadset/TranscriptWindowController.swift`
- Modify: `daemon/AIHeadset/MenuBarController.swift`
- Modify: `daemon/AIHeadset/Resources/{pl,en}.lproj/Localizable.strings`
- Modify: `tools/run_tests.sh`
- Test: `tools/autoscroll_test.swift`

**Interfaces:**
- Consumes: `TranscriptStore` (`paragraphs`, `text(of:)`, `hasPartial(in:)`, `onChange`), `TranscriptionSession`, `TranscriberFactory`, `TranscriptionSettings`, `AppleSpeechTranscriber.requestAuthorization`, `SettingsWindowController.show(pane:)`
- Produces:
  - `func makeGlass(around content: NSView, cornerRadius: CGFloat) -> NSView`
  - `enum TranscriptionStatus: Equatable { case running(TranscriberEngine), paused, unavailable(String) }`
  - `protocol TranscriptionControlling: AnyObject { var transcriptionStatus: TranscriptionStatus { get }; func setTranscriptionPaused(_ paused: Bool); func openTranscriptionSettings() }`
  - `enum AutoScrollPolicy { static func shouldFollow(visibleMaxY: CGFloat, documentHeight: CGFloat, tolerance: CGFloat = 24) -> Bool }`
  - `final class TranscriptWindowController: NSWindowController { init(store: TranscriptStore, controller: TranscriptionControlling); func show(); func statusDidChange() }`

- [ ] **Step 1: Napisz test polityki przewijania**

`tools/autoscroll_test.swift`:

```swift
// Auto-przewijanie: podążaj za nowym tekstem tylko, gdy użytkownik jest na dole.
import AppKit

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}

check(AutoScrollPolicy.shouldFollow(visibleMaxY: 1000, documentHeight: 1000), "dokładnie na dole")
check(AutoScrollPolicy.shouldFollow(visibleMaxY: 980, documentHeight: 1000), "20 pt od dołu")
check(!AutoScrollPolicy.shouldFollow(visibleMaxY: 600, documentHeight: 1000), "przewinięty w górę -> nie skacz")
check(AutoScrollPolicy.shouldFollow(visibleMaxY: 400, documentHeight: 300), "treść krótsza niż okno")

if failures > 0 { exit(1) }
print("PASS autoscroll_test")
```

Wpis: `"autoscroll_test: $A/TranscriptWindowController.swift $A/Glass.swift $A/TranscriptStore.swift $A/TranscriptModel.swift $A/TranscriptionSettings.swift $A/AppleSpeechTranscriber.swift $A/WhisperTranscriber.swift $A/ScribeTranscriber.swift $A/SilenceSegmenter.swift $A/SpeechTranscriber.swift $A/Strings.swift $A/Log.swift"`

- [ ] **Step 2: Uruchom i sprawdź, że nie przechodzi**

Run: `make test`
Expected: `BUILD FAIL  autoscroll_test`

- [ ] **Step 3: Szkło**

`daemon/AIHeadset/Glass.swift`:

```swift
import AppKit

/// Liquid Glass dla pływającej warstwy sterowania (pasek, karty,
/// pigułka) -- nigdy dla treści (HIG liquid-glass.md: „Don't use Liquid
/// Glass in the content layer”). macOS 26+: NSGlassEffectView; starsze:
/// NSVisualEffectView. „Ogranicz przezroczystość” obsługuje system.
func makeGlass(around content: NSView, cornerRadius: CGFloat) -> NSView {
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        return glass
    }
    let effect = NSVisualEffectView()
    effect.material = .headerView
    effect.blendingMode = .withinWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = cornerRadius
    effect.layer?.masksToBounds = true
    content.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        content.topAnchor.constraint(equalTo: effect.topAnchor),
        content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
    ])
    return effect
}
```

- [ ] **Step 4: Okno**

`daemon/AIHeadset/TranscriptWindowController.swift`:

```swift
import AppKit

enum TranscriptionStatus: Equatable {
    case running(TranscriberEngine)
    case paused
    case unavailable(String)
}

protocol TranscriptionControlling: AnyObject {
    var transcriptionStatus: TranscriptionStatus { get }
    func setTranscriptionPaused(_ paused: Bool)
    func openTranscriptionSettings()
}

enum AutoScrollPolicy {
    static func shouldFollow(visibleMaxY: CGFloat, documentHeight: CGFloat, tolerance: CGFloat = 24) -> Bool {
        documentHeight - visibleMaxY <= tolerance
    }
}

/// Okno transkryptora: akapity rozmowy w tabeli (treść, bez szkła) i
/// szklany pasek sterowania nad nią. Pływa nad komunikatorem, działa w
/// każdym trybie. Notatki agentów i przełączniki dochodzą w podprojekcie 3.
final class TranscriptWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: TranscriptStore
    private weak var controller: TranscriptionControlling?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusDot = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")
    private static let barHeight: CGFloat = 44
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init(store: TranscriptStore, controller: TranscriptionControlling) {
        self.store = store
        self.controller = controller
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = L("transcript.title")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 360, height: 300)
        panel.setFrameAutosaveName("TranscriptWindow")
        super.init(window: panel)
        buildUI()
        store.onChange = { [weak self] change in self?.apply(change) }
        statusDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nieużywane") }

    func show() {
        tableView.reloadData()
        updateEmptyState()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        scrollToBottom()
    }

    // MARK: - Budowa

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let column = NSTableColumn(identifier: .init("paragraph"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = true
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 10)
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(L("transcript.title"))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        // Treść przewija się POD szklanym paskiem.
        scrollView.contentInsets = NSEdgeInsets(top: Self.barHeight + 36, left: 0, bottom: 12, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        statusDot.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        pauseButton.bezelStyle = .accessoryBarAction
        pauseButton.isBordered = false
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        let settingsButton = NSButton(image: NSImage(systemSymbolName: "slider.horizontal.3",
                                                     accessibilityDescription: L("transcript.settings"))!,
                                      target: self, action: #selector(openSettings))
        settingsButton.isBordered = false
        settingsButton.toolTip = L("transcript.settings")

        let barContent = NSStackView(views: [statusDot, statusLabel, NSView(), pauseButton, settingsButton])
        barContent.orientation = .horizontal
        barContent.spacing = 8
        barContent.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = makeGlass(around: barContent, cornerRadius: Self.barHeight / 2)
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    // MARK: - Stan

    func statusDidChange() {
        let status = controller?.transcriptionStatus ?? .paused
        let (symbol, color, text, paused): (String, NSColor, String, Bool)
        switch status {
        case .running(let engine):
            (symbol, color, text, paused) = ("circle.fill", .systemGreen, L("transcript.status.running", engine.privacyNote), false)
        case .paused:
            (symbol, color, text, paused) = ("pause.circle.fill", .secondaryLabelColor, L("transcript.status.paused"), true)
        case .unavailable(let reason):
            (symbol, color, text, paused) = ("exclamationmark.triangle.fill", .systemOrange, reason, false)
        }
        statusDot.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusDot.contentTintColor = color
        statusLabel.stringValue = text
        statusLabel.toolTip = text
        let title = paused ? L("transcript.resume") : L("transcript.pause")
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: title)
        pauseButton.toolTip = title
        updateEmptyState()
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !store.paragraphs.isEmpty
        if case .paused = controller?.transcriptionStatus {
            emptyLabel.stringValue = L("transcript.empty.paused")
        } else {
            emptyLabel.stringValue = L("transcript.empty.listening")
        }
    }

    @objc private func togglePause() {
        let paused: Bool
        if case .paused = controller?.transcriptionStatus { paused = false } else { paused = true }
        controller?.setTranscriptionPaused(paused)
    }

    @objc private func openSettings() {
        controller?.openTranscriptionSettings()
    }

    // MARK: - Zmiany magazynu

    private func apply(_ change: TranscriptStore.Change) {
        guard window?.isVisible == true else { return } // odświeżamy przy show()
        let clip = scrollView.contentView
        let follow = AutoScrollPolicy.shouldFollow(visibleMaxY: clip.bounds.maxY,
                                                   documentHeight: tableView.frame.height)
        switch change {
        case .appended:
            tableView.insertRows(at: IndexSet(integer: store.paragraphs.count - 1), withAnimation: .effectFade)
        case .updated(let id):
            if let row = store.paragraphs.firstIndex(where: { $0.id == id }) {
                tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            }
        case .removed(let ids):
            tableView.removeRows(at: IndexSet(integersIn: 0..<ids.count), withAnimation: [])
        }
        updateEmptyState()
        if follow { scrollToBottom() }
    }

    private func scrollToBottom() {
        guard !store.paragraphs.isEmpty else { return }
        tableView.scrollRowToVisible(store.paragraphs.count - 1)
    }

    // MARK: - Tabela

    func numberOfRows(in tableView: NSTableView) -> Int { store.paragraphs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let paragraph = store.paragraphs[row]
        let cell = (tableView.makeView(withIdentifier: ParagraphCell.identifier, owner: nil) as? ParagraphCell) ?? ParagraphCell()
        let speaker = paragraph.speaker == .me ? L("speaker.me") : L("speaker.caller")
        cell.configure(header: "\(timeFormatter.string(from: paragraph.start)) · \(speaker)",
                       text: store.text(of: paragraph.id),
                       isPartial: store.hasPartial(in: paragraph.id),
                       isMe: paragraph.speaker == .me)
        return cell
    }
}

/// Akapit: godzina i mówca małą czcionką, tekst w rozmiarze systemowym.
/// Tekst jeszcze rozpoznawany (partial) w kolorze drugorzędnym.
private final class ParagraphCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ParagraphCell")
    private let header = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        header.textColor = .secondaryLabelColor
        body.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        body.isSelectable = true
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [header, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nieużywane") }

    func configure(header headerText: String, text: String, isPartial: Bool, isMe: Bool) {
        header.stringValue = headerText
        body.stringValue = text
        body.textColor = isPartial ? .secondaryLabelColor : .labelColor
        setAccessibilityLabel("\(headerText): \(text)")
    }
}
```

Teksty — `pl.lproj`:

```
"transcript.title" = "Transkryptor";
"transcript.settings" = "Ustawienia transkrypcji";
"transcript.status.running" = "Słucham · %@";
"transcript.status.paused" = "Transkrypcja wstrzymana";
"transcript.pause" = "Wstrzymaj transkrypcję";
"transcript.resume" = "Wznów transkrypcję";
"transcript.empty.listening" = "Czekam na rozmowę…";
"transcript.empty.paused" = "Transkrypcja wstrzymana";
"menu.transcript" = "Transkryptor…";
```

`en.lproj`:

```
"transcript.title" = "Transcriber";
"transcript.settings" = "Transcription Settings";
"transcript.status.running" = "Listening · %@";
"transcript.status.paused" = "Transcription paused";
"transcript.pause" = "Pause Transcription";
"transcript.resume" = "Resume Transcription";
"transcript.empty.listening" = "Waiting for the conversation…";
"transcript.empty.paused" = "Transcription paused";
"menu.transcript" = "Transcriber…";
```

- [ ] **Step 5: Okablowanie w `MenuBarController`**

Dodaj zgodność z protokołem: `final class MenuBarController: NSObject, NSMenuDelegate, TranscriptionControlling {`

Nowe właściwości (obok `agentPanel`):

```swift
    /// Transkrypt żyje tyle co aplikacja: przebudowa audio wymienia sesję,
    /// nie magazyn, więc okno nie traci rozmowy.
    private let transcriptStore = TranscriptStore()
    private var transcriptionSession: TranscriptionSession?
    private var transcriptJournal: Transcript?
    private var transcriptWindow: TranscriptWindowController?
    private(set) var transcriptionStatus: TranscriptionStatus = .paused {
        didSet { transcriptWindow?.statusDidChange() }
    }
```

W `rebuildMenu()`, bezpośrednio przed `let panelItem = ...` (po separatorze pod trybami):

```swift
        let transcriptItem = NSMenuItem(title: L("menu.transcript"), action: #selector(openTranscriptWindow), keyEquivalent: "t")
        transcriptItem.keyEquivalentModifierMask = [.command, .shift]
        transcriptItem.target = self
        menu.addItem(transcriptItem)
```

W `rebuildAudio(...)`: na początku, przed `router?.mode = .mute`, dodaj `stopTranscription()`; po `status = .active` dodaj `startTranscription()`.

W `shutdown()` przed `router?.stop()` dodaj `stopTranscription(); transcriptJournal?.close()`.

Zastąp pustą `restartTranscription()` z Task 8 i dodaj resztę:

```swift
    // MARK: - Transkrypcja

    private func startTranscription() {
        let settings = TranscriptionSettings()
        guard settings.isEnabled else {
            transcriptionStatus = .paused
            return
        }
        guard let router else { return }
        if settings.engine == .apple, SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            // Pytamy w kontekście: dopiero gdy transkrypcja Apple ma ruszyć.
            AppleSpeechTranscriber.requestAuthorization { [weak self] _ in self?.restartTranscription() }
            return
        }
        do {
            if transcriptJournal == nil { transcriptJournal = try? Transcript() }
            let session = try TranscriptionSession(router: router, store: transcriptStore, journal: transcriptJournal) { speaker in
                try TranscriberFactory.make(speaker, settings: settings, elevenLabsKey: AgentSettings.apiKey)
            }
            session.onError = { [weak self] _, error in
                self?.transcriptionStatus = .unavailable(String(describing: error))
            }
            try session.start()
            transcriptionSession = session
            transcriptionStatus = .running(settings.engine)
        } catch {
            Log.error("transkrypcja nie wystartowała: \(error)")
            transcriptionStatus = .unavailable(String(describing: error))
        }
    }

    private func stopTranscription() {
        transcriptionSession?.stop()
        transcriptionSession = nil
    }

    private func restartTranscription() {
        stopTranscription()
        startTranscription()
    }

    func setTranscriptionPaused(_ paused: Bool) {
        TranscriptionSettings().isEnabled = !paused
        restartTranscription()
    }

    func openTranscriptionSettings() {
        openSettings()
        settingsWindowController?.show(pane: .transcription)
    }

    @objc private func openTranscriptWindow() {
        if transcriptWindow == nil {
            transcriptWindow = TranscriptWindowController(store: transcriptStore, controller: self)
        }
        transcriptWindow?.show()
        NSApp.activate(ignoringOtherApps: true)
    }
```

Na górze `MenuBarController.swift` dodaj `import Speech`.

- [ ] **Step 6: Testy i build**

Run: `make test && plutil -lint daemon/AIHeadset/Resources/*.lproj/Localizable.strings && ./build.sh`
Expected: wszystkie `PASS`, `OK`, `Gotowe`

- [ ] **Step 7: Commit**

```bash
git add daemon/AIHeadset/Glass.swift daemon/AIHeadset/TranscriptWindowController.swift daemon/AIHeadset/MenuBarController.swift daemon/AIHeadset/Resources tools/autoscroll_test.swift tools/run_tests.sh
git commit -m "Okno transkryptora z paskiem Liquid Glass, transkrypcja w cyklu życia audio"
```

---

### Task 10: README i test ręczny na prawdziwej rozmowie

**Files:**
- Modify: `README.md`, `README.pl.md` (sekcja „What it does” / „Co robi” i „Setup” / „Konfiguracja”)

- [ ] **Step 1: Dopisz do README**

W `README.pl.md`, w liście „Co robi”, jako pierwszy punkt:

```markdown
- **Transkrypcja na żywo** — obie strony rozmowy osobno („Ja” / „Rozmówcy”), w każdym
  trybie. Okno **Transkryptor…** (`⌘⇧T`). Silnik do wyboru w Ustawieniach → Transkrypcja:
  Apple (na tym Macu), ElevenLabs Scribe (chmura) albo lokalny serwer Whisper
  (`whisper-server -m model.bin -l pl --port 8080` z whisper.cpp)
```

W `README.md` odpowiednio:

```markdown
- **Live transcription** — both sides of the call separately ("Me" / "Others"), in every
  mode. Open **Transcriber…** (`⌘⇧T`). Pick the engine in Settings → Transcription:
  Apple (on this Mac), ElevenLabs Scribe (cloud) or a local Whisper server
  (`whisper-server -m model.bin -l en --port 8080` from whisper.cpp)
```

- [ ] **Step 2: Pełny zestaw testów i build**

Run: `make test && ./build.sh`
Expected: wszystkie `PASS`, `Gotowe`

- [ ] **Step 3: Test ręczny (z użytkownikiem)**

`./run.sh install logs`, potem:

1. Menu → Transkryptor… (`⌘⇧T`) — okno nad Teamsem, pasek szklany, „Czekam na rozmowę…”.
2. Przy pierwszym starcie z silnikiem Apple macOS pyta o rozpoznawanie mowy → zgoda → pasek „Słucham · Dźwięk nie opuszcza tego Maca.”.
3. Rozmowa testowa w Teams: Twoje zdania jako „Ja”, rozmówcy jako „Rozmówcy”, tekst ≤ 3 s po wypowiedzi, partial szary → czarny.
4. Przełącz na AGENT (`⌘⇧A`) — transkrypcja trwa.
5. Menu → Słuchawki → inne urządzenie — transkrypt w oknie zostaje, transkrypcja wraca.
6. Pauza w pasku → „Transkrypcja wstrzymana”; wznowienie.
7. Ustawienia → Transkrypcja → Whisper bez uruchomionego serwera → ⚠ z opisem błędu w pasku; dźwięk rozmowy działa.
8. Wygląd jasny i ciemny; Ustawienia systemowe → Dostępność → Ogranicz przezroczystość — pasek czytelny.

- [ ] **Step 4: Commit**

```bash
git add README.md README.pl.md
git commit -m "README: transkrypcja na żywo"
```
