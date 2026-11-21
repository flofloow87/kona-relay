import SwiftUI

private func euros(_ v: Double) -> String { String(format: "%.2f €", v).replacingOccurrences(of: ".", with: ",") }

private func heures(_ min: Int) -> String { min >= 60 ? "\(min / 60) h \(String(format: "%02d", min % 60))" : "\(min) min" }

// MARK: - Onglet Recharge
struct RechargePage: View {
    @EnvironmentObject var r: BLERelay
    @EnvironmentObject var st: Store
    let now: Date
    @AppStorage("socCible") private var socCible = 80
    @AppStorage("prixBorne") private var prixBorne = 0.45
    @State private var shown = false
    @ScaledMetric(relativeTo: .largeTitle) private var taille: CGFloat = 56

    var body: some View {
        let d = r.data
        let soc = d?.soc ?? d?.socBms
        let charge = r.enCharge(now)
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    PageTitle(titre: "Recharge", sous: sousTitre(charge)).modifier(Reveal(on: shown, delay: 0))
                    VStack(spacing: 16) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(soc.map { "\(Int($0.rounded()))" } ?? "—")
                                .font(.system(size: min(taille, 96), weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Color.soc(soc))
                                .contentTransition(.numericText(value: soc ?? 0))
                            Text("%").font(.title2.weight(.medium)).foregroundStyle(Color.kSub)
                        }
                        .animation(.snappy, value: soc)
                        ChargeBar(soc: soc, cible: socCible, charging: charge)
                        StatStrip(items: stats(d, charge))
                    }
                    .modifier(Reveal(on: shown, delay: 0.08))
                    if charge, let c = st.curCharge, (c.samples?.count ?? 0) >= 2 {
                        ChargeCurveCard(c: c).modifier(Reveal(on: shown, delay: 0.16))
                    } else if let c = st.charges.first {
                        derniere(c).modifier(Reveal(on: shown, delay: 0.16))
                    } else {
                        ContentUnavailableView {
                            Label("Pas encore de recharge sur borne", systemImage: "ev.charger")
                        } description: {
                            Text("Les recharges hors de la maison s'enregistrent quand l'iPhone reste relié en Bluetooth pendant la charge. Celles de la maison sont dans Recharges, onglet Maison.")
                        }
                        .modifier(Reveal(on: shown, delay: 0.16))
                    }
                    MenuSection(titre: "Historique") {
                        MenuLink(icon: "ev.charger", title: "Recharges",
                                 sub: st.curCharge != nil ? "Recharge en cours" : "\(st.charges.count) sur borne · maison",
                                 tint: st.curCharge != nil ? .kTeal : Color.primary.opacity(0.9), actif: st.curCharge != nil) {
                            ChargesView().environmentObject(st).environmentObject(r)
                        }
                        MenuLink(icon: "chart.line.uptrend.xyaxis", title: "Comparer les bornes", sub: "Puissance selon le niveau de charge") {
                            BornesView().environmentObject(st)
                        }
                        MenuLink(icon: "chart.bar", title: "Bilans mensuels", sub: "Kilomètres, coûts et économies") {
                            BilansView().environmentObject(r)
                        }
                    }
                    .modifier(Reveal(on: shown, delay: 0.24))
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .konaScroll(glow: charge ? .kTeal : KonaBackdrop.defaut)
            .refreshable { await r.fetchHA() }
            .task { shown = true }
        }
    }

    private func sousTitre(_ charge: Bool) -> String {
        if charge { return "En charge" }
        if r.data?.charging == true { return "En charge à la dernière lecture" }
        return "Pas en charge"
    }

    private func stats(_ d: KonaData?, _ charge: Bool) -> [(String, String, Color)] {
        if charge {
            var l: [(String, String, Color)] = [("\(fr(abs(d?.kw ?? 0))) kW", "Puissance", Color.kTeal)]
            if let eta = r.chargeETA(d) {
                l.append((now.addingTimeInterval(Double(eta.min) * 60).formatted(date: .omitted, time: .shortened), "\(eta.cible) % atteints", Color.primary))
                l.append((heures(eta.min), "Restant", Color.primary))
            }
            if let c = st.curCharge { l.append(("+\(fr(c.kwh)) kWh", "Ajoutés", Color.primary)) }
            return l
        }
        let debut = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        let mois = st.charges.filter { $0.start >= debut }
        return [
            ("\(socCible) %", "Objectif", Color.primary),
            (st.range(100).map { "\($0) km" } ?? "—", "Autonomie à 100 %", Color.primary),
            ("\(mois.count)", "Sur borne ce mois", Color.primary),
            ("\(fr(mois.map(\.kwh).reduce(0, +), 0)) kWh", "Énergie ce mois", Color.primary),
        ]
    }

    private func derniere(_ c: Charge) -> some View {
        let socs = c.socStart.flatMap { a in c.socEnd.map { "\(fr(a, 0)) → \(fr($0, 0)) %" } }
        let infos = [c.lieu, "\(Int(c.end.timeIntervalSince(c.start) / 60)) min", "maxi \(fr(c.maxKw, 0)) kW", socs].compactMap { $0 }
        return NavigationLink { ChargeDetail(c: c, prix: prixBorne).konaPage() } label: {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("DERNIÈRE RECHARGE").font(.caption.weight(.semibold)).tracking(1.1).foregroundStyle(Color.kSub)
                    HStack(alignment: .firstTextBaseline) {
                        Text("+\(fr(c.kwh)) kWh").font(.title2.weight(.semibold).monospacedDigit())
                        Spacer()
                        Text(c.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Color.kSub)
                    }
                    Text(infos.joined(separator: " · ")).font(.caption).foregroundStyle(Color.kSub).lineLimit(2)
                }
                .foregroundStyle(Color.primary)
            }
        }
        .buttonStyle(RowStyle())
    }
}

