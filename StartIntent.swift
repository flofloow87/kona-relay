import AppIntents

/// Action Raccourcis : lance l'app en arrière-plan (sans l'afficher) et relance la connexion à l'ESP.
struct StartRelayIntent: AppIntent {
    static var title: LocalizedStringResource = "Démarrer le relais Kona"
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        BLERelay.shared.kick()
        try? await Task.sleep(nanoseconds: 8_000_000_000)   // laisse le temps au BLE de se connecter
        return .result()
    }
}

struct KonaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRelayIntent(),
                    phrases: ["Démarrer \(.applicationName)"],
                    shortTitle: "Démarrer le relais",
                    systemImageName: "car")
    }
}
