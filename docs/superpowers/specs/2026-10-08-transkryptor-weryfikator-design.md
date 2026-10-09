# AI Headset jako asystent rozmów — projekt

Data: 2026-10-09 (wersja 2, zastępuje wersję z 2026-10-08) · Status: do przeglądu

## Cel

AI Headset staje się uniwersalnym asystentem rozmów (Teams, Zoom, Meet,
Signal). Główne zadanie: **transkrypcja na żywo i jej analiza przez
agentów** — weryfikacja wiedzy (faktów oraz tego, co padło w poprzednich
rozmowach), podsumowania, kierunek rozmowy, tematy, mapa myśli. Mówienie
za użytkownika zostaje jako jedna z opcji.

Kryteria sukcesu:

1. Okno transkrypcji można otworzyć w każdym trybie (PASS/AGENT/MUTE), na
   rozmowie 1:1 i konferencji; tekst pojawia się z opóźnieniem ≤ 3 s.
2. Twierdzenie „akcje Intela dziś spadają” dostaje pod akapitem notatkę
   Weryfikatora: najpierw ⋯ (sprawdzam), potem ✓/✗ ze źródłem, rozwijaną
   kliknięciem.
3. Zdanie „na poprzednim callu mówiłeś X” dostaje notatkę agenta Pamięć
   z odnośnikiem do notatki z tamtej rozmowy.
4. Użytkownik dodaje w Ustawieniach model (np. OpenRouter), serwer MCP
   (np. Obsidian) i własnego agenta (np. Ekonomistę) bez zmian w kodzie.
5. Po zabiciu aplikacji przez system (OOM, awaria) aplikacja wraca sama
   i proponuje przywrócenie rozmowy sprzed ≤ 30 s.

## Diagnoza: dlaczego agent głosowy się gubi

- `AgentSession` startuje dopiero przy przełączeniu na AGENT — agent nie
  słyszał wcześniejszej części rozmowy.
- Dostaje wyłącznie zmiksowany dźwięk rozmówców; ElevenLabs traktuje miks
  jak jednego „usera”; mikrofonu użytkownika nie słyszy.
- Nic nie każe mu milczeć, gdy wypowiedź nie jest do użytkownika.

Naprawa korzysta z transkrypcji (podprojekt 8).

## Podprojekty i kolejność

Każdy podprojekt ma własny plan wdrożenia i jest samodzielnie testowalny.

| # | Podprojekt | Zależy od |
|---|---|---|
| 1 | Transkrypcja + okno transkryptora (bez agentów) | — |
| 2 | Profile modeli i serwery MCP (Ustawienia + klienci) | — |
| 3 | Silnik agentów + agenci wbudowani + notatki w oknie | 1, 2 |
| 4 | Pamięć rozmów: notatki Markdown/Obsidian + serwer MCP | 1, 3 |
| 5 | Karty: podsumowanie, kierunek, tematy, mapa myśli | 3 |
| 6 | Pająk (stan agentów) + tryb kompaktowy „pigułka” | 1, 3 |
| 7 | Odporność: limity pamięci, punkty przywracania, autorestart | 1, 3 |
| 8 | Agent głosowy z kontekstem rozmowy (1:1/konferencja) | 1 |

---

## 1. Transkrypcja i okno transkryptora

### Źródła dźwięku

`AudioRouter` dostaje dwa nowe bufory pierścieniowe, zasilane w każdym
trybie, niezależne od `uplinkBuffer` (jego jedynym konsumentem jest
`AgentSession`):

- `callerTranscriptTap` — Bridge.in (rozmówcy),
- `micTranscriptTap` — fizyczny mikrofon (`input[0]`), także w AGENT/MUTE.

Na wątku audio wyłącznie zapis do bufora.

Dwa strumienie = dwie instancje rozpoznawania → mówca `ja` / `rozmowcy`
jest pewny bez diaryzacji. Rozróżnianie osób w konferencji: poza v1.

### Silniki

```swift
protocol SpeechTranscriber: AnyObject {
    var onSegment: ((TranscriptSegment) -> Void)? { get set }  // partial i final
    var onError: ((Error) -> Void)? { get set }
    func start(language: String) throws
    func feed(pcm16Mono16k: Data)
    func stop()
}
```

| Silnik | Implementacja | Uwagi |
|---|---|---|
| Apple | `SFSpeechRecognizer`, `requiresOnDeviceRecognition = true` | zgoda Speech Recognition (`NSSpeechRecognitionUsageDescription`); zadanie restartowane co ~50 s |
| ElevenLabs Scribe | realtime przez WebSocket, klucz z `AgentSettings.apiKey` | kształt protokołu weryfikowany w dokumentacji przy implementacji |
| Whisper lokalny | HTTP do `whisper-server` (whisper.cpp), adres w Ustawieniach | fragmenty 3–5 s cięte na ciszy; tylko segmenty `final` |

