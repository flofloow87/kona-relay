import SwiftUI

// Aperçus Xcode (iPhone 15 Pro Max) avec des données fictives. Rien ici n'est utilisé par l'app elle-même :
// chaque aperçu a son propre relais (sans Bluetooth ni GPS) et son propre historique.

/// Situations montrées dans les aperçus
enum Scenario {
    case garee, enCharge, enRoute, vide, douzeVoltsBas

    /// Relais et historique fictifs de la situation
    func monter() -> (BLERelay, Store) {
        let st = Store()
        st.trips = []; st.charges = []; st.parking = nil; st.log = []; st.curTrip = nil; st.curCharge = nil
        switch self {
        case .garee:
            remplir(st)
            return (BLERelay(apercu: Fictif.kona(soc: 78, kw: 0, charging: false, gear: "P"), connecte: false), st)
        case .enCharge:
            remplir(st)
            st.curCharge = Fictif.recharge(debut: Date().addingTimeInterval(-50 * 60), minutes: 50, socDepart: 34)
            return (BLERelay(apercu: Fictif.kona(soc: 64, kw: -7.2, charging: true, gear: "P"), connecte: true), st)
        case .enRoute:
            remplir(st)
            st.parking = nil
            var t = Trip(start: Date().addingTimeInterval(-18 * 60), end: Date())
            t.odoStart = 45_200; t.kwh = 2.4; t.socStart = 81; t.pts = Fictif.trace(40)
            st.curTrip = t
            return (BLERelay(apercu: Fictif.kona(soc: 77, kw: 14.5, charging: false, gear: "D", speed: 87), connecte: true), st)
        case .vide:
            return (BLERelay(apercu: Fictif.kona(soc: 52, kw: 0, charging: false, gear: "P"), connecte: false), st)
        case .douzeVoltsBas:
            remplir(st)
            return (BLERelay(apercu: Fictif.kona(soc: 71, kw: 0, charging: false, gear: "P", v12: 11.9), connecte: false), st)
        }
    }

    private func remplir(_ st: Store) {
        st.trips = Fictif.trajets
        st.charges = Fictif.recharges
        st.parking = Parking(lat: 48.8584, lon: 2.2945, date: Date().addingTimeInterval(-2 * 3600))
        st.log = [LogEntry(date: Date().addingTimeInterval(-600), text: "Trajet enregistré synchronisé avec Home Assistant"),
                  LogEntry(date: Date().addingTimeInterval(-60), text: "Commande Fermer (Bluetooth)")]
    }
}

/// Données fictives (lieu générique, pas celui de la voiture)
private enum Fictif {
    static func kona(soc: Double, kw: Double, charging: Bool, gear: String, speed: Int? = nil, v12: Double = 12.62) -> KonaData {
        var k = KonaData()
        k.soc = soc; k.socBms = soc + 2; k.kw = kw; k.volts = 360 + soc * 0.4; k.amps = kw * 1000 / 380
        k.tMin = 14; k.tMax = 17; k.v12 = v12; k.v12d = v12; k.odo = 45_232
        k.charging = charging; k.gear = gear; k.speed = speed
        k.date = Date().addingTimeInterval(-90)
        return k
    }

    static func trace(_ n: Int) -> [GeoPt] {
        (0..<n).map { i in
            let x = Double(i)
            return GeoPt(lat: 48.84 + 0.012 * sin(x / 9), lon: 2.27 + 0.0012 * x, kw: 12)
        }
    }

    static var trajets: [Trip] {
        (0..<12).map { i in
            let debut = Date().addingTimeInterval(-Double(i + 1) * 86_400 * 1.6)
            var t = Trip(start: debut, end: debut.addingTimeInterval(Double(20 + i * 3) * 60))
            t.odoStart = 45_000 - i * 40; t.odoEnd = 45_000 - i * 40 + 18 + i * 2
            t.kwh = Double(18 + i * 2) * (0.14 + Double(i % 3) * 0.01)
            t.socStart = 82; t.socEnd = 74; t.maxKmh = 90 + i
            t.pts = trace(30 + i)
            return t
        }
    }

    static func recharge(debut: Date, minutes: Int, socDepart: Double) -> Charge {
        var c = Charge(start: debut, end: debut.addingTimeInterval(Double(minutes) * 60))
        c.socStart = socDepart; c.socEnd = socDepart + Double(minutes) * 0.6
        c.kwh = Double(minutes) * 0.12; c.maxKw = 7.4; c.lieu = "Borne du centre commercial"
        c.samples = (0..<minutes).map { m in
            ChargeSample(s: m * 60, kw: m < 2 ? 3.5 : 7.2 - Double(m % 5) * 0.05, soc: socDepart + Double(m) * 0.6)
        }
        return c
    }

    static var recharges: [Charge] {
        (0..<4).map { i in recharge(debut: Date().addingTimeInterval(-Double(i + 1) * 5 * 86_400), minutes: 40 + i * 10, socDepart: 30) }
    }
}

/// Injecte le relais et l'historique fictifs, thème sombre de l'app, taille de texte choisie
struct ApercuKona<Content: View>: View {
    @StateObject private var r: BLERelay
    @StateObject private var st: Store
    let taille: DynamicTypeSize
    let content: Content

    init(_ s: Scenario, taille: DynamicTypeSize = .large, @ViewBuilder content: () -> Content) {
        let (r, st) = s.monter()
        _r = StateObject(wrappedValue: r)
        _st = StateObject(wrappedValue: st)
        self.taille = taille
        self.content = content()
    }

    var body: some View {
        content
            .environmentObject(r)
            .environmentObject(st)
            .environment(\.dynamicTypeSize, taille)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
    }
}

struct KonaApercus_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ApercuKona(.garee) { ContentView() }
                .previewDisplayName("App · garée")
            ApercuKona(.enCharge) { ContentView() }
                .previewDisplayName("App · en charge")
            ApercuKona(.enRoute) { ContentView() }
                .previewDisplayName("App · en route")
            ApercuKona(.garee, taille: .accessibility5) { ContentView() }
                .previewDisplayName("App · très grande police")
            ApercuKona(.enCharge) { RechargePage(now: .now) }
                .previewDisplayName("Recharge · en charge")
            ApercuKona(.vide) { RechargePage(now: .now) }
                .previewDisplayName("Recharge · vide")
            ApercuKona(.garee) { TrajetsPage() }
                .previewDisplayName("Trajets")
            ApercuKona(.enRoute) { TrajetsPage() }
                .previewDisplayName("Trajets · en cours")
            ApercuKona(.vide) { TrajetsPage() }
                .previewDisplayName("Trajets · vide")
            ApercuKona(.douzeVoltsBas) { SantePage() }
                .previewDisplayName("Santé · 12 V faible")
            ApercuKona(.garee, taille: .accessibility5) { SantePage() }
                .previewDisplayName("Santé · très grande police")
            ApercuKona(.garee) { PlusPage {} }
                .previewDisplayName("Plus")
        }
        .previewDevice(PreviewDevice(rawValue: "iPhone 15 Pro Max"))
    }
}