/// Grande batterie façon Tesla : niveau, repère de l'objectif, reflet qui défile en charge
struct ChargeBar: View {
    let soc: Double?
    let cible: Int
    let charging: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let f = max(0, min(1, (soc ?? 0) / 100))
        let col = Color.soc(soc)
        let forme = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 6) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    forme.fill(Color.primary.opacity(0.07))
                    forme.fill(LinearGradient(colors: [col.opacity(0.65), col], startPoint: .leading, endPoint: .trailing))
                        .overlay { if charging && !reduce { Shimmer() } }
                        .clipShape(forme)
                        .frame(width: max(10, w * CGFloat(shown ? f : 0)))
                        .shadow(color: col.opacity(charging ? 0.6 : 0.25), radius: charging ? 10 : 4)
                    Capsule().fill(Color.primary.opacity(0.75))
                        .frame(width: 2.5, height: g.size.height + 10)
                        .offset(x: w * CGFloat(cible) / 100 - 1.25)
                }
                .overlay(forme.strokeBorder(Color.primary.opacity(0.15)))
            }
            .frame(height: 38)
            HStack {
                Text("0 %")
                Spacer()
                Text("Objectif \(cible) %")
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(Color.kSub)
        }
        .animation(.spring(duration: 0.9, bounce: 0.15), value: f)
        .task {
            withAnimation(reduce ? nil : Animation.spring(duration: 1.3, bounce: 0.12).delay(0.3)) { shown = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Batterie \(Int(((soc ?? 0)).rounded())) %, objectif \(cible) %")
    }
}

// MARK: - Onglet Trajets
struct TrajetsPage: View {
    @EnvironmentObject var r: BLERelay
    @EnvironmentObject var st: Store
    @AppStorage("prixMaison") private var prix = 0.21
    @State private var shown = false

