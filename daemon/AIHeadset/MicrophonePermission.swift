import AppKit
import AVFoundation

/// Bez zgody TCC macOS podaje aplikacji **ciszę zamiast dźwięku z
/// mikrofonu** -- bufory wejściowe przychodzą wypełnione zerami, bez
/// błędu, bez ostrzeżenia, bez śladu w logu. Objaw jest nie do
/// odróżnienia od zepsutego routingu, dlatego stan uprawnienia musi
/// być sprawdzany i pokazywany wprost.
enum MicrophonePermission {
    enum State {
        case granted
        case denied
        case notDetermined

        var isUsable: Bool { self == .granted }
    }

    static var rawStatusDescription: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted (zasady systemowe/MDM)"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static var state: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Wywołaj przy starcie. Przy `.notDetermined` macOS pokaże pytanie;
    /// przy `.denied` nie pokaże już nic i jedyną drogą są Ustawienia
    /// systemowe, dlatego wtedy trzeba powiedzieć o tym użytkownikowi.
    static func requestIfNeeded(completion: @escaping (State) -> Void) {
        switch state {
        case .granted:
            Log.info("uprawnienie do mikrofonu: przyznane")
            completion(.granted)
        case .denied:
            Log.error("uprawnienie do mikrofonu: ODMÓWIONE -- tryb PASS będzie przekazywał ciszę; włącz w Ustawieniach systemowych → Prywatność i ochrona → Mikrofon")
            completion(.denied)
        case .notDetermined:
            // Aplikacja jest LSUIElement (tylko pasek menu, bez ikony w
            // Docku) i jako nieaktywna NIE MOŻE pokazać okna uprawnień
            // -- macOS odmawia wtedy natychmiast, bez pytania i bez
            // wpisu na liście w Ustawieniach. Zaobserwowane: prośba i
            // odmowa w odstępie 11 ms. Aktywacja plus chwila zwłoki na
            // pełne uruchomienie dają systemowi warunki do wyświetlenia
            // pytania.
            Log.info("uprawnienie do mikrofonu: status przed prośbą = \(rawStatusDescription); aktywuję i pytam")
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        Log.info("uprawnienie do mikrofonu: \(granted ? "przyznane" : "odmówione"), status po prośbie = \(rawStatusDescription)")
                        completion(granted ? .granted : .denied)
                    }
                }
            }
        }
    }
}