`TranscriptionSession` co ~50 ms opróżnia oba bufory, resampluje
(`Resampler.deviceToAgent`) do PCM16 16 kHz i karmi transkryptory.
Startuje z routerem, działa niezależnie od trybu i od agenta głosowego.

### Model danych

```swift
struct TranscriptSegment { id: UUID; speaker: Speaker; text: String;
                           start: Date; end: Date; isFinal: Bool }
struct Paragraph { id: UUID; speaker: Speaker; segmentIDs: [UUID] }
```

`TranscriptStore` (główny wątek) trzyma segmenty i akapity. Nowy akapit,
gdy zmienia się mówca albo przerwa > 4 s. Segmenty `final` trafiają też do
istniejącego `Transcript` (JSONL). Pamięć ograniczona: w oknie żyje
ostatnie 90 minut, starsze tylko na dysku (podprojekt 7).

### Okno (natywny AppKit)

- `NSPanel` pływający, otwierany z menu „Transkryptor…” i skrótem ⌘⇧T, w
  każdym trybie.
- Treść: `NSTableView` oparty na widokach, jeden wiersz = akapit (godzina,
  mówca, tekst), zmienna wysokość. Segment `partial` szary, nadpisywany.
  Automatyczne przewijanie, dopóki użytkownik nie przewinie w górę.
- Na górze szklany pasek sterowania (tu w podprojekcie 1: wybór silnika
  i języka, start/pauza transkrypcji; przełączniki agentów dochodzą w 3).
