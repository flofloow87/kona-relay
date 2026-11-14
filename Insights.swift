import Charts
import CoreLocation
import MapKit
import SwiftUI

private func euros(_ v: Double?) -> String { String(format: "%.2f €", v ?? 0).replacingOccurrences(of: ".", with: ",") }

// MARK: - Météo du jour → conso et autonomie attendues
struct ConsoTemp: Decodable { struct B: Decodable { var km: Double; var kwh: Double }; var tranches: [String: B] }

@MainActor
final class Meteo: ObservableObject {
    static let shared = Meteo()
    @Published var temp: Double?
    @Published var consoJour: Double?
    private var last = Date.distantPast

    private struct OM: Decodable { struct H: Decodable { var time: [String]; var temperature_2m: [Double?] }; var hourly: H }

    func refresh(force: Bool = false) async {
        guard force || Date().timeIntervalSince(last) > 3 * 3600 else { return }
        let l = BLERelay.shared.lastLocation ?? Store.shared.parking.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
        guard let c = l?.coordinate,
              let u = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(c.latitude)&longitude=\(c.longitude)&hourly=temperature_2m&forecast_days=1&timezone=Europe%2FParis"),
              let res = try? await URLSession.shared.data(from: u),
              let r = try? JSONDecoder().decode(OM.self, from: res.0) else { return }
        var vals: [Double] = []
        for (i, t) in r.hourly.time.enumerated() where i < r.hourly.temperature_2m.count {
            let h = Int(t.suffix(5).prefix(2)) ?? 0
            if h >= 7 && h <= 20, let v = r.hourly.temperature_2m[i] { vals.append(v) }
        }
        guard !vals.isEmpty else { return }
        last = Date()
        let T = vals.reduce(0, +) / Double(vals.count)
        temp = T
        consoJour = await consoPour(T)
    }

    /// Conso attendue à la température T : tes propres tranches de température (Home Assistant), sinon un modèle simple
    private func consoPour(_ T: Double) async -> Double {
        if let f: ConsoTemp = await BLERelay.shared.haJSON("conso_temp.json") {
            let pts = f.tranches.compactMap { (k, v) -> (t: Double, c: Double)? in
                guard let lo = Double(k), v.km >= 50 else { return nil }
                return (lo + 2.5, v.kwh / v.km * 100)
            }.sorted { $0.t < $1.t }
            if let a = pts.first, T <= a.t { return a.c }
            if let z = pts.last, T >= z.t { return z.c }
            for i in 1..<max(pts.count, 1) where pts.count >= 2 {
                let a = pts[i - 1], b = pts[i]
                if T >= a.t && T <= b.t { return a.c + (b.c - a.c) * (T - a.t) / (b.t - a.t) }
            }
        }
        return Store.shared.conso * (1 + 0.015 * max(0, 15 - T))
    }

    func range(_ soc: Double?) -> Int? {
        guard let s = soc, let c = consoJour, c > 0 else { return nil }
        return Int(s / 100 * 64 / c * 100)
    }
}

// MARK: - Bilans mensuels (rapports.json)
struct Bilan: Decodable {
    struct R: Decodable { var n: Int; var kwh: Double; var cout: Double }
    var mois: String
    var km: Double
    var trajets: Int
    var conso_kwh_100km: Double?
    var recharges_maison: R
    var recharges_borne: R
    var cout_electricite: Double
    var cout_thermique: Double
    var economie: Double
}

struct BilansView: View {
    @EnvironmentObject var r: BLERelay
    @State private var bilans: [Bilan] = []
    @State private var charge = true

