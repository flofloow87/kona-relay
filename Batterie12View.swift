import Charts
import SwiftUI

private struct V12Point: Decodable { var d: String; var v: Double }
private struct V12Prev: Decodable { var pente_v_mois: Double; var jours: Int?; var date: String?; var nuits: Int }
private struct V12File: Decodable { var v: Double?; var moy30: Double?; var hist: [V12Point]; var prevision: V12Prev? }

struct Batterie12View: View {
    @EnvironmentObject var r: BLERelay
    @State private var f: V12File?
    @State private var err: String?

    private static let jour: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Europe/Paris"); return f }()

    var body: some View {
        List {
            Section {
                if let f, !f.hist.isEmpty {
                    let pts: [(d: Date, v: Double)] = f.hist.compactMap { p in Self.jour.date(from: p.d).map { (d: $0, v: p.v) } }
                    Chart {
                        ForEach(pts.indices, id: \.self) { i in
                            LineMark(x: .value("Nuit", pts[i].d, unit: .day), y: .value("Tension", pts[i].v))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(Color.kTeal)
                            PointMark(x: .value("Nuit", pts[i].d, unit: .day), y: .value("Tension", pts[i].v))
                                .foregroundStyle(pts[i].v < 12.4 ? Color.kRed : Color.kTeal)
                        }
                        RuleMark(y: .value("Seuil", 12.4))
                            .foregroundStyle(Color.kRed.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    .chartYScale(domain: 11.8...13.2)
                    .frame(height: 220)
                } else if let err {
                    Text(err).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            } header: {
                Text("Tension de repos, chaque nuit")
            } footer: {
                Text("Mesurée par l'ESP32, voiture endormie au garage. Une batterie en bonne santé reste à 12,5 V ou plus ; sous 12,4 V plusieurs nuits de suite, fais-la tester.")
            }
            if let f {
                Section {
                    if let p = f.prevision {
                        LabeledContent("Tendance", value: "\(p.pente_v_mois > 0 ? "+" : "")\(fr(p.pente_v_mois, 2)) V/mois")
                        if let j = p.jours, let d = p.date.flatMap({ Self.jour.date(from: $0) }) {
                            LabeledContent("Sous 12,3 V", value: j == 0 ? "déjà atteint" : d.formatted(date: .long, time: .omitted))
                                .foregroundStyle(j <= 60 ? Color.kRed : .primary)
                        } else {
                            LabeledContent("Sous 12,3 V", value: "pas en vue")
                        }
                    } else {
                        Text("Prévision disponible après 7 nuits de mesure.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Prévision de remplacement")
                } footer: {
                    Text("Tendance calculée sur les dernières nuits. Le froid fait baisser la tension de repos : en hiver, la prévision est pessimiste.")
                }
                Section {
                    LabeledContent("Dernière nuit", value: f.v.map { "\(fr($0, 2)) V" } ?? "—")
                    LabeledContent("Moyenne", value: f.moy30.map { "\(fr($0, 2)) V" } ?? "—")
                    LabeledContent("Nuits mesurées", value: "\(f.hist.count)")
                    if let v = r.data?.v12d { LabeledContent("Dernière mesure directe", value: "\(fr(v, 2)) V") }
                }
            }
        }
        .navigationTitle("Batterie 12 V")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let base = r.haFolder(), let u = URL(string: base + "v12.json?t=\(Int(Date().timeIntervalSince1970))") else {
            err = "Renseigne le dossier de l'app sur Home Assistant dans Réglages"; return
        }
        do {
            let (d, _) = try await URLSession.shared.data(for: URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData))
            f = try JSONDecoder().decode(V12File.self, from: d); err = nil
        } catch {
            err = "Lecture impossible : \(error.localizedDescription)"
        }
    }
}
