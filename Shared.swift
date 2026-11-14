import ActivityKit
import Foundation
import SwiftUI

// Partagé entre l'app et l'extension (widgets, activité en direct)
enum AppGroup {
    static let base = "group.fr.flo.konarelay"
    /// SideStore renomme les groupes d'apps : l'identifiant réel est dans Info.plist (ALTAppGroups).
    static var id: String {
        (Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String])?.first(where: { $0.hasPrefix(base) }) ?? base
    }
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
}

struct WidgetState: Codable {
    var soc: Double?
    var range: Int?
    var kw: Double?
    var charging = false
    var gear: String?
    var v12: Double?
    var date = Date()
    var connected = false
    var minLeft: Int?         // recharge : minutes jusqu'à l'objectif
    var cible: Int?

    static func load() -> WidgetState? {
        guard let d = AppGroup.defaults.data(forKey: "widget") else { return nil }
        return try? JSONDecoder().decode(WidgetState.self, from: d)
    }
    func save() { if let d = try? JSONEncoder().encode(self) { AppGroup.defaults.set(d, forKey: "widget") } }
}

struct KonaActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var soc: Double
        var range: Int
        var kw: Double
        var speed: Int
        var gear: String
        var charging: Bool
        var updated: Date
        var minLeft = 0          // recharge : minutes estimées jusqu'à l'objectif
        var cible = 80
        var tripKm = 0.0         // trajet en cours
        var tripConso = 0.0
        var portail = ""         // départ de la maison (10 premières min) : état du portail et du garage, vide = non affiché
        var garage = ""
    }
    var title: String
}

/// Apparence de l'app : sombre, clair ou auto (clair de 7 h à 19 h) ; accent turquoise ou rouge Kona.
/// Les widgets et CarPlay restent sombres.
enum Theme {
    static var appex: Bool { Bundle.main.bundlePath.hasSuffix(".appex") }
    static var mode: String { UserDefaults.standard.string(forKey: "theme") ?? "sombre" }
    static var clair: Bool {
        guard !appex else { return false }
        switch mode {
        case "clair": return true
        case "auto": return (7..<19).contains(Calendar.current.component(.hour, from: Date()))
        default: return false
        }
    }
    static var rouge: Bool { !appex && UserDefaults.standard.string(forKey: "accent") == "rouge" }
    static var accent: Color { rouge ? .kKona : .kTeal }
    static var scheme: ColorScheme { clair ? .light : .dark }
}

extension Color {
    static var kBg1: Color { Theme.clair ? Color(red: 0.95, green: 0.96, blue: 0.97) : Color(red: 0.04, green: 0.07, blue: 0.09) }
    static var kBg2: Color { Theme.clair ? Color(red: 0.86, green: 0.90, blue: 0.93) : Color(red: 0.07, green: 0.16, blue: 0.19) }
    static var kTeal: Color { Theme.clair ? Color(red: 0.08, green: 0.58, blue: 0.46) : Color(red: 0.50, green: 0.88, blue: 0.75) }
    static var kGold: Color { Theme.clair ? Color(red: 0.72, green: 0.52, blue: 0.08) : Color(red: 0.90, green: 0.77, blue: 0.44) }
    static var kBlue: Color { Theme.clair ? Color(red: 0.15, green: 0.40, blue: 0.85) : Color(red: 0.45, green: 0.66, blue: 1.0) }
    static var kRed: Color { Theme.clair ? Color(red: 0.80, green: 0.18, blue: 0.18) : Color(red: 0.95, green: 0.42, blue: 0.42) }
    static let kKona = Color(red: 0.86, green: 0.12, blue: 0.16)
    static var kSub: Color { Theme.clair ? Color.black.opacity(0.55) : Color.white.opacity(0.55) }
    static func soc(_ v: Double?) -> Color { guard let v else { return .kSub }; return v < 20 ? .kRed : v < 50 ? .kGold : .kTeal }
}
