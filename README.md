<div align="center">

# 🎧 AI Headset

**A virtual headset for macOS that can talk for you.**

To Zoom, Teams and Signal it looks like an ordinary USB headset.
Inside, audio flows through a daemon that — on your command — puts an
ElevenLabs conversational agent on the line in place of your microphone.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Universal](https://img.shields.io/badge/binary-arm64%20%2B%20x86__64-blue)](#)
[![Swift + C11](https://img.shields.io/badge/code-Swift%20%2B%20C11-orange?logo=swift&logoColor=white)](#)
[![Notarized](https://img.shields.io/badge/Apple-notarized-success)](#)
[![Version](https://img.shields.io/badge/version-0.5.3-informational)](VERSION)

**English** · [Polski](README.pl.md)

</div>

---

```
      Zoom · Teams · Signal · Meet
                  ↕
         ┌──────────────────┐
         │   AI Headset     │   ← what apps see, USB transport type
         └──────────────────┘
                  ↕              two ring buffers, cross-wired
         ┌──────────────────┐
         │ AI Headset Bridge│   ← hidden, for the daemon only
         └──────────────────┘
                  ↕
         ┌──────────────────┐
         │  AIHeadset.app   │   ← aggregate device + routing
         └──────────────────┘
             ↙          ↘
     Your headphones    ElevenLabs agent
                        (WebSocket, PCM 16 kHz)
```

Two devices instead of one, because the app and the daemon cannot both read
from the same input stream — the daemon has to sit in the middle.

## Three modes, one shortcut

| | The caller hears | The agent hears | You hear |
|---|---|---|---|
| 🌊 **PASS** | you | the caller | the caller |
| 🧠 **AGENT** | **the agent** | the caller | the caller **+ the agent** |
| 🔇 **MUTE** | silence | the caller | the caller |

`⌘⇧A` toggles PASS ↔ AGENT — deliberately non-blocking, so it still works when
the WebSocket is hung. The menu bar icon uses **a distinct glyph per mode** and
turns purple while the agent is actually speaking on your channel.

## What it does

- **Live transcription** — both sides of the call separately ("Me" / "Others"), in every
  mode. Open **Transcriber…** (`⌘⇧T`). Pick the engine in Settings → Transcription:
  Apple (on this Mac), ElevenLabs Scribe (cloud) or a local Whisper server
  (`whisper-server -m model.bin -l en --port 8080` from whisper.cpp)
- **Live hints** — a small floating window above Teams; you type "client is
  asking about pricing, don't commit" and the agent takes it into account from
  its next turn, without interrupting what it is saying
- **Agent persona at hand** — role and character edited in the app, saved
  straight to your ElevenLabs account
- **Traffic meters** — four levels (to agent, from agent, to headphones,
  microphone), so silence can be diagnosed by looking rather than guessing
- **Config health check** — the app reads the agent's settings and flags the
  ones that conflict with its own requirements (audio format, call length,
  greeting)
- **Safety nets** — dead man's switch on a dropped connection, clock drift
  watchdog, and a filter that blocks promises about prices and deadlines
- **Two languages** — English and Polish, picked from your system settings

---

## Install

### From a release package

```bash
unzip AIHeadset-0.5.3-*.zip
cd dist && ./install.sh
```

The driver goes to `/Library/Audio/Plug-Ins/HAL/`, the app to `/Applications/`,
and `coreaudiod` restarts (one second of system-wide silence — that's normal).

> [!IMPORTANT]
> Launch it from `/Applications`, not from the unpacked folder. macOS applies
> App Translocation otherwise, and permissions have nowhere to persist.

After installing: allow **microphone** access, grant **Accessibility** for the
keyboard shortcut, and enter your **API key** (it stays in this machine's
Keychain and does not travel with the package).

### From source

```bash
cp packaging/.env.example packaging/.env   # Apple ID, Team ID, certificate
make driver && make install                # HAL driver (needs sudo)
make run                                   # the app, ~2 s
```

> [!NOTE]
> **The driver must be notarized even for local testing.** `coreaudiod` loads
> HAL plug-ins through a sandboxed XPC helper that enforces this via AMFI. The
> app itself does not need notarization to run locally.

```bash
./packaging/make_dist.sh    # build + sign + notarize + zip, one command
```

---

## Setup

Menu bar icon → **Hints for Agent…** (`⌘⇧H`) and **Settings…** (`⌘,`)

| Where | What to select |
|---|---|
| macOS Sound settings | **your headphones** — not AI Headset |
| Teams / Zoom → mic and speaker | **AI Headset** |
| Menu → Headphones | the headphones you listen on |
| Menu → Microphone | your physical microphone |

> [!WARNING]
> Do not set `AI Headset` as the system default device. Every sound —
> notifications, music — would then reach the agent as if it were the caller's
> voice.

### On the ElevenLabs side

This app is an audio bridge; who the agent is, which model it uses and what it
knows are configured at [elevenlabs.io](https://elevenlabs.io) → Conversational AI.

**Without these there will be no audio:**

| Setting | Value |
|---|---|
| Input audio format | `PCM 16000 Hz` |
| Output audio format | `PCM 16000 Hz` |

Also worth doing: raise `max_duration_seconds` (the 20-minute default cuts calls
off), clear `first_message` (the agent joins a conversation **already in
progress**, so a greeting lands mid-sentence), and keep `reasoning_effort` low —
a reasoning model can take 7 seconds to answer, which is unusable in a voice
call.

---

## Diagnostics

```bash
make logs                                                   # live
log show --last 10m --predicate 'subsystem == "cat.sysop.aiheadset"'
```

Menu → **Test sound in headphones** sends a tone straight to the output,
bypassing Teams and the driver — it cuts the problem in half without guessing.

---

## Project status

The driver, routing and modes work and have been tested against real hardware.
Below is what is **missing** — deliberately and openly:

| Component | State |
|---|---|
| `Transcript` | written, not wired up — conversations are not saved |
| `ConsentAnnouncer` | written, not wired up — the recording notice does not play by itself |
| `CommitmentFilter` | Polish **and** English patterns, both always active; other languages fall back to the prompt layer |
| ElevenLabs protocol fields | `user_transcript`, `agent_response`, `vad_score`, `ping` — **unverified** against the docs (marked in code) |
| `.pkg` installer | needs a *Developer ID Installer* certificate; `make_dist.sh` (zip) works today |
| Hour-long call test | **not done** — the plan calls it the quality gate |

> [!CAUTION]
> **Recording and consent.** This app puts a synthetic voice into a conversation
> with another person, and ElevenLabs processes the audio on their side.
> Informing the other party is on you — the project does **not** enforce it,
> because `ConsentAnnouncer` is not wired up. In many jurisdictions recording
> someone without their knowledge is unlawful.

---

## Layout

```
driver/      HAL driver (C11) — two devices, lock-free ring buffers
daemon/      the app (Swift/AppKit) — aggregate device, routing, agent
tools/       throwaway diagnostics (not part of the product)
packaging/   signing, notarization, distribution
VERSION      the single source of the version number
```

| Command | Purpose |
|---|---|
| `make run` | build + sign + launch, ~2 s |
| `make logs` | live app logs |
| `packaging/make_dist.sh` | full distributable (build → notarize → zip) |
| `packaging/make_pkg.sh` | `.pkg` installer (needs an Installer certificate) |

Releasing: bump `VERSION`, run `packaging/make_dist.sh`.

> [!TIP]
> Tools in `tools/` that touch the Keychain require `AIHEADSET_TEST_KEYCHAIN_SUFFIX`
> and refuse to run without it. Writing to the production entry from a different
> binary rebinds its ACL and silently locks the app out of its own API key —
> this actually happened.

---

<div align="center">

Built from a detailed technical design document (not published).

</div>
