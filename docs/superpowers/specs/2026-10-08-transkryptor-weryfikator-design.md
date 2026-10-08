# Transkryptor, weryfikator faktów i kontekst rozmowy — projekt

Data: 2026-10-08 · Status: do przeglądu

## Cel

1. Agent mówiący za użytkownika ma rozumieć, w jakiej rozmowie jest (1:1 czy
   konferencja), kto w niej uczestniczy i co padło przed jego włączeniem — i na
   konferencji nie odpowiadać na wypowiedzi niekierowane do użytkownika.
2. Transkrypcja na żywo w każdym trybie (PASS/AGENT/MUTE), w oknie, które
   oznacza twierdzenia kolorem w trakcie weryfikacji (🟠), po weryfikacji
   (🟢 prawda / 🔴 fałsz / ⚪ nie do ustalenia) z adnotacją i źródłem, oraz
   streszcza rozmowę pod kategoriami wybranymi przed rozmową.
3. Każda rozmowa trafia do lokalnej pamięci (notatki Markdown, zgodne z
   Obsidianem), udostępnionej przez lokalny serwer MCP — weryfikator i inne
   narzędzia (Claude Desktop/Code) mogą sięgać do wiedzy z poprzednich rozmów
   i dodatkowych notatek użytkownika.

## Diagnoza obecnego problemu (punkt 1)

- `AgentSession` startuje dopiero przy przełączeniu na AGENT
  (`MenuBarController.applyMode`) — agent nie słyszał wcześniejszej części
  rozmowy.
- Agent dostaje wyłącznie zmiksowany dźwięk z Bridge.in; mikrofonu użytkownika
  nie słyszy. ElevenLabs traktuje miks wszystkich rozmówców jak jednego
  „usera”.
- Nic nie każe agentowi milczeć, gdy wypowiedź nie jest do użytkownika.
- `Transcript.swift` istnieje, ale nie jest podłączony.

## Kolejność wdrożenia

A (transkrypcja) → B1 (kontekst agenta) → B2 (okno transkryptora) → C (pamięć
MCP). Każdy etap jest samodzielnie użyteczny i testowalny.

---

## A. Transkrypcja na żywo

**Źródła dźwięku.** `AudioRouter` dostaje dwa nowe bufory pierścieniowe,
zasilane w każdym trybie, niezależne od `uplinkBuffer` (który ma jednego
konsumenta — `AgentSession`):

- `callerTranscriptTap` — Bridge.in (rozmówcy),
- `micTranscriptTap` — fizyczny mikrofon (`input[0]`), również w AGENT/MUTE.

Na wątku audio wyłącznie zapis do bufora — bez alokacji i blokad.

**Mówcy.** Dwa strumienie = dwie instancje rozpoznawania → etykiety `ja` /
`rozmowcy` są pewne bez diaryzacji. Rozróżnianie osób w konferencji jest poza
zakresem v1.

**Interfejs.**

```swift
protocol SpeechTranscriber: AnyObject {
    var onSegment: ((TranscriptSegment) -> Void)? { get set }  // partial i final
    var onError: ((Error) -> Void)? { get set }
    func start(language: String) throws
    func feed(pcm16Mono16k: Data)
    func stop()
}
struct TranscriptSegment { id; speaker; text; isFinal; start; end }
```

**Silniki** (wybór w Ustawieniach + język PL/EN):

| Silnik | Implementacja | Uwagi |
|---|---|---|
| Apple | `SFSpeechRecognizer`, `requiresOnDeviceRecognition = true` | wymaga zgody Speech Recognition (Info.plist `NSSpeechRecognitionUsageDescription`); zadania rozpoznawania restartowane co ~50 s (limit długości) |
| ElevenLabs Scribe | realtime przez WebSocket, klucz z `AgentSettings.apiKey` | kształt protokołu weryfikowany w aktualnej dokumentacji przy implementacji — jak w `ElevenLabsClient`, pola niezweryfikowane oznaczone komentarzem |
| Whisper lokalny | HTTP do `whisper-server` (whisper.cpp) na localhost, adres w Ustawieniach | fragmenty 3–5 s cięte na ciszy (prosty próg RMS); tylko segmenty `final` |

