import MapKit
import SwiftUI


func fr(_ v: Double?, _ d: Int = 1) -> String {
    guard let v else { return "—" }
    return String(format: "%.\(d)f", v).replacingOccurrences(of: ".", with: ",")
}

func duree(_ s: Int) -> String {
    s < 60 ? "\(s) s" : s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s"
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.primary.opacity(0.07)))
    }
}

enum HomeCard: String, CaseIterable, Identifiable {
    case jauge, recharge, mesures, commandes, stationnement, historique, etat
    var id: String { rawValue }
    var label: String {
        ["jauge": "Charge et autonomie", "recharge": "Recharge en cours", "mesures": "Mesures", "commandes": "Commandes",
         "stationnement": "Stationnement", "historique": "Historique et analyses", "etat": "État du relais"][rawValue]!
    }
    var icon: String {
        ["jauge": "gauge.with.dots.needle.67percent", "recharge": "ev.charger.fill", "mesures": "square.grid.2x2.fill", "commandes": "lock.fill",
         "stationnement": "parkingsign.circle.fill", "historique": "chart.xyaxis.line", "etat": "dot.radiowaves.left.and.right"][rawValue]!
    }
    /// Ordre enregistré (les cartes absentes sont ajoutées à la fin)
    static func ordre(_ s: String) -> [HomeCard] {
        let l = s.split(separator: ",").compactMap { HomeCard(rawValue: String($0)) }
        return l + allCases.filter { !l.contains($0) }
    }
}