    var body: some View {
        let mois = st.trips.filter { $0.start > Date().addingTimeInterval(-30 * 86400) }
        let km = mois.compactMap(\.km).reduce(0, +)
        let kwh = mois.map(\.kwh).reduce(0, +)
        let items: [(String, String, Color)] = [
            ("\(fr(km, 0)) km", "30 derniers jours", Color.primary),
            ("\(mois.count)", "Trajets", Color.primary),
            (km > 0 ? fr(kwh / km * 100) : "—", "kWh/100 km", Color.primary),
            (euros(kwh * prix), "Coût", Color.primary),
        ]
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    PageTitle(titre: "Trajets", sous: "\(st.trips.count) trajets enregistrés · \(fr(st.conso)) kWh/100 km")
                        .modifier(Reveal(on: shown, delay: 0))
                    if let t = st.curTrip { enCours(t).modifier(Reveal(on: shown, delay: 0.06)) }
                    if st.trips.isEmpty && st.curTrip == nil {
                        ContentUnavailableView {
                            Label("Pas encore de trajet", systemImage: "map")
                        } description: {
                            Text("Les trajets s'enregistrent quand l'iPhone est relié en Bluetooth à la Kona pendant que tu roules, hors WiFi maison.")
                        }
                        .modifier(Reveal(on: shown, delay: 0.1))
                    } else {
                        Card { StatStrip(items: items) }.modifier(Reveal(on: shown, delay: 0.1))
                    }
                    if let t = st.trips.first { dernier(t).modifier(Reveal(on: shown, delay: 0.16)) }
                    MenuSection(titre: "Analyses") {
                        MenuLink(icon: "list.bullet", title: "Historique", sub: "Tous les trajets, tracé et coût") {
                            TripsView().environmentObject(st)
                        }
                        MenuLink(icon: "calendar", title: "Calendrier", sub: "Jours de route et de recharge") {
                            CalendarView().environmentObject(st)
                        }
                        MenuLink(icon: "arrow.triangle.swap", title: "Trajets répétés", sub: "Tes trajets habituels comparés") {
                            RecurringView().environmentObject(st)
                        }
                        MenuLink(icon: "speedometer", title: "Conso et vitesse", sub: "kWh/100 km selon la vitesse") {
                            SpeedConsoView().environmentObject(st)
                        }
                    }
                    .modifier(Reveal(on: shown, delay: 0.22))
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .konaScroll(glow: st.curTrip != nil ? .kBlue : KonaBackdrop.defaut)
            .task { shown = true }
        }
    }

    private func enCours(_ t: Trip) -> some View {
        let km = r.data?.odo.flatMap { o in t.odoStart.map { o - $0 } }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("TRAJET EN COURS", systemImage: "location.fill")
                    .font(.caption.weight(.semibold)).tracking(1.1).foregroundStyle(Color.kBlue)
                    .symbolEffect(.pulse)
                StatStrip(items: [
                    (t.start.formatted(date: .omitted, time: .shortened), "Départ", Color.primary),
                    (km.map { "\($0) km" } ?? "—", "Parcourus", Color.primary),
                    ("\(fr(t.kwh)) kWh", "Consommés", Color.primary),
                ])
            }
        }
    }

    private func dernier(_ t: Trip) -> some View {
        let infos = [t.km.map { "\(fr($0, 0)) km" }, "\(t.minutes) min", t.conso.map { "\(fr($0)) kWh/100" },
                     t.kwh > 0 ? euros(t.kwh * prix) : nil].compactMap { $0 }
        return NavigationLink { TripDetail(t: t, prix: prix).konaPage() } label: {
            Card {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DERNIER TRAJET").font(.caption.weight(.semibold)).tracking(1.1).foregroundStyle(Color.kSub)
                        Text(t.start.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        Text(infos.joined(separator: " · ")).font(.caption).foregroundStyle(Color.kSub).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if t.pts.count >= 2 {
                        Trace(pts: t.pts).frame(width: 84, height: 64)
                    }
                }
                .foregroundStyle(Color.primary)
            }
        }
        .buttonStyle(RowStyle())
    }
}