**Pompa.** `TranscriptionSession` (osobna od `AgentSession`) co ~50 ms
opróżnia oba bufory, resampluje istniejącym `Resampler.deviceToAgent` do PCM16
16 kHz i podaje do odpowiedniego transkryptora. Startuje razem z routerem i
działa niezależnie od trybu i od połączenia z agentem (wyłączana w Ustawieniach).

**Zapis.** Segmenty `final` → `Transcript.append` (dochodzi mówca `ja` /
`rozmowcy`; odpowiedzi agenta z `agent_response` jako `agent`). Dodatkowo
`TranscriptStore` w pamięci (ostatnie N minut) — źródło dla B1 i B2.

## B1. Kontekst agenta

- Okno podpowiedzi (`HintWindowController`) dostaje sekcję **Rozmowa**: typ
  (1:1 / Konferencja), „Moje imię”, „Uczestnicy” (lista po przecinku).
  Zapamiętywane w `UserDefaults` do zmiany.
- Po połączeniu `AgentSession` (stan `connected`) wysyła jeden
  `contextual_update` zawierający: typ rozmowy, imię użytkownika, uczestników,
  regułę zachowania oraz ostatnie 5 minut transkryptu z `TranscriptStore`
  (z etykietami mówców; obcięte do ~4000 znaków od końca).
- Reguła dla konferencji (w aktualizacji kontekstu, nie w systemowym prompcie,
  żeby nie nadpisywać persony): odpowiadaj tylko, gdy ktoś zwraca się do
  `<imię>` lub zadaje mu pytanie wprost; w innym wypadku użyj `skip_turn`.
  Dla 1:1: odpowiadaj normalnie.
- Zmiana typu/uczestników w trakcie połączenia → kolejny `contextual_update`.
- `ConfigHealthCheck` dostaje sprawdzenie, czy narzędzie systemowe `skip_turn`
  jest włączone w agencie (ścieżka pola do weryfikacji w dokumentacji); jeśli
  nie — ostrzeżenie z instrukcją włączenia w panelu ElevenLabs. Aplikacja nie
  zmienia tego ustawienia sama.

## B2. Okno transkryptora

**Dostęp.** Menu → „Transkryptor…” oraz skrót ⌘⇧T. `NSPanel` pływający, jak
okno podpowiedzi. Działa w każdym trybie.

**Układ.**

```
┌ Transkryptor ─────────────────────────── [✓ Weryfikator] [✓ Analizator] ┐
│ 12:03:41 rozmowcy ▸ Słyszeliście, że akcje Intela dziś spadają?      │ Decyzje
│          ↳ ✗ Kurs INTC dziś +2,8% (źródło: …)    ← tło czerwone      │  • …
│ 12:03:49 ja       ▸ Nie widziałem jeszcze.                           │ Zadania
│ 12:04:02 rozmowcy ▸ Budżet na Q4 to 120 tys.     ← tło pomarańczowe  │  • …
│                                                                      │ Ryzyka
│ status: Apple (lokalnie) · weryfikacja: chmura (Anthropic) · MCP 2/2 │  • …
└──────────────────────────────────────────────────────────────────────┘
```

- Lewa część: `NSTextView` (ciemne tło, czcionka monospace), segmenty
  `partial` szare i nadpisywane, `final` utrwalone. Twierdzenie podświetlane
  w zakresie tekstu, którego dotyczy; adnotacja jako wcięta linia pod spodem.
- Prawa część: kategorie. Lista kategorii edytowana przed rozmową (domyślnie:
  Decyzje, Zadania, Ryzyka, Liczby i fakty, Pytania otwarte), zapamiętywana.
- Pasek statusu: silnik transkrypcji, gdzie idzie tekst (lokalnie / chmura +
  dostawca), liczba działających serwerów MCP, ostatni błąd.

