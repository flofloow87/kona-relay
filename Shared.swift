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

extension Color {
    static let kBg1 = Color(red: 0.04, green: 0.07, blue: 0.09)
    static let kBg2 = Color(red: 0.07, green: 0.16, blue: 0.19)
    static let kTeal = Color(red: 0.50, green: 0.88, blue: 0.75)
    static let kGold = Color(red: 0.90, green: 0.77, blue: 0.44)
    static let kBlue = Color(red: 0.45, green: 0.66, blue: 1.0)
    static let kRed = Color(red: 0.95, green: 0.42, blue: 0.42)
    static let kSub = Color.white.opacity(0.55)
    static func soc(_ v: Double?) -> Color { guard let v else { return .kSub }; return v < 20 ? .kRed : v < 50 ? .kGold : .kTeal }
}