    var body: some View {
        List {
            if bilans.isEmpty {
                Text(charge ? "Chargement…" : "Aucun bilan pour l'instant : le premier arrive le 1er du mois.").foregroundStyle(.secondary)
            } else {
                Section("Coût par mois") {
                    Chart {
                        ForEach(bilans, id: \.mois) { b in
                            BarMark(x: .value("Mois", court(b.mois)), y: .value("€", b.cout_electricite))
                                .foregroundStyle(by: .value("Type", "Électricité")).position(by: .value("Type", "Électricité"))
                            BarMark(x: .value("Mois", court(b.mois)), y: .value("€", b.cout_thermique))
                                .foregroundStyle(by: .value("Type", "Thermique")).position(by: .value("Type", "Thermique"))
                        }
                    }
                    .chartForegroundStyleScale(["Électricité": Color.kTeal, "Thermique": Color.kRed.opacity(0.7)])
                    .frame(height: 200)
                }
                ForEach(bilans.reversed(), id: \.mois) { b in
                    Section(long(b.mois)) {
                        LabeledContent("Distance", value: "\(Int(b.km)) km · \(b.trajets) trajets")
                        if let c = b.conso_kwh_100km { LabeledContent("Consommation", value: "\(fr(c)) kWh/100 km") }
                        LabeledContent("Recharges maison", value: "\(b.recharges_maison.n) · \(fr(b.recharges_maison.kwh, 0)) kWh · \(euros(b.recharges_maison.cout))")
                        LabeledContent("Recharges borne", value: "\(b.recharges_borne.n) · \(fr(b.recharges_borne.kwh, 0)) kWh · \(euros(b.recharges_borne.cout))")
                        LabeledContent("Électricité / thermique", value: "\(euros(b.cout_electricite)) / \(euros(b.cout_thermique))")
                        LabeledContent(b.economie >= 0 ? "Économie" : "Surcoût", value: euros(abs(b.economie)))
                            .foregroundStyle(b.economie >= 0 ? Color.kTeal : Color.kRed)
                    }
                }
            }
        }
        .navigationTitle("Bilans mensuels")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let d: [String: Bilan]? = await r.haJSON("rapports.json")
        bilans = (d ?? [:]).values.sorted { $0.mois < $1.mois }
        charge = false
    }
    private func date(_ m: String) -> Date? { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.date(from: m) }
    private func court(_ m: String) -> String { date(m)?.formatted(.dateTime.month(.abbreviated).locale(Locale(identifier: "fr_FR"))) ?? m }
    private func long(_ m: String) -> String { date(m)?.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "fr_FR"))).capitalized ?? m }
}

// MARK: - Santé de la batterie haute tension (soh.json)
private struct SOHFile: Decodable { struct P: Decodable { var d: String; var soh: Double; var km: Double? }; var hist: [P] }

struct SOHView: View {
    @EnvironmentObject var r: BLERelay
    @State private var f: SOHFile?
    @State private var err: String?
    private static let jour: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    var body: some View {
        List {
            Section {
                if let f, !f.hist.isEmpty {
                    let pts: [(d: Date, v: Double)] = f.hist.compactMap { p in Self.jour.date(from: p.d).map { (d: $0, v: p.soh) } }
                    Chart {
                        ForEach(pts.indices, id: \.self) { i in
                            LineMark(x: .value("Mois", pts[i].d), y: .value("SOH", pts[i].v)).foregroundStyle(Color.kTeal)
                            PointMark(x: .value("Mois", pts[i].d), y: .value("SOH", pts[i].v)).foregroundStyle(Color.kTeal)
                        }
                    }
                    .chartYScale(domain: max(70, (pts.map(\.v).min() ?? 90) - 3)...100)
                    .frame(height: 220)
                } else {
                    Text(err ?? "Chargement…").foregroundStyle(.secondary)
                }
            } header: {
                Text("État de santé (SOH), un point par mois")
            } footer: {
                Text("Mesuré par le BMS. Une batterie de Kona perd en général quelques points sur les premiers 100 000 km.")
            }
            if let f, let a = f.hist.first, let z = f.hist.last {
                Section {
                    LabeledContent("Actuel", value: "\(fr(z.soh)) %")
                    LabeledContent("Capacité estimée", value: "\(fr(64 * z.soh / 100)) kWh")
                    if let ka = a.km, let kz = z.km, kz - ka >= 2000 {
                        LabeledContent("Évolution", value: "\(fr((z.soh - a.soh) / (kz - ka) * 10000, 2)) pt / 10 000 km")
                    }
                }
            }
        }
        .navigationTitle("Batterie haute tension")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        f = await r.haJSON("soh.json")
        err = f == nil ? "Renseigne le dossier de l'app sur Home Assistant dans Réglages" : nil
    }
}

// MARK: - Trajets répétés (même départ et même arrivée)
struct RecurringView: View {
    @EnvironmentObject var st: Store
    @AppStorage("prixMaison") private var prix = 0.21
    @State private var noms: [Int: String] = [:]

