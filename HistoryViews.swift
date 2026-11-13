import MapKit
import SwiftUI

private func euros(_ v: Double) -> String { String(format: "%.2f €", v).replacingOccurrences(of: ".", with: ",") }

struct TripsView: View {
    @EnvironmentObject var st: Store
    @AppStorage("prixMaison") private var prix = 0.21

    var body: some View {
        List {
            if let t = st.curTrip { Section("En cours") { TripRow(t: t, prix: prix) } }
            Section {
                ForEach(st.trips) { t in
                    NavigationLink { TripDetail(t: t, prix: prix) } label: { TripRow(t: t, prix: prix) }
                }
                .onDelete { st.trips.remove(atOffsets: $0); st.save() }
            } header: {
                Text("\(st.trips.count) trajets · conso moyenne \(fr(st.conso)) kWh/100 km")
            } footer: {
                Text("Enregistrés par l'app pendant la connexion Bluetooth (hors WiFi maison). Coût calculé au prix du kWh maison.")
            }
        }
        .navigationTitle("Trajets")
    }
}

struct TripRow: View {
    let t: Trip
    let prix: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t.start.formatted(date: .abbreviated, time: .shortened)).font(.headline)
            Text([t.km.map { "\(fr($0, 0)) km" }, "\(t.minutes) min", t.conso.map { "\(fr($0)) kWh/100" },
                  t.kwh > 0 ? euros(t.kwh * prix) : nil].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TripDetail: View {
    let t: Trip
    let prix: Double

    private static let couleurs: [Color] = [.kTeal, .kBlue, .kGold, .kRed]
    private func classe(_ kw: Double?) -> Int { guard let k = kw else { return 1 }; return k < -1 ? 0 : k < 12 ? 1 : k < 30 ? 2 : 3 }

    /// Tracé découpé en tronçons de même couleur (récupération, faible, moyenne, forte puissance)
    private var troncons: [(c: Int, pts: [CLLocationCoordinate2D])] {
        var out: [(c: Int, pts: [CLLocationCoordinate2D])] = []
        for g in t.pts {
            let co = CLLocationCoordinate2D(latitude: g.lat, longitude: g.lon), c = classe(g.kw)
            if var last = out.last, last.c == c { last.pts.append(co); out[out.count - 1] = last }
            else { out.append((c, (out.last?.pts.last.map { [$0] } ?? []) + [co])) }
        }
        return out.filter { $0.pts.count >= 2 }
    }

    var body: some View {
        let cs = t.pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let tr = troncons
        let sm = t.samples ?? []
        List {
            Section {
                if cs.count > 1 {
                    Map {
                        ForEach(tr.indices, id: \.self) { i in
                            MapPolyline(coordinates: tr[i].pts).stroke(Self.couleurs[tr[i].c], lineWidth: 5)
                        }
                        Marker("Départ", systemImage: "flag.fill", coordinate: cs[0]).tint(.green)
                        Marker("Arrivée", systemImage: "flag.checkered", coordinate: cs[cs.count - 1]).tint(Color.kRed)
                    }
                    .frame(height: 300)
                    .listRowInsets(EdgeInsets())
                    HStack(spacing: 12) {
                        ForEach(0..<4, id: \.self) { i in
                            Label(["Récupération", "Faible", "Moyenne", "Forte"][i], systemImage: "circle.fill")
                                .font(.caption2).foregroundStyle(Self.couleurs[i])
                        }
                    }
                } else {
                    Text("Pas de tracé GPS pour ce trajet").foregroundStyle(.secondary)
                }
            } footer: {
                if cs.count > 1 { Text("Couleur du tracé selon la puissance demandée à la batterie.") }
            }
            if sm.count >= 3 {
                Section("Puissance") { PowerChart(pts: sm.map { (m: Double($0.s) / 60, kw: $0.kw) }) }
                let socs = sm.compactMap { x in x.soc.map { (m: Double(x.s) / 60, soc: $0) } }
                if socs.count >= 3 { Section("Niveau de charge") { SocChart(pts: socs) } }
            }
            Section {
                LabeledContent("Départ", value: t.start.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Arrivée", value: t.end.formatted(date: .omitted, time: .shortened))
                LabeledContent("Distance", value: t.km.map { "\(fr($0, 0)) km" } ?? "—")
                LabeledContent("Durée", value: "\(t.minutes) min")
                LabeledContent("Énergie", value: "\(fr(t.kwh)) kWh")
                LabeledContent("Consommation", value: t.conso.map { "\(fr($0)) kWh/100 km" } ?? "—")
                if sm.count >= 3 {
                    let regen = sm.filter { $0.kw < 0 }.count, tot = sm.count
                    LabeledContent("Récupération", value: "\(regen * 100 / max(tot, 1)) % du temps")
                    LabeledContent("Puissance maxi", value: "\(fr(sm.map(\.kw).max(), 0)) kW")
                }
                LabeledContent("SOC", value: "\(fr(t.socStart, 0)) → \(fr(t.socEnd, 0)) %")
                LabeledContent("Vitesse maxi", value: "\(t.maxKmh) km/h")
                LabeledContent("Coût estimé", value: euros(t.kwh * prix))
            }
        }
        .navigationTitle(t.start.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ChargesView: View {
    @EnvironmentObject var st: Store
    @AppStorage("prixBorne") private var prix = 0.45
    @State private var lieu = 0

    var body: some View {
        List {
            Picker("Lieu", selection: $lieu) { Text("Bornes").tag(0); Text("Maison").tag(1) }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            if lieu == 1 {
                HomeChargesList()
            } else {
                if let c = st.curCharge { Section("En cours") { NavigationLink { ChargeDetail(c: c, prix: prix) } label: { ChargeRow(c: c, prix: prix) } } }
                Section {
                    ForEach(st.charges) { c in
                        NavigationLink { ChargeDetail(c: c, prix: prix) } label: { ChargeRow(c: c, prix: prix) }
                    }
                    .onDelete { st.charges.remove(atOffsets: $0); st.save() }
                } header: {
                    Text("\(st.charges.count) recharges · \(fr(st.charges.reduce(0.0) { $0 + $1.kwh }, 0)) kWh")
                } footer: {
                    Text("Détectées pendant la connexion Bluetooth, donc hors WiFi maison. Coût au prix du kWh borne (Réglages).")
                }
            }
        }
        .navigationTitle("Recharges")
    }
}

struct ChargeDetail: View {
    let c: Charge
    let prix: Double
    var body: some View {
        let sm = c.samples ?? []
        List {
            if sm.count >= 3 {
                Section("Puissance") { PowerChart(pts: sm.map { (m: Double($0.s) / 60, kw: $0.kw) }) }
                let socs = sm.compactMap { x in x.soc.map { (m: Double(x.s) / 60, soc: $0) } }
                if socs.count >= 3 { Section("Niveau de charge") { SocChart(pts: socs) } }
            }
            Section {
                if let l = c.lieu { LabeledContent("Lieu", value: l) }
                LabeledContent("Début", value: c.start.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Durée", value: "\(Int(c.end.timeIntervalSince(c.start) / 60)) min")
                LabeledContent("Énergie", value: "\(fr(c.kwh)) kWh")
                LabeledContent("SOC", value: "\(fr(c.socStart, 0)) → \(fr(c.socEnd, 0)) %")
                LabeledContent("Puissance maxi", value: "\(fr(c.maxKw, 0)) kW")
                LabeledContent("Coût estimé", value: euros(c.kwh * prix))
                if let la = c.lat, let lo = c.lon {
                    Button {
                        let it = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: la, longitude: lo)))
                        it.name = c.lieu ?? "Recharge"; it.openInMaps()
                    } label: { Label("Ouvrir dans Plans", systemImage: "map") }
                }
            }
        }
        .navigationTitle("Recharge")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ChargeRow: View {
    let c: Charge
    let prix: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(c.start.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                Spacer()
                Text(euros(c.kwh * prix)).font(.subheadline.weight(.semibold))
            }
            if let l = c.lieu { Text(l).font(.subheadline) }
            Text("\(fr(c.socStart, 0)) → \(fr(c.socEnd, 0)) % · \(fr(c.kwh)) kWh · maxi \(fr(c.maxKw, 0)) kW · \(Int(c.end.timeIntervalSince(c.start) / 60)) min")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LogView: View {
    @EnvironmentObject var st: Store
    var body: some View {
        List(st.log.reversed()) { e in
            VStack(alignment: .leading, spacing: 2) {
                Text(e.text).font(.subheadline)
                Text(e.date.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Journal")
        .toolbar {
            ShareLink(item: st.log.map { "\($0.date.formatted(date: .numeric, time: .standard))  \($0.text)" }.joined(separator: "\n")) {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }
}