**Ekstraktor twierdzeń.** Każdy segment `final` (z mówcy `rozmowcy` lub `ja`)
→ model „szybki” ze strukturalnym JSON:
`{"claims":[{"text": "<dosłowny fragment>", "checkable": true}]}`. Fragment
dopasowywany do tekstu segmentu (dokładnie, potem bez wielkości liter);
niedopasowane odrzucane. Twierdzenie → 🟠.

**Weryfikator.** Kolejka z limitem 2 równoległych. Model „weryfikator” dostaje
twierdzenie, kontekst (ostatnie ~10 segmentów), datę i narzędzia wszystkich
włączonych serwerów MCP. Pętla narzędzi: maks. 5 wywołań, łącznie 30 s.
Wynik JSON: `{"verdict": "true|false|unverifiable", "note": "...",
"sources": ["url"]}` → 🟢 / 🔴 / ⚪ + adnotacja. Przekroczenie limitu czasu
lub błąd → ⚪ z powodem.

**Analizator.** Co 30 s, jeśli przybyły nowe segmenty: model „szybki” dostaje
kategorie, aktualne streszczenie i nowe segmenty; zwraca JSON
`{"<kategoria>": ["punkt", ...]}` — pełne nowe streszczenie, które zastępuje
poprzednie.

## Modele (dostawcy LLM)

```swift
protocol LLMClient {
    func complete(system: String, messages: [LLMMessage], tools: [LLMTool],
                  jsonOutput: Bool) async throws -> LLMResponse  // tekst lub wywołania narzędzi
}
```

- `AnthropicMessagesClient` — `POST {baseURL}/v1/messages`, nagłówki
  `x-api-key`, `anthropic-version`. Bazowy URL konfigurowalny (Claude API lub
  oMLX w trybie zgodnym z Anthropic).
- `OpenAICompatibleClient` — `POST {baseURL}/v1/chat/completions`, narzędzia
  w formacie `tools`/`tool_calls`. Obsługuje OpenAI, oMLX, Ollamę, LM Studio.
- Ustawienia mają dwa sloty: **szybki** (ekstraktor, analizator) i
  **weryfikator**. Każdy: dostawca, bazowy URL, nazwa modelu, klucz (Keychain,
  konto zależne od slotu; pusty klucz dozwolony dla lokalnych serwerów).
  Proponowane wartości domyślne: szybki `claude-haiku-5-5`, weryfikator
  `claude-sonnet-5-5`.
- Przy modelach Claude: `stop_reason == "refusal"` traktowany jak błąd →
  ⚪ z powodem.

## Klient MCP

- `StdioMCPClient`: uruchamia `Process` z poleceniem, argumentami i
  zmiennymi środowiskowymi; JSON-RPC 2.0 rozdzielany znakami nowej linii;
  `initialize` → `notifications/initialized` → `tools/list`; `tools/call`
  z limitem czasu 15 s. Stderr serwera → log aplikacji.
- `MCPRegistry`: lista serwerów z Ustawień (nazwa, polecenie, argumenty, env,
  włączony). Narzędzia przekazywane modelowi z prefiksem `<serwer>__<narzędzie>`.
  Serwer, który padł → oznaczony jako niedostępny, ponowne uruchomienie przy
  następnym użyciu.
- Gotowe wpisy (presety) na start: **Brave Search** (wymaga klucza Brave),
  **SearXNG** (wymaga adresu instancji), **Pamięć rozmów** (sekcja C).
  Dokładne nazwy pakietów i argumentów weryfikowane przy implementacji.
- Polecenia uruchamiane przez `/usr/bin/env` z `PATH` rozszerzonym o
  `/opt/homebrew/bin` i `/usr/local/bin` (aplikacja z Docka nie dziedziczy
  `PATH` z powłoki).

## C. Pamięć rozmów (Markdown/Obsidian + serwer MCP)

**Notatka po rozmowie.** Po zakończeniu sesji transkrypcji (zmiana urządzenia,
wyjście, ręczne „Zakończ rozmowę” w oknie transkryptora) zapisywana jest
notatka Markdown:

```markdown
---
date: 2026-10-08T14:02
type: konferencja
participants: [Anna, Piotr]
tags: [rozmowa, aiheadset]
---
# Rozmowa 2026-10-08 14:02
## Decyzje
- …
## Twierdzenia zweryfikowane
- 🔴 „akcje Intela dziś spadają” — Kurs INTC +2,8% (źródło)
## Transkrypt
**12:03:41 rozmowcy:** …
```

- Folder docelowy w Ustawieniach. Domyślnie
  `~/Library/Application Support/AIHeadset/notes/`. Można wskazać folder
  wewnątrz skarbca Obsidiana (np. `<vault>/Rozmowy/`) — notatki są wtedy
  przeglądane, linkowane i przeszukiwane w Obsidianie bez żadnej wtyczki.
  Aplikacja nie zapisuje do skarbca, dopóki użytkownik go nie wskaże.
- Plik JSONL z `Transcript` zostaje bez zmian jako surowy zapis.

**Serwer `aiheadset-memory-mcp`.** Osobny mały plik wykonywalny w Swifcie
(`Contents/MacOS/aiheadset-memory-mcp`), serwer MCP przez stdio:

- `search_notes(query, limit=5)` — wyszukiwanie słów kluczowych (liczba
  trafień, tytuł ×3) po wszystkich `.md` w skonfigurowanych folderach
  (folder notatek rozmów + opcjonalnie cały skarbiec = „dodatkowe sprawy”);
  zwraca ścieżkę, tytuł, datę, fragment wokół trafienia.
- `read_note(path)` — pełna treść notatki (tylko w obrębie skonfigurowanych
  folderów).
- `list_recent_calls(limit=10)` — ostatnie notatki rozmów.
- Foldery przekazywane argumentami (`--root <ścieżka>`, powtarzalne), więc ten
  sam serwer można dodać w Claude Desktop/Code.

## Błędy

- Awaria transkryptora, modelu lub MCP → komunikat w pasku statusu okna;
  dźwięk i tryb agenta nienaruszone.
- Brak zgody na rozpoznawanie mowy (Apple) → komunikat z linkiem do Ustawień
  systemowych.
- Brak skonfigurowanego modelu → przełączniki Weryfikator/Analizator nieaktywne
  z podpowiedzią.

## Prywatność

- Pasek statusu zawsze pokazuje, czy tekst opuszcza Maca i do kogo.
- Klucze wyłącznie w Keychain (osobne konta na slot, z sufiksem testowym jak
  w `AgentSettings`).
- Istniejący `ConsentAnnouncer` pozostaje mechanizmem informowania rozmówców
  o nagrywaniu.

## Testy

Narzędzia w `tools/` w stylu istniejących `*_test.swift`, bez sieci:

- `transcription_test` — składanie segmentów partial/final, etykiety mówców,
  okno ostatnich N minut w `TranscriptStore`.
- `claims_test` — parsowanie JSON ekstraktora i weryfikatora, dopasowanie
  fragmentu do tekstu, odrzucanie niedopasowanych.
- `llm_client_test` — kodowanie żądań i dekodowanie odpowiedzi (tekst,
  wywołania narzędzi) dla obu dostawców na zapisanych przykładach.
- `mcp_client_test` — klient wobec atrapy serwera stdio (skrypt), w tym limit
  czasu i padnięcie serwera.
- `memory_mcp_test` — wyszukiwanie i odczyt notatek na folderze testowym,
  odmowa odczytu poza skonfigurowanymi folderami.
- `agent_context_test` — treść `contextual_update` dla 1:1 i konferencji,
  obcięcie transkryptu.

Ręcznie: prawdziwa rozmowa 1:1 i konferencja, każdy z trzech silników.

## Poza zakresem v1

- Rozróżnianie poszczególnych uczestników konferencji po głosie.
- Wyszukiwanie semantyczne (embeddingi) w pamięci.
- Serwery MCP przez HTTP (tylko stdio).
- Automatyczna zmiana konfiguracji agenta ElevenLabs (`skip_turn`).