/// Tracé GPS d'un trajet qui se dessine à l'apparition
struct Trace: View {
    let pts: [GeoPt]
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        TraceShape(pts: pts)
            .trim(from: 0, to: shown ? 1 : 0)
            .stroke(LinearGradient(colors: [.kTeal, .kBlue], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .shadow(color: Color.kBlue.opacity(0.5), radius: 4)
            .task {
                withAnimation(reduce ? nil : Animation.easeInOut(duration: 1.4).delay(0.3)) { shown = true }
            }
            .accessibilityHidden(true)
    }
}

struct TraceShape: Shape {
    let pts: [GeoPt]
    func path(in rect: CGRect) -> Path {
        guard pts.count >= 2 else { return Path() }
        let pas = max(1, pts.count / 300)
        let l = stride(from: 0, to: pts.count, by: pas).map { pts[$0] } + [pts[pts.count - 1]]
        let k = cos((l.map(\.lat).reduce(0, +) / Double(l.count)) * .pi / 180)
        let xs = l.map { $0.lon * k }, ys = l.map(\.lat)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return Path() }
        let w = max(x1 - x0, 1e-6), h = max(y1 - y0, 1e-6)
        let sc = min(Double(rect.width) / w, Double(rect.height) / h)
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        var p = Path()
        for i in l.indices {
            let pt = CGPoint(x: Double(rect.midX) + (xs[i] - cx) * sc, y: Double(rect.midY) - (ys[i] - cy) * sc)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

// MARK: - Onglet Santé
struct SantePage: View {
    @EnvironmentObject var r: BLERelay
    @EnvironmentObject var st: Store
    @StateObject private var carnet = EntretienStore.shared
    @State private var shown = false

    var body: some View {
        let d = r.data
        let v12 = d?.v12d ?? d?.v12
        let bas = (v12 ?? 13) < 12.2
        let items: [(String, String, Color)] = [
            (d?.volts.map { "\(fr($0, 0)) V" } ?? "—", "Tension HV", Color.primary),
            (d?.tMin.map { "\($0)–\(d?.tMax ?? $0) °C" } ?? "—", "Batterie", Color.primary),
            (v12.map { "\(fr($0, 2)) V" } ?? "—", d?.v12d != nil ? "12 V mesuré" : "12 V", bas ? Color.kRed : Color.primary),
            (d?.odo.map { "\($0.formatted())" } ?? "—", "Kilomètres", Color.primary),
        ]
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    PageTitle(titre: "Santé", sous: "Batteries, mesures et entretien").modifier(Reveal(on: shown, delay: 0))
                    Card { StatStrip(items: items) }.modifier(Reveal(on: shown, delay: 0.08))
                    MenuSection(titre: "Batteries") {
                        MenuLink(icon: "bolt.batteryblock", title: "Batterie haute tension", sub: "État de santé et capacité") {
                            SOHView().environmentObject(r)
                        }
                        MenuLink(icon: "minus.plus.batteryblock", title: "Batterie 12 V",
                                 sub: v12.map { "\(fr($0, 2)) V\(bas ? " · faible" : "") · suivi au repos" } ?? "Suivi au repos",
                                 tint: bas ? .kRed : Color.primary.opacity(0.9), actif: bas) {
                            Batterie12View().environmentObject(r)
                        }
                    }
                    .modifier(Reveal(on: shown, delay: 0.16))
                    MenuSection(titre: "Véhicule") {
                        MenuLink(icon: "car", title: "Ma Kona", sub: "Véhicule, logiciels, codes défaut") {
                            MaKonaView().environmentObject(r).environmentObject(st)
                        }
                        MenuLink(icon: "wrench.and.screwdriver", title: "Carnet d'entretien",
                                 sub: carnet.items.isEmpty ? "Révisions, pneus, factures" : "\(carnet.items.count) interventions") {
                            EntretienView()
                        }
                    }
                    .modifier(Reveal(on: shown, delay: 0.22))
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .konaScroll(glow: bas ? .kRed : KonaBackdrop.defaut)
            .refreshable { await r.fetchHA() }
            .task { shown = true }
        }
    }
}

// MARK: - Onglet Plus
struct PlusPage: View {
    @EnvironmentObject var r: BLERelay
    @EnvironmentObject var st: Store
    let ouvrirReglages: () -> Void
    @AppStorage("cfgMain") private var cfgMain = 60
    @AppStorage("cfgExtra") private var cfgExtra = 300
    @State private var shown = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    PageTitle(titre: "Plus", sous: "Relais, journal et réglages").modifier(Reveal(on: shown, delay: 0))
                    Card {
                        VStack(spacing: 10) {
                            row("antenna.radiowaves.left.and.right", "Bluetooth", r.status)
                            row("paperplane.fill", "Envoi à Home Assistant", r.lastSent.map { $0.formatted(date: .omitted, time: .standard) } ?? "—")
                            row("location.fill", "Position GPS", r.hasGPS ? "Active" : "En attente")
                            row("point.topleft.down.to.point.bottomright.curvepath.fill", "Trajets synchronisés",
                                r.tripSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                            row("timer", "Cadences", "\(duree(cfgMain)) · \(duree(cfgExtra))")
                            if r.pendingCount > 0 { row("icloud.slash", "Sauvegardes en attente", "\(r.pendingCount)") }
                        }
                    }
                    .modifier(Reveal(on: shown, delay: 0.08))
                    MenuSection {
                        Button(action: ouvrirReglages) {
                            TeslaRow(icon: "gearshape", title: "Réglages", sub: "Cadences, Home Assistant, thème, firmware",
                                     tint: Color.primary.opacity(0.9))
                        }
                        .buttonStyle(RowStyle())
                        MenuLink(icon: "list.bullet.rectangle.portrait", title: "Journal", sub: "\(st.log.count) événements") {
                            LogView().environmentObject(st)
                        }
                    }
                    .modifier(Reveal(on: shown, delay: 0.16))
                    Text("Kona Relay \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                        .font(.caption).foregroundStyle(Color.kSub)
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .konaScroll()
            .task { shown = true }
        }
    }

    private func row(_ i: String, _ t: String, _ v: String) -> some View {
        HStack {
            Label(t, systemImage: i).font(.subheadline).foregroundStyle(Color.kSub)
            Spacer()
            Text(v).font(.subheadline.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}