    struct Groupe { var s: CLLocation; var e: CLLocation; var trips: [Trip] }

    private var groupes: [Groupe] {
        var g: [Groupe] = []
        for t in st.trips {
            guard let a = t.pts.first, let b = t.pts.last, (t.km ?? 0) >= 1, t.conso != nil else { continue }
            let s = CLLocation(latitude: a.lat, longitude: a.lon), e = CLLocation(latitude: b.lat, longitude: b.lon)
            if let i = g.firstIndex(where: { $0.s.distance(from: s) < 500 && $0.e.distance(from: e) < 500 }) { g[i].trips.append(t) }
            else { g.append(Groupe(s: s, e: e, trips: [t])) }
        }
        return g.filter { $0.trips.count >= 2 }.sorted { $0.trips.count > $1.trips.count }
    }

    var body: some View {
        let gs = groupes
        List {
            if gs.isEmpty {
                Text("Pas encore de trajet répété : il faut au moins deux trajets avec le même départ et la même arrivée (à 500 m près).").foregroundStyle(.secondary)
            }
            ForEach(gs.indices, id: \.self) { i in
                let g = gs[i]
                let cs = g.trips.compactMap(\.conso)
                let best = g.trips.min { ($0.conso ?? 99) < ($1.conso ?? 99) }
                Section(noms[i] ?? "Trajet \(i + 1)") {
                    LabeledContent("Trajets", value: "\(g.trips.count) · \(fr(g.trips.compactMap(\.km).reduce(0, +) / Double(g.trips.count), 0)) km")
                    LabeledContent("Conso moyenne", value: "\(fr(cs.reduce(0, +) / Double(cs.count))) kWh/100")
                    LabeledContent("Meilleure / pire", value: "\(fr(cs.min())) / \(fr(cs.max())) kWh/100")
                    LabeledContent("Durée moyenne", value: "\(g.trips.map(\.minutes).reduce(0, +) / g.trips.count) min")
                    if let b = best {
                        NavigationLink { TripDetail(t: b, prix: prix) } label: {
                            Label("Meilleur : \(b.start.formatted(date: .abbreviated, time: .shortened))", systemImage: "trophy.fill").foregroundStyle(Color.kGold)
                        }
                    }
                }
            }
        }
        .navigationTitle("Trajets répétés")
        .task {
            for (i, g) in gs.enumerated() where noms[i] == nil && i < 12 {
                let a = try? await CLGeocoder().reverseGeocodeLocation(g.s).first
                let b = try? await CLGeocoder().reverseGeocodeLocation(g.e).first
                noms[i] = "\(a?.locality ?? a?.name ?? "?") → \(b?.locality ?? b?.name ?? "?")"
            }
        }
    }
}