struct ContentView: View {
    @EnvironmentObject var r: BLERelay
    @EnvironmentObject var st: Store
    @State private var settings = false
    @State private var confirm: KonaCommand?
    @AppStorage("cfgMain") private var cfgMain = 60
    @AppStorage("cfgExtra") private var cfgExtra = 300
    @AppStorage("homeOrder") private var homeOrder = ""
    @AppStorage("homeHidden") private var homeHidden = ""
    @AppStorage("theme") private var theme = "sombre"
    @AppStorage("accent") private var accent = "turquoise"
    @StateObject private var meteo = Meteo.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    ForEach(HomeCard.ordre(homeOrder).filter { !homeHidden.split(separator: ",").contains(Substring($0.rawValue)) }) { c in
                        carte(c)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 30)
            }
            .background(LinearGradient(colors: [.kBg2, .kBg1], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape.fill").foregroundStyle(Color.kSub) }
                }
            }
            .sheet(isPresented: $settings) { SettingsView().environmentObject(r).environmentObject(st) }
            .overlay(alignment: .bottom) {
                if let t = r.toast {
                    Text(t).font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: r.toast)
            .task { await meteo.refresh() }
            .refreshable { await r.fetchHA(); await meteo.refresh(force: true) }
            .onChange(of: phase, initial: true) { _, p in
                if p == .active { r.startHAPolling() } else { r.stopHAPolling(); if p == .background { BLERelay.scheduleHA() } }
            }
            .confirmationDialog(confirm.map { "\($0.label) la Kona ?" } ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                if let c = confirm { Button(c.label) { r.send(c) } }
                Button("Annuler", role: .cancel) {}
            }
        }
        .preferredColorScheme(Theme.scheme)
        .tint(Theme.accent)
        .id(theme + accent)
    }

    @ViewBuilder private func carte(_ c: HomeCard) -> some View {
        switch c {
        case .jauge: hero
        case .recharge: chargeCard
        case .mesures: metrics
        case .commandes: actions
        case .stationnement: parkingCard
        case .historique: history
        case .etat: footer
        }
    }

    // MARK: Recharge en cours (courbes)
    @ViewBuilder private var chargeCard: some View {
        if let c = st.curCharge, let sm = c.samples, sm.count >= 2 {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Recharge en cours", systemImage: "bolt.fill").font(.headline).foregroundStyle(Color.kTeal)
                        Spacer()
                        Text("+\(fr(c.kwh)) kWh · \(Int(c.end.timeIntervalSince(c.start) / 60)) min").font(.caption).foregroundStyle(Color.kSub)
                    }
                    PowerChart(pts: sm.map { (m: Double($0.s) / 60, kw: $0.kw) }).frame(height: 110)
                    let socs = sm.compactMap { x in x.soc.map { (m: Double(x.s) / 60, soc: $0) } }
                    if socs.count >= 2 { SocChart(pts: socs).frame(height: 90) }
                }
            }
        }
    }

    // MARK: En-tête
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kona Electric").font(.largeTitle.bold()).foregroundStyle(Theme.rouge ? Color.kKona : Color.primary)
                if let d = r.data?.date {
                    (Text("Lecture ") + Text(d, style: .relative) + Text(r.connected ? "" : r.data?.src == "ha" ? " · via Home Assistant" : " · dernière connue"))
                        .font(.footnote).foregroundStyle(Color.kSub)
                } else {
                    Text("Aucune lecture pour l'instant").font(.footnote).foregroundStyle(Color.kSub)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                linkPill
                if r.eco {
                    Label("Économie", systemImage: "leaf.fill").font(.caption2.weight(.semibold)).foregroundStyle(Color.kGold)
                }
            }
        }
        .padding(.top, 4)
    }

    private var linkPill: some View {
        let viaHA = r.haSync.map { -$0.timeIntervalSinceNow < 180 } == true
        let (icon, txt, col): (String, String, Color) = r.connected
            ? ("antenna.radiowaves.left.and.right", "Bluetooth", .kBlue)
            : viaHA ? ("house.fill", "Maison", .kTeal)
            : r.status.hasPrefix("Recherche") ? ("magnifyingglass", "Recherche", .kSub) : ("hourglass", "En attente", .kSub)
        return Label(txt, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(col)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(col.opacity(0.14), in: Capsule())
            .symbolEffect(.pulse, isActive: r.connected)
    }

    // MARK: Jauge
    private var hero: some View {
        let d = r.data
        let soc = d?.soc ?? d?.socBms
        let col = Color.soc(soc)
        return Card {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.08), lineWidth: 14)
                    Circle().trim(from: 0, to: (soc ?? 0) / 100)
                        .stroke(AngularGradient(colors: [col.opacity(0.5), col], center: .center), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.8), value: soc)
                    VStack(spacing: 0) {
                        Text(soc.map { "\(Int($0.rounded()))" } ?? "—")
                            .font(.system(size: 44, weight: .bold, design: .rounded)).foregroundStyle(col)
                            .contentTransition(.numericText())
                        Text("%").font(.caption.weight(.semibold)).foregroundStyle(Color.kSub)
                    }
                }
                .frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: 12) {
                    stat(d?.charging == true ? "En charge" : "Puissance",
                         d?.kw.map { "\(fr(abs($0))) kW" } ?? "—",
                         d?.charging == true ? "bolt.fill" : "gauge.with.dots.needle.33percent",
                         d?.charging == true ? .kTeal : .kGold)
                    stat(meteo.temp.map { "Autonomie aujourd'hui (\(Int($0.rounded())) °C)" } ?? "Autonomie estimée",
                         (meteo.range(soc) ?? st.range(soc)).map { "≈ \($0) km" } ?? "—", "road.lanes", .kTeal)
                    if let eta = r.chargeETA(d) {
                        stat("Fin à \(eta.cible) %", "≈ \(duree(eta.min * 60)) · \(Date().addingTimeInterval(Double(eta.min) * 60).formatted(date: .omitted, time: .shortened))", "timer", .kTeal)
                    } else {
                        stat("Vitesse", d?.speed.map { "\($0) km/h" } ?? "—", "speedometer", .kBlue)
                    }
                    stat("Rapport", d?.gear ?? "—", "car.side.fill", .primary)
                }
            }
        }
    }

    private func stat(_ t: String, _ v: String, _ i: String, _ c: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: i).font(.body.weight(.semibold)).foregroundStyle(c).frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(v).font(.headline.monospacedDigit())
                Text(t).font(.caption2).foregroundStyle(Color.kSub)
            }
        }
    }

    // MARK: Mesures
    private var metrics: some View {
        let d = r.data
        let tiles: [(String, String, String, Color)] = [
            ("bolt.batteryblock.fill", "Tension HV", d?.volts.map { "\(fr($0, 0)) V" } ?? "—", .kTeal),
            ("thermometer.medium", "Batterie", d?.tMin.map { "\($0)–\(d?.tMax ?? $0) °C" } ?? "—", .kGold),
            ("minus.plus.batteryblock.fill", d?.v12d != nil ? "12 V mesuré" : "Batterie 12 V", (d?.v12d ?? d?.v12).map { "\(fr($0, 2)) V" } ?? "—", (d?.v12d ?? d?.v12 ?? 13) < 12.2 ? .kRed : .kTeal),
            ("gauge.with.needle", "Kilométrage", d?.odo.map { "\($0.formatted()) km" } ?? "—", .kBlue),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(tiles.indices, id: \.self) { i in
                let t = tiles[i]
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: t.0).font(.title3).foregroundStyle(t.3)
                        Text(t.2).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                        Text(t.1).font(.caption).foregroundStyle(Color.kSub)
                    }
                }
            }
        }
    }

    // MARK: Commandes
    private var actions: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Commandes").font(.headline)
                    Spacer()
                    Label(r.bleReady ? "Bluetooth direct" : "Via Home Assistant",
                          systemImage: r.bleReady ? "antenna.radiowaves.left.and.right" : "house.fill")
                        .font(.caption).foregroundStyle(Color.kSub)
                }
                HStack(spacing: 0) {
                    ForEach(KonaCommand.allCases) { c in
                        Button {
                            if c.needsConfirm { confirm = c } else { r.send(c) }
                        } label: {
                            VStack(spacing: 8) {
                                ZStack {
                                    Circle().fill(LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                                    Circle().stroke(color(c).opacity(0.45), lineWidth: 1.5)
                                    if r.busy == c { ProgressView().tint(color(c)) }
                                    else { Image(systemName: c.icon).font(.title2).foregroundStyle(color(c)) }
                                }
                                .frame(width: 62, height: 62)
                                .shadow(color: color(c).opacity(0.25), radius: 10)
                                Text(c.label).font(.caption.weight(.semibold)).foregroundStyle(Color.primary.opacity(0.85))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .disabled(r.busy != nil)
                        .sensoryFeedback(.impact(weight: .medium), trigger: r.busy == c)
                    }
                }
                if !r.bleReady {
                    Text("Hors Bluetooth, les commandes passent par Home Assistant et ne fonctionnent que voiture au garage.")
                        .font(.caption2).foregroundStyle(Color.kSub)
                }
            }
        }
    }

    private func color(_ c: KonaCommand) -> Color {
        switch c { case .deverrouiller: .kGold; case .verrouiller: .kTeal; case .feux: .kBlue; case .klaxon: .kRed }
    }

    // MARK: Stationnement
    @ViewBuilder private var parkingCard: some View {
        if let pk = st.parking, !(r.connected && ["D", "R", "N"].contains(r.data?.gear ?? "")) {
            let c = CLLocationCoordinate2D(latitude: pk.lat, longitude: pk.lon)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Garée ici", systemImage: "parkingsign.circle.fill").font(.headline)
                        Spacer()
                        (Text("il y a ") + Text(pk.date, style: .relative)).font(.caption).foregroundStyle(Color.kSub)
                    }
                    Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 350, longitudinalMeters: 350))) {
                        Marker("Kona", systemImage: "car.fill", coordinate: c).tint(Color.kRed)
                        UserAnnotation()
                    }
                    .id(pk.date)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Button {
                        let it = MKMapItem(placemark: MKPlacemark(coordinate: c)); it.name = "Kona"
                        it.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                    } label: {
                        Label("Itinéraire à pied", systemImage: "figure.walk").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Color.kTeal.opacity(0.85))
                }
            }
        }
    }

    // MARK: Historique
    private var history: some View {
        Card {
            VStack(spacing: 0) {
                NavigationLink { TripsView().environmentObject(st) } label: {
                    navRow("map.fill", "Trajets", st.curTrip != nil ? "en cours" : "\(st.trips.count)", .kBlue)
                }
                Divider().overlay(Color.primary.opacity(0.08))
                NavigationLink { RecurringView().environmentObject(st) } label: {
                    navRow("arrow.triangle.swap", "Trajets répétés", "", .kBlue)
                }
                Divider().overlay(Color.primary.opacity(0.08))
                NavigationLink { CalendarView().environmentObject(st) } label: {
                    navRow("calendar", "Calendrier", "", .kBlue)
                }
                Divider().overlay(Color.primary.opacity(0.08))
                NavigationLink { SpeedConsoView().environmentObject(st) } label: {
                    navRow("speedometer", "Conso et vitesse", "", .kGold)
                }
                Divider().overlay(Color.primary.opacity(0.08))
                NavigationLink { ChargesView().environmentObject(st).environmentObject(r) } label: {
                    navRow("ev.charger.fill", "Recharges", st.curCharge != nil ? "en cours" : "\(st.charges.count)", .kTeal)
                }
                Divider().overlay(Color.primary.opacity(0.08))
                NavigationLink { BornesView().environmentObject(st) } label: {
                    navRow("chart.line.uptrend.xyaxis", "Comparer les bornes", "", .kTeal)
                }
                Divider().overlay(Color.primary.opacity(0.08))
                NavigationLink { BilansView().environmentObject(r) } label: {
                    navRow("chart.bar.fill", "Bilans mensuels", "", .kTeal)
                }
                Divider().overlay(Color.primary.opacity(0.08))
                NavigationLink { SOHView().environmentObject(r) } label: {
                    navRow("bolt.batteryblock.fill", "Batterie haute tension", "", .kGold)
                }
                Divider().overlay(Color.primary.opacity(0.08))
                NavigationLink { Batterie12View().environmentObject(r) } label: {
                    navRow("minus.plus.batteryblock.fill", "Batterie 12 V au repos", "", .kRed)
                }
                Divider().overlay(Color.primary.opacity(0.08))
                NavigationLink { EntretienView() } label: {
                    navRow("wrench.and.screwdriver.fill", "Carnet d'entretien", "", .kGold)
                }
                Divider().overlay(Color.primary.opacity(0.08))
                NavigationLink { MaKonaView().environmentObject(r).environmentObject(st) } label: {
                    navRow("car.fill", "Ma Kona", "", .kBlue)
                }
                Divider().overlay(Color.primary.opacity(0.08))
                NavigationLink { LogView().environmentObject(st) } label: {
                    navRow("list.bullet.rectangle.portrait.fill", "Journal", "\(st.log.count)", .kGold)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func navRow(_ i: String, _ t: String, _ v: String, _ c: Color) -> some View {
        HStack {
            Image(systemName: i).foregroundStyle(c).frame(width: 26)
            Text(t).font(.subheadline.weight(.semibold))
            Spacer()
            Text(v).font(.subheadline).foregroundStyle(Color.kSub)
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.kSub)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // MARK: Pied
    private var footer: some View {
        Card {
            VStack(spacing: 10) {
                row("paperplane.fill", "Envoi à Home Assistant", r.lastSent.map { $0.formatted(date: .omitted, time: .standard) } ?? "—")
                row("location.fill", "Position GPS", r.hasGPS ? "Active" : "En attente")
                row("point.topleft.down.to.point.bottomright.curvepath.fill", "Trajets synchronisés", r.tripSync.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                row("timer", "Cadences", "\(duree(cfgMain)) · \(duree(cfgExtra))")
            }
        }
        .onTapGesture { settings = true }
    }

    private func row(_ i: String, _ t: String, _ v: String) -> some View {
        HStack {
            Label(t, systemImage: i).font(.subheadline).foregroundStyle(Color.kSub)
            Spacer()
            Text(v).font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }
}
