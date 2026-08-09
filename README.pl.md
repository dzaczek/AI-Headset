<div align="center">

# 🎧 AI Headset

**Wirtualny zestaw słuchawkowy dla macOS, który potrafi mówić za Ciebie.**

Dla Zooma, Teamsa i Signala wygląda jak zwykły headset USB.
W środku przepuszcza dźwięk przez własny demon, który na Twoje żądanie
podstawia agenta konwersacyjnego ElevenLabs zamiast Twojego mikrofonu.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Universal](https://img.shields.io/badge/binary-arm64%20%2B%20x86__64-blue)](#)
[![Swift + C11](https://img.shields.io/badge/kod-Swift%20%2B%20C11-orange?logo=swift&logoColor=white)](#)
[![Notarized](https://img.shields.io/badge/Apple-notaryzowany-success)](#)
[![Version](https://img.shields.io/badge/wersja-0.5.0-informational)](VERSION)

**Polski** · [English](README.md)

</div>

---

```
      Zoom · Teams · Signal · Meet
                  ↕
         ┌──────────────────┐
         │   AI Headset     │   ← widoczne dla aplikacji, transport USB
         └──────────────────┘
                  ↕              dwa ring buffery, na krzyż
         ┌──────────────────┐
         │ AI Headset Bridge│   ← ukryte, tylko dla demona
         └──────────────────┘
                  ↕
         ┌──────────────────┐
         │  AIHeadset.app   │   ← aggregate device + routing
         └──────────────────┘
             ↙          ↘
   Twoje słuchawki      Agent ElevenLabs
                        (WebSocket, PCM 16 kHz)
```

Dwa urządzenia zamiast jednego, bo aplikacja i demon nie mogą czytać z tego
samego strumienia wejściowego — demon musi wejść w środek.

## Trzy tryby, jeden skrót

| | Rozmówca słyszy | Agent słyszy | Ty słyszysz |
|---|---|---|---|
| 🌊 **PASS** | ciebie | rozmówcę | rozmówcę |
| 🧠 **AGENT** | **agenta** | rozmówcę | rozmówcę **+ agenta** |
| 🔇 **MUTE** | ciszę | rozmówcę | rozmówcę |

`⌘⇧A` przełącza PASS ↔ AGENT — celowo bez blokowania na czymkolwiek, więc
działa nawet gdy WebSocket wisi. Ikona w pasku menu ma **inny glif dla każdego
trybu** i świeci na fioletowo, gdy agent właśnie mówi Twoim kanałem.

## Co potrafi

- **Podpowiedzi na żywo** — małe pływające okno nad Teamsem; wpisujesz „klient
  pyta o cenę, nie obiecuj", agent uwzględnia to od następnej wypowiedzi, bez
  przerywania bieżącej
- **Charakter agenta pod ręką** — rola i osobowość edytowane w aplikacji,
  zapisywane wprost na koncie ElevenLabs
- **Mierniki ruchu** — cztery poziomy (do agenta, od agenta, do słuchawek,
  mikrofon), żeby ciszę dało się zdiagnozować patrzeniem, a nie zgadywaniem
- **Kontrola konfiguracji** — aplikacja czyta ustawienia agenta i ostrzega, gdy
  kłócą się z jej wymaganiami (format audio, długość rozmowy, powitanie)
- **Zabezpieczenia w tle** — dead man's switch przy zerwanym połączeniu,
  watchdog zegara, filtr blokujący obietnice o cenach i terminach
- **Dwa języki** — polski i angielski, wybierane po ustawieniach systemu

---

## Instalacja

### Z gotowej paczki

```bash
unzip AIHeadset-0.5.0-*.zip
cd dist && ./install.sh
```

Sterownik ląduje w `/Library/Audio/Plug-Ins/HAL/`, aplikacja w `/Applications/`,
`coreaudiod` się restartuje (sekunda ciszy w systemie — to normalne).

> [!IMPORTANT]
> Uruchamiaj z `/Applications`, nie z rozpakowanego folderu. macOS stosuje
> wtedy App Translocation i uprawnienia nie mają się gdzie zapisać.

Po instalacji: zgódź się na **mikrofon**, nadaj **Accessibility** dla skrótu
klawiszowego, wpisz **API Key** (zostaje w Keychainie tej maszyny, nie wędruje
z paczką).

### Ze źródeł

```bash
cp packaging/.env.example packaging/.env   # Apple ID, Team ID, certyfikat
make driver && make install                # sterownik HAL (wymaga sudo)
make run                                   # aplikacja, ~2 s
```

> [!NOTE]
> **Sterownik wymaga notaryzacji nawet do testów lokalnych.** `coreaudiod`
> ładuje pluginy HAL przez piaskownicowy proces XPC, który egzekwuje to przez
> AMFI. Aplikacja lokalnie notaryzacji nie potrzebuje.

```bash
./packaging/make_dist.sh    # build + podpis + notaryzacja + zip, jedna komenda
```

---

## Konfiguracja

Ikona w pasku menu → **Agent…** (`⌘⇧A`) i **Ustawienia…** (`⌘,`)

| Gdzie | Co ustawiasz |
|---|---|
| Ustawienia Dźwięku macOS | **Twoje słuchawki** — nie AI Headset |
| Teams / Zoom → mikrofon i głośnik | **AI Headset** |
| Menu → Wyjście monitorujące | słuchawki, na których słyszysz rozmowę |
| Menu → Wejście mikrofonu | Twój fizyczny mikrofon |

> [!WARNING]
> Nie ustawiaj `AI Headset` jako domyślnego urządzenia systemu. Wszystkie
> dźwięki — powiadomienia, muzyka — trafiłyby wtedy do agenta jako głos
> rozmówcy.

### Po stronie ElevenLabs

Aplikacja jest mostem audio; kim agent jest, jakiego używa modelu i co wie —
konfiguruje się na [elevenlabs.io](https://elevenlabs.io) → Conversational AI.

**Bez tego nie będzie dźwięku:**

| Ustawienie | Wartość |
|---|---|
| Input audio format | `PCM 16000 Hz` |
| Output audio format | `PCM 16000 Hz` |

Warto też podnieść `max_duration_seconds` (domyślne 20 minut urwie rozmowę),
wyczyścić `first_message` (agent wchodzi w **trwającą** rozmowę, powitanie
zabrzmi w środku zdania) i trzymać `reasoning_effort` nisko — model rozumujący
potrafi odpowiadać 7 sekund, co w rozmowie głosowej jest nie do przyjęcia.

---

## Diagnostyka

```bash
make logs                                                   # na żywo
log show --last 10m --predicate 'subsystem == "cat.sysop.aiheadset"'
```

Menu → **Test dźwięku w słuchawkach** wysyła ton prosto na wyjście, z pominięciem
Teamsa i sterownika — rozcina problem na pół bez zgadywania.

---

## Stan projektu

Sterownik, routing i tryby działają i są przetestowane na żywym sprzęcie.
Poniżej to, czego **nie ma** — świadomie i jawnie:

| Element | Stan |
|---|---|
| `Transcript` | napisany, nieuruchamiany — rozmowy nie są zapisywane |
| `ConsentAnnouncer` | napisany, nieuruchamiany — komunikat o nagrywaniu nie odtwarza się sam |
| `CommitmentFilter` | wzorce **tylko po polsku**; w innym języku zostaje sama warstwa promptu |
| Pola protokołu ElevenLabs | `user_transcript`, `agent_response`, `vad_score`, `ping` — **niezweryfikowane** wobec dokumentacji (oznaczone w kodzie) |
| Instalator `.pkg` | wymaga certyfikatu *Developer ID Installer*; działa `make_dist.sh` (zip) |
| Test godzinnej rozmowy | **nieprzeprowadzony** — plan nazywa go bramką jakościową |

> [!CAUTION]
> **Nagrywanie i zgoda.** Aplikacja pozwala podstawić syntetyczny głos na
> rozmowie z drugą osobą, a ElevenLabs przetwarza dźwięk po swojej stronie.
> Poinformowanie rozmówcy jest po Twojej stronie — projekt tego **nie
> egzekwuje**, bo `ConsentAnnouncer` nie jest podpięty. W wielu jurysdykcjach
> nagrywanie bez wiedzy drugiej strony jest niezgodne z prawem.

---

## Struktura

```
driver/      sterownik HAL (C11) — dwa urządzenia, ring buffery lock-free
daemon/      aplikacja (Swift/AppKit) — aggregate device, routing, agent
tools/       jednorazowe narzędzia diagnostyczne (nie część produktu)
packaging/   podpisywanie, notaryzacja, dystrybucja
VERSION      jedyne miejsce z numerem wersji
```

| Skrypt | Do czego |
|---|---|
| `make run` | build + podpis + uruchomienie, ~2 s |
| `make logs` | logi aplikacji na żywo |
| `packaging/make_dist.sh` | pełna paczka do przeniesienia (build → notaryzacja → zip) |
| `packaging/make_pkg.sh` | instalator `.pkg` (wymaga certyfikatu Installer) |

Wydanie: zmień `VERSION`, uruchom `packaging/make_dist.sh`.

> [!TIP]
> Narzędzia w `tools/` dotykające Keychaina wymagają zmiennej
> `AIHEADSET_TEST_KEYCHAIN_SUFFIX` i bez niej odmawiają startu. Zapis do
> produkcyjnego wpisu z innej binarki przepina uprawnienia i po cichu odcina
> aplikację od jej własnego klucza API — zdarzyło się naprawdę.

---

<div align="center">

Projekt techniczny: [`ai-headset-macos-plan.md`](ai-headset-macos-plan.md)

</div>
