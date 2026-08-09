import Foundation
import UserNotifications

/// Plan section 6.1: "Nigdy cisza. Nigdy urwane w połowie zdanie."
/// Watches AGENT mode for the conditions the plan lists and reacts in
/// the plan's exact order: play a pre-recorded fallback (never TTS),
/// force MUTE, system notification.
///
/// `expectingAgentSpeech` and `lastAudioActivity` are meant to be
/// driven by real turn-taking state once that exists (Faza 3 wiring)
/// -- this class only implements the watchdog/reaction machinery
/// itself, not turn-taking, which the plan doesn't specify in enough
/// detail to invent here.
final class DeadMansSwitch {
    struct Config {
        var noAudioAfterUtteranceTimeout: TimeInterval = 3.0
        var turnLatencyTimeout: TimeInterval = 2.5
        var checkInterval: TimeInterval = 0.5
    }

    private let router: AudioRouter
    private let config: Config
    private let fallbackPlayer: FallbackPlayer
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "cat.sysop.aiheadset.deadmans-switch")
    private var hasTriggered = false

    /// Driven by ElevenLabsClient's state changes.
    var isConnected = false
    /// Timestamp of the last `audio` event received.
    var lastAudioActivity = Date()
    /// True only while the agent is expected to be actively speaking
    /// (between the user's utterance ending and the agent's reply
    /// finishing). Defaults false so the switch never fires while
    /// AGENT mode is just sitting idle between turns.
    var expectingAgentSpeech = false

    init(router: AudioRouter, config: Config = Config()) {
        self.router = router
        self.config = config
        self.fallbackPlayer = FallbackPlayer(router: router)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + config.checkInterval, repeating: config.checkInterval)
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Call when the user (or a fresh AGENT-mode entry) re-arms
    /// listening after a trip, so the switch can fire again.
    func rearm() {
        hasTriggered = false
    }

    /// Why the switch tripped, carried as a value rather than a string
    /// because it needs to be said twice in two languages: once in the
    /// log and once to the user. The log text is deliberately NOT
    /// localized -- a log that changes wording with the system language
    /// cannot be grepped, compared against older entries, or pasted
    /// into a bug report by a user whose Mac speaks a language the
    /// reader doesn't.
    private enum TriggerReason {
        case disconnected
        case noAudio(TimeInterval)
        case latency(TimeInterval)
        case queueEmpty

        var logText: String {
            switch self {
            case .disconnected: return "WebSocket disconnected"
            case .noAudio(let s): return String(format: "no audio event for %.1fs after user's utterance ended", s)
            case .latency(let s): return String(format: "turn latency %.1fs exceeds threshold", s)
            case .queueEmpty: return "playback queue emptied mid-utterance"
            }
        }

        var localizedText: String {
            switch self {
            case .disconnected: return L("dms.reason.disconnected")
            case .noAudio(let s): return L("dms.reason.noAudio", s)
            case .latency(let s): return L("dms.reason.latency", s)
            case .queueEmpty: return L("dms.reason.queueEmpty")
            }
        }
    }

    private func check() {
        guard router.mode == .agent, !hasTriggered else { return }

        var reason: TriggerReason?
        if !isConnected {
            reason = .disconnected
        } else if expectingAgentSpeech {
            let silence = Date().timeIntervalSince(lastAudioActivity)
            if silence > config.noAudioAfterUtteranceTimeout {
                reason = .noAudio(silence)
            } else if silence > config.turnLatencyTimeout {
                reason = .latency(silence)
            } else if router.agentPlaybackBuffer.framesAvailable == 0 && silence > 0.5 {
                reason = .queueEmpty
            }
        }

        if let reason {
            trigger(reason: reason)
        }
    }

    private func trigger(reason: TriggerReason) {
        hasTriggered = true
        Log.error("dead man's switch fired: \(reason.logText)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fallbackPlayer.playBundledFallback()
            self.router.mode = .mute
            self.notifyUser(reason: reason)
        }
    }

    private func notifyUser(reason: TriggerReason) {
        let content = UNMutableNotificationContent()
        content.title = "AI Headset"
        content.body = L("dms.body", reason.localizedText)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