// MARK: - Calendrier mensuel
struct CalendarView: View {
    @EnvironmentObject var st: Store
    @AppStorage("prixMaison") private var prix = 0.21
    @State private var mois = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @State private var choix: Date?

    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; c.locale = Locale(identifier: "fr_FR"); return c }

    var body: some View {
        let jours = cal.range(of: .day, in: .month, for: mois)?.count ?? 30
        let decal = (cal.component(.weekday, from: mois) + 5) % 7
        let tripsMois = st.trips.filter { cal.isDate($0.start, equalTo: mois, toGranularity: .month) }
        let kmJour: [Int: Double] = Dictionary(grouping: tripsMois) { cal.component(.day, from: $0.start) }.mapValues { $0.compactMap(\.km).reduce(0, +) }
        let maxKm = max(kmJour.values.max() ?? 1, 1)
        List {
            Section {
                HStack {
                    Button { mois = cal.date(byAdding: .month, value: -1, to: mois)!; choix = nil } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(mois.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "fr_FR"))).capitalized).font(.headline)
                    Spacer()
                    Button { mois = cal.date(byAdding: .month, value: 1, to: mois)!; choix = nil } label: { Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderless)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(["L", "M", "M", "J", "V", "S", "D"].indices, id: \.self) { i in
                        Text(["L", "M", "M", "J", "V", "S", "D"][i]).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(0..<(decal + jours), id: \.self) { i in
                        if i < decal { Color.clear.frame(height: 44) } else {
                            let j = i - decal + 1
                            let km = kmJour[j] ?? 0
                            let d = cal.date(byAdding: .day, value: j - 1, to: mois)!
                            Button { choix = d } label: {
                                VStack(spacing: 1) {
                                    Text("\(j)").font(.caption.weight(.semibold))
                                    Text(km > 0 ? "\(Int(km))" : " ").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.kTeal)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Color.kTeal.opacity(km > 0 ? 0.12 + 0.5 * km / maxKm : 0.03), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(choix.map { cal.isDate($0, inSameDayAs: d) } == true ? Color.kTeal : .clear, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } footer: {
                Text("Kilomètres parcourus chaque jour (trajets enregistrés par l'app).")
            }
            Section("Total du mois") {
                let km = tripsMois.compactMap(\.km).reduce(0, +), kwh = tripsMois.map(\.kwh).reduce(0, +)
                LabeledContent("Distance", value: "\(Int(km)) km · \(tripsMois.count) trajets")
                LabeledContent("Énergie", value: "\(fr(kwh, 0)) kWh · \(euros(kwh * prix))")
            }
            if let c = choix {
                let ts = tripsMois.filter { cal.isDate($0.start, inSameDayAs: c) }
                Section(c.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR"))).capitalized) {
                    if ts.isEmpty { Text("Aucun trajet").foregroundStyle(.secondary) }
                    ForEach(ts) { t in NavigationLink { TripDetail(t: t, prix: prix) } label: { TripRow(t: t, prix: prix) } }
                }
            }
        }
        .navigationTitle("Calendrier")
    }
}

// MARK: - Recharges maison (recharges_maison.json)
struct HomeCharge: Decodable, Identifiable {
    var debut: String
    var duree_min: Int?
    var kwh_borne: Double?
    var cout: Double?
    var soc_debut: Double?
    var soc_fin: Double?
    var part_solaire: Double?
    var kwh_hp: Double?
    var kwh_hc: Double?
    var kwh_solaire: Double?
    var kwh_zendure: Double?
    var id: String { debut }
    var date: Date? { ISO8601DateFormatter().date(from: debut) ?? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: debut) }() }
}

struct HomeChargesList: View {
    @EnvironmentObject var r: BLERelay
    @State private var list: [HomeCharge] = []
    @State private var charge = true

    var body: some View {
        Section {
            if list.isEmpty { Text(charge ? "Chargement…" : "Aucune recharge maison reçue pour l'instant (la liste se remplit à chaque nouvelle recharge).").foregroundStyle(.secondary) }
            ForEach(list) { c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(c.date?.formatted(date: .abbreviated, time: .shortened) ?? c.debut).font(.headline)
                        Spacer()
                        Text(euros(c.cout)).font(.subheadline.weight(.semibold))
                    }
                    Text("\(fr(c.soc_debut, 0)) → \(fr(c.soc_fin, 0)) % · \(fr(c.kwh_borne)) kWh · \(c.duree_min ?? 0) min" + (c.kwh_hp == nil ? (c.part_solaire.map { " · \(Int($0)) % solaire" } ?? "") : ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if c.kwh_hp != nil { MixBar(c: c) }
                }
            }
        } header: {
            Text("\(list.count) recharges · \(fr(list.compactMap(\.kwh_borne).reduce(0, +), 0)) kWh · \(euros(list.compactMap(\.cout).reduce(0, +)))")
        } footer: {
            let d = list.filter { $0.kwh_hp != nil }
            if !d.isEmpty {
                let t = { (k: KeyPath<HomeCharge, Double?>) in fr(d.compactMap { $0[keyPath: k] }.reduce(0, +), 0) }
                Text("Origine (\(d.count) recharges détaillées) : HC \(t(\.kwh_hc)) kWh · HP \(t(\.kwh_hp)) kWh · solaire \(t(\.kwh_solaire)) kWh · batterie maison \(t(\.kwh_zendure)) kWh. La batterie maison est comptée au prix HC, le solaire gratuit.")
            }
        }
        .task {
            list = (await r.haJSON("recharges_maison.json") as [HomeCharge]?) ?? []
            charge = false
        }
    }
}

