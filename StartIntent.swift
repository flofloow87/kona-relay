import AppIntents

/// Action Raccourcis : lance l'app en arrière-plan (sans l'afficher), relance la connexion à l'ESP
/// et ouvre l'activité en direct du trajet (autorisé en arrière-plan pour une LiveActivityIntent).
struct StartRelayIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Démarrer le relais Kona"
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        BLERelay.shared.kick()
        Live.start("Trajet", BLERelay.shared.liveState())
        try? await Task.sleep(nanoseconds: 8_000_000_000)   // laisse le temps au BLE de se connecter
        return .result()
    }
}

/// Siri : « Dis Siri, autonomie de la Kona Relay » — réponse vocale sans ouvrir l'app
struct AutonomieIntent: AppIntent {
    static var title: LocalizedStringResource = "Autonomie de la Kona"
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let r = BLERelay.shared
        guard let d = r.data, let soc = d.soc ?? d.socBms else {
            return .result(dialog: "Je n'ai pas encore de données de la Kona.")
        }
        let km = Meteo.shared.range(soc) ?? Store.shared.range(soc) ?? 0
        var t = "La Kona est à \(Int(soc.rounded())) %, environ \(km) kilomètres d'autonomie"
        if let eta = r.chargeETA(d) { t += ". Elle sera à \(eta.cible) % dans \(eta.min) minutes" }
        else if d.charging { t += ", en charge" }
        let age = Int(-d.date.timeIntervalSinceNow / 60)
        if age > 10 { t += ". Dernière lecture il y a " + (age < 120 ? "\(age) minutes" : "\(age / 60) heures") }
        return .result(dialog: IntentDialog(stringLiteral: t + "."))
    }
}

struct KonaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRelayIntent(),
                    phrases: ["Démarrer \(.applicationName)"],
                    shortTitle: "Démarrer le relais",
                    systemImageName: "car")
        AppShortcut(intent: AutonomieIntent(),
                    phrases: ["Autonomie de la \(.applicationName)", "Charge de la \(.applicationName)", "État de la \(.applicationName)"],
                    shortTitle: "Autonomie",
                    systemImageName: "battery.75percent")
    }
}