- Treść transkryptu nigdy nie jest na szkle (HIG `liquid-glass.md`:
  „Don't use Liquid Glass in the content layer”).

### Liquid Glass

- macOS 26+: `NSGlassEffectView` dla paska, kart i pigułki.
- Starsze systemy (target 13): `NSVisualEffectView`.
- „Ogranicz przezroczystość” / „Zwiększ kontrast”: system sam usztywnia
  materiał; sprawdzane ręcznie w obu trybach.

---

## 2. Profile modeli i serwery MCP

### Profile modeli

```swift
struct ModelProfile: Codable { id: UUID; name: String
                               provider: Provider   // .anthropic | .openAICompatible
                               baseURL: URL; model: String }  // klucz w Keychain pod id
```

- `AnthropicMessagesClient` — `POST {baseURL}/v1/messages`.
- `OpenAICompatibleClient` — `POST {baseURL}/chat/completions`
  (`tools`/`tool_calls`). Obejmuje OpenRouter
  (`https://openrouter.ai/api/v1`), OpenAI, oMLX, Ollamę, LM Studio.
- Wspólny interfejs `LLMClient.complete(system:messages:tools:jsonOutput:)`
  zwraca tekst albo wywołania narzędzi.
- Gotowe szablony przy „+”: Anthropic, OpenRouter, OpenAI, oMLX, Ollama,
  Własny. Przycisk „Sprawdź” wysyła krótkie zapytanie i pokazuje czas
  odpowiedzi albo błąd.
- Odpowiedź Claude z `stop_reason == "refusal"` = błąd agenta (⚠ w notatce).

### Serwery MCP

- `StdioMCPClient`: `Process` z poleceniem, argumentami i env; JSON-RPC 2.0
  rozdzielany nową linią; `initialize` → `notifications/initialized` →
  `tools/list`; `tools/call` z limitem 15 s; stderr → log.
- `MCPRegistry`: lista z Ustawień; narzędzia z prefiksem
  `<serwer>__<narzędzie>`; padnięty serwer → niedostępny, ponowny start
  przy następnym użyciu.
- `PATH` rozszerzony o `/opt/homebrew/bin` i `/usr/local/bin` (aplikacja
  z Docka nie dziedziczy `PATH` powłoki).
- Szablony przy „+”: Brave Search, SearXNG, Fetch (czytnik URL), Obsidian,
  Pamięć rozmów, Własny. Dokładne pakiety i argumenty weryfikowane przy
  implementacji. Wartości sekretne z env (np. `BRAVE_API_KEY`) w Keychain.

### Ustawienia

Okno Ustawień przechodzi na panele w pasku narzędzi (HIG `settings.md`):
**Agent głosowy** (obecna zawartość okna), **Transkrypcja**, **Modele**,
**Narzędzia**, **Agenci**, **Notatki**.
Tytuł okna = nazwa panelu; otwiera się na ostatnio używanym. Panel
dochodzi razem z podprojektem, który go obsługuje.

---

## 3. Silnik agentów

### Definicja agenta

```swift
struct AgentDefinition: Codable {
    id: UUID; name: String; symbol: String        // SF Symbol
    modelProfileID: UUID
    instructions: String                           // edytowalne
    toolServerIDs: [UUID]                          // serwery MCP
    trigger: Trigger    // .everyFinalSegment | .interval(seconds) | .onDemand
    output: Output      // .anchoredNotes | .card
    maxToolCalls: Int   // domyślnie 5
    timeoutSeconds: Int // domyślnie 30
}
```

Zapisywane w `~/Library/Application Support/AIHeadset/agents.json`;
edycja w panelu **Agenci** (lista z „+”, „−”, „Duplikuj”).

### Agenci wbudowani (edytowalni, można przywrócić domyślne)

| Agent | Wyzwalacz | Wyjście | Narzędzia |
|---|---|---|---|
| Weryfikator prawdy | każdy segment final | notatki ✓/✗/? | wyszukiwarka, Fetch |
| Pamięć | każdy segment final | notatki ↺ | Pamięć rozmów, Obsidian |
| Podsumowanie | co 60 s | karta | — |
| Kierunek rozmowy | co 90 s | karta (tematy, kierunek, mapa myśli) | — |

Weryfikator i Pamięć dostają najpierw tani filtr: czy segment zawiera
twierdzenie do sprawdzenia / odwołanie do przeszłości. Jeśli nie — brak
wywołania narzędzi.

### Kontrakt wyjścia (JSON, w instrukcji systemowej silnika)

```json
{"notes": [{"anchor_quote": "dosłowny fragment", "status": "pending|true|false|unverifiable|info",
            "summary": "≤ 90 znaków", "detail": "dłuższe wyjaśnienie", "sources": ["url"]}],
 "card": {"title": "…", "sections": [{"heading": "…", "items": ["…"]}]}}
```

`anchor_quote` dopasowywany do tekstu segmentów (dokładnie, potem bez
wielkości liter i interpunkcji); niedopasowane notatki trafiają do
najnowszego akapitu z oznaczeniem „bez kotwicy”.

### Wykonanie

- Kolejka z limitem 3 równoległych wywołań na całość, 1 na agenta.
- Pętla narzędzi do `maxToolCalls`, całość do `timeoutSeconds`; przekroczenie
  → notatka `unverifiable` z powodem.
- Kontekst: ostatnie ~3 min transkryptu + segment wyzwalający.

### Notatki w oknie

- Pod akapitem: jedna linia na notatkę, czcionka `smallSystemFontSize`,
  kolor drugorzędny: `symbol werdyktu · agent · summary ›`.
- Kliknięcie lub Spacja rozwija: detail, źródła (klikalne), przyciski
  Kopiuj / Otwórz źródło.
- Zdanie z notatką: podkreślenie w kolorze werdyktu (pomarańczowy w trakcie,
  zielony, czerwony, szary). Znaczenie niesie symbol i tekst (✓ ✗ ⋯ ? ↺ ✎),
  nie sam kolor.
- Pasek sterowania: przełącznik dla każdego agenta + „+” (otwiera panel
  Agenci). Status, dokąd idzie tekst: „lokalnie” / nazwa dostawcy.

## 4. Pamięć rozmów (Markdown/Obsidian + MCP)

- Po zakończeniu rozmowy (przycisk „Zakończ rozmowę”, zmiana urządzenia,
  wyjście, 10 min ciszy) zapis notatki Markdown: frontmatter (data, typ,
  uczestnicy, tagi), karty agentów, zweryfikowane twierdzenia, transkrypt.
- Folder w panelu **Notatki**; domyślnie
  `~/Library/Application Support/AIHeadset/notes/`. Skarbiec Obsidiana
  tylko po jawnym wskazaniu.
- Serwer `aiheadset-memory-mcp` (osobny plik wykonywalny Swift w
  `Contents/MacOS/`): `search_notes(query, limit)`, `read_note(path)`,
  `list_recent_calls(limit)`; foldery z `--root` (powtarzalne); odczyt
  tylko w ich obrębie. Wyszukiwanie słów kluczowych (tytuł ×3).
- Przycisk „Kopiuj konfigurację dla Claude Desktop/Code”.

## 5. Karty agentów

- Boczna kolumna (szkło) z kartami agentów o wyjściu `.card`: tytuł,
  sekcje z punktami, rozwijane.
- Mapa myśli w v1 jako drzewo wcięć (temat → podtematy → wątki).
  Graficzne schematy: poza v1, ale format karty ich nie blokuje.

## 6. Pająk i tryb kompaktowy

- Pająk (Core Animation, warstwy wektorowe, ≤ 32 pt) w pasku i w pigułce.
  Stany: śpi (brak transkrypcji), nasłuchuje (transkrypcja), biegnie
  (agenci pracują / narzędzia), mówi (tryb AGENT i agent mówi), błąd.
- „Ogranicz ruch” → statyczna ikona stanu. Stan ma też etykietę tekstową
  dla VoiceOver.
- Pigułka: małe szklane `NSPanel` nad wszystkimi oknami — pająk + ostatnia
  notatka ✗/↺; kliknięcie otwiera pełne okno. Przełączanie ⌘⇧T: pełne ↔
  pigułka.

## 7. Odporność

- **Zapobieganie:** limit równoległych wywołań (3); transkrypt w pamięci
  ≤ 90 min; odpowiedzi modeli obcinane do 16 kB; `MemoryGuard` co 10 s
  czyta `phys_footprint` (`task_info`). Powyżej 1,5 GB: wstrzymanie agentów
  + komunikat w pasku; powyżej 2,5 GB: zwolnienie historii okna starszej
  niż 15 min (zostaje na dysku).
- **Punkt przywracania:** co 30 s zapis `checkpoint.json` (sesja, akapity,
  notatki, karty, włączeni agenci, silnik) atomowo (zapis do pliku
  tymczasowego + rename). Znacznik czystego zamknięcia przy „Zakończ”.
- **Powrót:** LaunchAgent `KeepAlive = {SuccessfulExit: false}` — restart
  tylko po awarii/zabiciu, nie po „Zakończ”. Przy starcie: punkt
  przywracania < 10 min i brak znacznika czystego zamknięcia → okno
  transkryptora z pytaniem „Przywrócić rozmowę z HH:MM?”.

## 8. Agent głosowy z kontekstem rozmowy

- W oknie podpowiedzi: typ rozmowy (1:1 / Konferencja), moje imię,
  uczestnicy (zapamiętywane).
- Po połączeniu `contextual_update`: typ, uczestnicy, reguła zachowania,
  ostatnie 5 min transkryptu (≤ 4000 znaków od końca).
- Konferencja: odpowiadaj tylko, gdy ktoś zwraca się do `<imię>` albo pyta
  go wprost; inaczej `skip_turn`. Zmiana typu/uczestników → kolejny
  `contextual_update`.
- `ConfigHealthCheck` ostrzega, gdy `skip_turn` nie jest włączone.

## Błędy

- Awaria transkryptora, modelu lub MCP → komunikat w pasku okna i ⚠ w
  notatce; dźwięk i tryb agenta nienaruszone.
- Brak zgody na rozpoznawanie mowy → komunikat z odnośnikiem do Ustawień
  systemowych.
- Agent bez działającego profilu modelu → przełącznik nieaktywny z
  podpowiedzią.

## Prywatność

- Pasek okna pokazuje, czy tekst opuszcza Maca i do kogo (per agent).
- Klucze wyłącznie w Keychain (konto per profil/serwer, sufiks testowy jak
  w `AgentSettings`).
- `ConsentAnnouncer` pozostaje mechanizmem informowania rozmówców.

## Testy

Narzędzia w `tools/` w stylu istniejących, bez sieci i bez urządzeń audio;
nowy cel `make test` buduje i uruchamia wszystkie:

- `transcript_store_test` — partial/final, akapity (mówca, przerwa 4 s),
  limit 90 min.
- `llm_client_test` — kodowanie/dekodowanie obu dostawców na zapisanych
  przykładach (tekst, wywołania narzędzi, refusal).
- `mcp_client_test` — atrapa serwera stdio: handshake, wywołanie, limit
  czasu, padnięcie.
- `agent_engine_test` — wyzwalacze, limit równoległości, timeout, parsowanie
  kontraktu, kotwiczenie `anchor_quote`.
- `memory_mcp_test` — wyszukiwanie, odczyt, odmowa poza folderami.
- `checkpoint_test` — zapis atomowy, odczyt, decyzja o przywróceniu.
- `agent_context_test` — `contextual_update` dla 1:1 i konferencji.

Ręcznie: prawdziwa rozmowa 1:1 i konferencja, każdy silnik, oba wyglądy,
„Ogranicz przezroczystość/ruch”, `kill -9` w trakcie rozmowy.

## Poza zakresem v1

- Rozróżnianie uczestników konferencji po głosie.
- Graficzne schematy i obrazy w kartach.
- Wyszukiwanie semantyczne w pamięci.
- Serwery MCP przez HTTP.
- Automatyczna zmiana konfiguracji agenta ElevenLabs.