// MARK: - Graphiques réutilisables
struct PowerChart: View {
    let pts: [(m: Double, kw: Double)]
    var body: some View {
        Chart {
            ForEach(pts.indices, id: \.self) { i in
                BarMark(x: .value("Minute", pts[i].m), y: .value("kW", pts[i].kw), width: .fixed(3))
                    .foregroundStyle(pts[i].kw < 0 ? Color.kTeal : (pts[i].kw > 30 ? Color.kRed : Color.kGold))
            }
            RuleMark(y: .value("0", 0)).foregroundStyle(Color.primary.opacity(0.2))
        }
        .chartXAxisLabel("min")
        .chartYAxisLabel("kW")
        .frame(height: 160)
    }
}

struct SocChart: View {
    let pts: [(m: Double, soc: Double)]
    var body: some View {
        Chart {
            ForEach(pts.indices, id: \.self) { i in
                LineMark(x: .value("Minute", pts[i].m), y: .value("SOC", pts[i].soc)).foregroundStyle(Color.kTeal).interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: max(0, (pts.map(\.soc).min() ?? 0) - 5)...min(100, (pts.map(\.soc).max() ?? 100) + 5))
        .chartXAxisLabel("min")
        .chartYAxisLabel("%")
        .frame(height: 120)
    }
}

// MARK: - Conso selon la vitesse (échantillons des trajets de l'app)
struct SpeedConsoView: View {
    @EnvironmentObject var st: Store
    @AppStorage("prixMaison") private var prix = 0.21
    private let bornes = [10, 30, 50, 70, 90, 110, 130, 200]

    private var tranches: [(nom: String, c: Double, n: Int)] {
        var kw = Array(repeating: 0.0, count: bornes.count - 1), v = kw, n = Array(repeating: 0, count: bornes.count - 1)
        for t in st.trips { for x in t.samples ?? [] {
            guard let k = x.kmh, k >= 10, let i = bornes.indices.dropLast().last(where: { bornes[$0] <= k }) else { continue }
            kw[i] += x.kw; v[i] += Double(k); n[i] += 1
        } }
        return (0..<(bornes.count - 1)).compactMap { i in
            guard n[i] >= 5, v[i] > 0 else { return nil }
            let nom = i == bornes.count - 2 ? "\(bornes[i])+" : "\(bornes[i])–\(bornes[i + 1])"
            return (nom, kw[i] / v[i] * 100, n[i])
        }
    }

    var body: some View {
        let tr = tranches
        List {
            if tr.isEmpty {
                Text("Pas encore assez de mesures : il faut quelques trajets enregistrés par l'app à différentes vitesses.").foregroundStyle(.secondary)
            } else {
                Section {
                    Chart {
                        ForEach(tr.indices, id: \.self) { i in
                            BarMark(x: .value("Vitesse", tr[i].nom), y: .value("kWh/100", tr[i].c))
                                .foregroundStyle(tr[i].c > 20 ? Color.kRed : tr[i].c > 15 ? Color.kGold : Color.kTeal)
                                .annotation(position: .top) { Text(fr(tr[i].c)).font(.caption2) }
                        }
                    }
                    .chartXAxisLabel("km/h").chartYAxisLabel("kWh/100 km")
                    .frame(height: 230)
                } header: {
                    Text("Consommation par tranche de vitesse")
                } footer: {
                    Text("Calculée sur les mesures de tes trajets (une par lecture). Le froid, le relief et la clim jouent aussi.")
                }
                if let a = tr.first(where: { $0.nom == "70–90" }), let b = tr.first(where: { $0.nom == "110–130" }) {
                    Section("110 plutôt que 90") {
                        LabeledContent("Écart", value: "\(b.c >= a.c ? "+" : "")\(fr(b.c - a.c)) kWh/100 km (\(Int(((b.c / a.c) - 1) * 100)) %)")
                        LabeledContent("Pour 100 km", value: String(format: "%+.2f €", (b.c - a.c) * prix).replacingOccurrences(of: ".", with: ","))
                        LabeledContent("Autonomie à 100 %", value: "\(Int(6400 / a.c)) km contre \(Int(6400 / b.c)) km")
                    }
                }
            }
        }
        .navigationTitle("Conso et vitesse")
    }
}
