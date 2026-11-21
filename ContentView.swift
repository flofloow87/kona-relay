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
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.14), Color.primary.opacity(0.03)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
    }
}

enum HomeCard: String, CaseIterable, Identifiable {
    case jauge, commandes, recharge, mesures, stationnement, historique, etat
    var id: String { rawValue }
    var label: String {
        ["jauge": "Voiture, charge et autonomie", "recharge": "Recharge en cours", "mesures": "Mesures", "commandes": "Commandes",
         "stationnement": "Emplacement", "historique": "Historique et analyses", "etat": "État du relais"][rawValue]!
    }
    var icon: String {
        ["jauge": "car.side.fill", "recharge": "ev.charger.fill", "mesures": "square.grid.2x2.fill", "commandes": "lock.fill",
         "stationnement": "location.fill", "historique": "chart.xyaxis.line", "etat": "dot.radiowaves.left.and.right"][rawValue]!
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
    @State private var revealed = false
    @AppStorage("cfgMain") private var cfgMain = 60
    @AppStorage("cfgExtra") private var cfgExtra = 300
    @AppStorage("homeOrder") private var homeOrder = ""
    @AppStorage("homeHidden") private var homeHidden = ""
    @AppStorage("theme") private var theme = "sombre"
    @AppStorage("accent") private var accent = "turquoise"
    @AppStorage("carColor") private var carColor = "gris"
    @AppStorage("carName") private var carName = "Kona"
    @StateObject private var meteo = Meteo.shared
    @Environment(\.scenePhase) private var phase

    private var cartes: [HomeCard] {
        HomeCard.ordre(homeOrder).filter { !homeHidden.split(separator: ",").contains(Substring($0.rawValue)) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    ForEach(Array(cartes.enumerated()), id: \.element) { i, c in
                        carte(c).modifier(Reveal(on: revealed, delay: 0.08 + Double(i) * 0.07))
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
            .background(KonaBackdrop(glow: lueur).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $settings) { SettingsView().environmentObject(r).environmentObject(st) }
            .overlay(alignment: .bottom) {
                if let t = r.toast {
                    Text(t).font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.3), value: r.toast)
            .task { await meteo.refresh() }
            .task { revealed = true }
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

    /// Halo du fond : vert en charge, bleu en roulant, bleu-vert sinon
    private var lueur: Color {
        if r.data?.charging == true { return .kTeal }
        if r.connected, ["D", "R"].contains(r.data?.gear ?? "") { return .kBlue }
        return Color(red: 0.32, green: 0.58, blue: 0.68)
    }

    // MARK: En-tête (réglages, nom, liaison)
    private var header: some View {
        HStack {
            Button { settings = true } label: {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(Color.primary.opacity(0.85))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PressStyle())
            Spacer()
            VStack(spacing: 6) {
                Text(carName.isEmpty ? "Kona" : carName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.rouge ? Color.kKona : Color.primary)
                linkPill
            }
            Spacer()
            Group {
                if r.eco {
                    Image(systemName: "leaf.fill").foregroundStyle(Color.kGold).symbolEffect(.pulse)
                } else {
                    Color.clear
                }
            }
            .frame(width: 44, height: 44)
        }
        .padding(.top, 4)
    }

    private var linkPill: some View {
        let viaHA = r.haSync.map { -$0.timeIntervalSinceNow < 180 } == true
        let (txt, col): (String, Color) = r.connected ? ("Bluetooth", .kBlue)
            : viaHA ? ("Maison", .kTeal)
            : r.status.hasPrefix("Recherche") ? ("Recherche", .kSub) : ("En attente", .kSub)
        return HStack(spacing: 6) {
            PulseDot(color: col, active: r.connected || viaHA)
            Text(txt.uppercased()).font(.caption2.weight(.semibold)).tracking(1.2)
        }
        .foregroundStyle(col)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(col.opacity(0.12), in: Capsule())
        .animation(.easeInOut(duration: 0.3), value: txt)
    }

    // MARK: Voiture, charge et autonomie
    private var hero: some View {
        let d = r.data
        let soc = d?.soc ?? d?.socBms
        let autonomie = meteo.range(soc) ?? st.range(soc)
        let (etat, couleur) = statut(d)
        return VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 14) {
                BatteryBar(soc: soc, charging: d?.charging == true)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(autonomie.map { "\($0)" } ?? "—")
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(autonomie ?? 0)))
                    Text("km").font(.title3.weight(.medium)).foregroundStyle(Color.kSub)
                }
            }
            .animation(.snappy, value: autonomie)
            Text(etat).font(.headline).foregroundStyle(couleur)
                .contentTransition(.interpolate)
                .animation(.snappy, value: etat)
            lecture(d).font(.footnote).foregroundStyle(Color.kSub)
            KonaCarScene(soc: soc, charging: d?.charging == true, gear: d?.gear, speed: d?.speed, live: r.connected,
                         paint: CarPaint(rawValue: carColor) ?? .gris, done: r.done, eco: r.eco)
                .padding(.horizontal, -16)
                .padding(.top, 4)
                .visualEffect { content, proxy in
                    let y = proxy.frame(in: .scrollView).minY
                    return content
                        .offset(y: y < 0 ? -y * 0.35 : 0)
                        .opacity(y < 0 ? Double(max(0.15, 1 + y / 380)) : 1)
                }
            heroStats(d, soc)
        }
    }

    private func statut(_ d: KonaData?) -> (String, Color) {
        guard let d else { return ("Aucune lecture", Color.kSub) }
        if d.charging { return ("En charge · \(fr(abs(d.kw ?? 0))) kW", Color.kTeal) }
        if r.connected {
            switch d.gear ?? "" {
            case "D": return ("En route" + (d.speed.map { " · \($0) km/h" } ?? ""), Color.kBlue)
            case "R": return ("Marche arrière", Color.kBlue)
            case "N": return ("Point mort", Color.kGold)
            default: break
            }
        }
        return ("Garée", Color.primary.opacity(0.85))
    }

    private func lecture(_ d: KonaData?) -> Text {
        guard let d else { return Text("Aucune lecture pour l'instant") }
        let src = r.connected ? " · Bluetooth" : d.src == "ha" ? " · via Home Assistant" : " · dernière connue"
        return Text("Lecture il y a ") + Text(d.date, style: .relative) + Text(src)
    }

    private func heroStats(_ d: KonaData?, _ soc: Double?) -> some View {
        var items: [(String, String, Color)] = []
        items.append((soc.map { "\(Int($0.rounded())) %" } ?? "—", "Charge", Color.soc(soc)))
        if let eta = r.chargeETA(d) {
            let fin = Date().addingTimeInterval(Double(eta.min) * 60).formatted(date: .omitted, time: .shortened)
            items.append((fin, "\(eta.cible) % atteints", Color.kTeal))
        } else {
            items.append((d?.kw.map { "\(fr(abs($0))) kW" } ?? "—", d?.charging == true ? "Charge" : "Puissance", Color.primary))
        }
        if r.connected, let v = d?.speed, ["D", "R"].contains(d?.gear ?? "") {
            items.append(("\(v) km/h", "Vitesse", Color.primary))
        } else {
            items.append((d?.gear ?? "—", "Rapport", Color.primary))
        }
        if let t = meteo.temp {
            items.append(("\(Int(t.rounded())) °C", "Météo du jour", Color.primary))
        }
        return StatStrip(items: items)
    }

    // MARK: Commandes (boutons ronds)
    private var actions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(KonaCommand.allCases) { c in
                    Button {
                        if c.needsConfirm { confirm = c } else { r.send(c) }
                    } label: {
                        CmdCircle(c: c, busy: r.busy == c, tint: color(c))
                    }
                    .buttonStyle(PressStyle(scale: 0.88))
                    .disabled(r.busy != nil)
                    .frame(maxWidth: .infinity)
                    .sensoryFeedback(.impact(weight: .medium), trigger: r.busy == c)
                }
            }
            HStack(spacing: 5) {
                Image(systemName: r.bleReady ? "antenna.radiowaves.left.and.right" : "house.fill")
                Text(r.bleReady ? "Bluetooth direct" : "Via Home Assistant, voiture au garage uniquement")
            }
            .font(.caption2).foregroundStyle(Color.kSub)
        }
    }

    private func color(_ c: KonaCommand) -> Color {
        switch c { case .deverrouiller: .kGold; case .verrouiller: .kTeal; case .feux: .kBlue; case .klaxon: .kRed }
    }

    // MARK: Recharge en cours (courbes)
    @ViewBuilder private var chargeCard: some View {
        if let c = st.curCharge, let sm = c.samples, sm.count >= 2 {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .lastTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("RECHARGE EN COURS", systemImage: "bolt.fill")
                                .font(.caption.weight(.semibold)).tracking(1.1).foregroundStyle(Color.kTeal)
                                .symbolEffect(.pulse)
                            Text("+\(fr(c.kwh)) kWh").font(.title2.weight(.semibold).monospacedDigit())
                                .contentTransition(.numericText())
                        }
                        Spacer()
                        Text("\(Int(c.end.timeIntervalSince(c.start) / 60)) min").font(.subheadline.monospacedDigit()).foregroundStyle(Color.kSub)
                    }
                    PowerChart(pts: sm.map { (m: Double($0.s) / 60, kw: $0.kw) }).frame(height: 110)
                    let socs = sm.compactMap { x in x.soc.map { (m: Double(x.s) / 60, soc: $0) } }
                    if socs.count >= 2 { SocChart(pts: socs).frame(height: 90) }
                }
            }
        }
    }

    // MARK: Mesures
    private var metrics: some View {
        let d = r.data
        let v12 = d?.v12d ?? d?.v12
        let items: [(String, String, Color)] = [
            (d?.volts.map { "\(fr($0, 0)) V" } ?? "—", "Tension HV", Color.primary),
            (d?.tMin.map { "\($0)–\(d?.tMax ?? $0) °C" } ?? "—", "Batterie", Color.primary),
            (v12.map { "\(fr($0, 2)) V" } ?? "—", d?.v12d != nil ? "12 V mesuré" : "12 V", (v12 ?? 13) < 12.2 ? Color.kRed : Color.primary),
            (d?.odo.map { "\($0.formatted())" } ?? "—", "Kilomètres", Color.primary),
        ]
        return Card { StatStrip(items: items) }
    }

    // MARK: Emplacement
    @ViewBuilder private var parkingCard: some View {
        if let pk = st.parking, !(r.connected && ["D", "R", "N"].contains(r.data?.gear ?? "")) {
            ParkingCard(pk: pk)
        }
    }

    // MARK: Historique et analyses (liste façon Tesla)
    private var history: some View {
        let d = r.data
        let v12 = d?.v12d ?? d?.v12
        return VStack(alignment: .leading, spacing: 0) {
            titre("Activité")
            menu(0, "map", "Trajets", st.curTrip != nil ? "Trajet en cours" : "\(st.trips.count) trajets · \(fr(st.conso)) kWh/100 km",
                 actif: st.curTrip != nil) { TripsView().environmentObject(st) }
            menu(1, "ev.charger", "Recharges", st.curCharge != nil ? "Recharge en cours" : "\(st.charges.count) sur borne · maison",
                 actif: st.curCharge != nil) { ChargesView().environmentObject(st).environmentObject(r) }
            menu(2, "calendar", "Calendrier", "Jours de route et de recharge") { CalendarView().environmentObject(st) }
            menu(3, "arrow.triangle.swap", "Trajets répétés", "Tes trajets habituels comparés") { RecurringView().environmentObject(st) }
            menu(4, "speedometer", "Conso et vitesse", "kWh/100 km selon la vitesse") { SpeedConsoView().environmentObject(st) }
            menu(5, "chart.line.uptrend.xyaxis", "Comparer les bornes", "Puissance selon le niveau de charge") { BornesView().environmentObject(st) }
            menu(6, "chart.bar", "Bilans mensuels", "Kilomètres, coûts et économies") { BilansView().environmentObject(r) }
            titre("Véhicule").padding(.top, 14)
            menu(7, "bolt.batteryblock", "Batterie haute tension", "État de santé et capacité") { SOHView().environmentObject(r) }
            menu(8, "minus.plus.batteryblock", "Batterie 12 V", v12.map { "\(fr($0, 2)) V · suivi au repos" } ?? "Suivi au repos",
                 alerte: (v12 ?? 13) < 12.2) { Batterie12View().environmentObject(r) }
            menu(9, "wrench.and.screwdriver", "Carnet d'entretien", "Révisions, pneus, factures") { EntretienView() }
            menu(10, "car", "Ma Kona", "Véhicule, logiciels, codes défaut") { MaKonaView().environmentObject(r).environmentObject(st) }
            menu(11, "list.bullet.rectangle.portrait", "Journal", "\(st.log.count) événements") { LogView().environmentObject(st) }
        }
    }

    private func titre(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(Color.kSub)
            .padding(.leading, 4).padding(.bottom, 2)
    }

    private func menu<D: View>(_ i: Int, _ icon: String, _ t: String, _ sub: String, actif: Bool = false, alerte: Bool = false,
                               @ViewBuilder _ dest: () -> D) -> some View {
        let page = dest()
        let tint: Color = alerte ? .kRed : (actif ? .kTeal : Color.primary.opacity(0.9))
        return NavigationLink { page.konaPage() } label: {
            TeslaRow(icon: icon, title: t, sub: sub, tint: tint, actif: actif)
        }
        .buttonStyle(RowStyle())
        .opacity(revealed ? 1 : 0)
        .offset(x: revealed ? 0 : 24)
        .animation(.spring(duration: 0.55, bounce: 0.2).delay(0.35 + Double(i) * 0.035), value: revealed)
    }

    // MARK: État du relais
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

// MARK: - Éléments de l'écran d'accueil

/// Fond façon Tesla : halo bleu-vert en haut qui dérive lentement, noir en bas
struct KonaBackdrop: View {
    var glow = Color(red: 0.32, green: 0.58, blue: 0.68)
    var animated = true
    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            LinearGradient(colors: [.kBg2, .kBg1, .kBg1], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [glow.opacity(Theme.clair ? 0.22 : 0.38), glow.opacity(0)],
                           center: .top, startRadius: 10, endRadius: 460)
                .scaleEffect(drift ? 1.18 : 0.95, anchor: .top)
                .offset(x: drift ? 36 : -36, y: -40)
        }
        .animation(.easeInOut(duration: 1.5), value: glow)
        .task {
            guard animated, !reduce else { return }
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

extension View {
    /// Pages secondaires : même fond que l'accueil
    func konaPage() -> some View {
        scrollContentBackground(.hidden)
            .background(KonaBackdrop(animated: false).ignoresSafeArea())
    }
}

/// Apparition en fondu et glissement, décalée selon la position
struct Reveal: ViewModifier {
    let on: Bool
    let delay: Double
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 20)
            .animation(.spring(duration: 0.65, bounce: 0.2).delay(delay), value: on)
    }
}

struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.9
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.45), value: configuration.isPressed)
    }
}

struct RowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
                    .padding(.horizontal, -6)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

/// Ligne de menu : icône, titre en capitales, sous-titre gris, chevron
struct TeslaRow: View {
    let icon: String
    let title: String
    let sub: String
    let tint: Color
    var actif = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 19, weight: .medium)).foregroundStyle(tint)
                .frame(width: 28)
                .symbolEffect(.pulse, isActive: actif)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(.subheadline.weight(.semibold)).tracking(0.9)
                    .foregroundStyle(Color.primary.opacity(0.92))
                if !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(actif ? tint : Color.kSub).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.kSub)
        }
        .padding(.vertical, 12).padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

/// Batterie horizontale : remplissage animé, reflet qui défile en charge
struct BatteryBar: View {
    let soc: Double?
    let charging: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let f = max(0, min(1, (soc ?? 0) / 100))
        let col = Color.soc(soc)
        HStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.4), lineWidth: 1.5)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(col.gradient)
                        .overlay { if charging && !reduce { Shimmer() } }
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        .frame(width: max(3, g.size.width * CGFloat(shown ? f : 0)))
                        .shadow(color: col.opacity(charging ? 0.7 : 0.3), radius: charging ? 6 : 3)
                }
                .padding(3.5)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .symbolEffect(.pulse)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 66, height: 30)
            RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.4)).frame(width: 3.5, height: 11)
        }
        .animation(.spring(duration: 0.9, bounce: 0.15), value: f)
        .animation(.spring(duration: 0.4), value: charging)
        .task {
            withAnimation(reduce ? nil : Animation.spring(duration: 1.4, bounce: 0.12).delay(0.4)) { shown = true }
        }
        .accessibilityElement()
        .accessibilityLabel(soc.map { "Batterie \(Int($0.rounded())) %" } ?? "Batterie")
    }
}

/// Reflet lumineux qui balaie la batterie en charge
struct Shimmer: View {
    @State private var go = false
    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width * 0.5, 12)
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: w)
                .offset(x: go ? g.size.width + 12 : -w)
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { go = true } }
    }
}

/// Point de liaison avec onde qui s'étend
struct PulseDot: View {
    let color: Color
    let active: Bool
    var body: some View {
        ZStack {
            if active {
                Circle().stroke(color, lineWidth: 1.5)
                    .phaseAnimator([false, true]) { content, on in
                        content.scaleEffect(on ? 2.6 : 1).opacity(on ? 0 : 0.8)
                    } animation: { on in
                        on ? .easeOut(duration: 1.6) : .linear(duration: 0.01)
                    }
            }
            Circle().fill(color)
        }
        .frame(width: 7, height: 7)
    }
}

/// Bandeau de valeurs séparées par de fins traits
struct StatStrip: View {
    let items: [(String, String, Color)]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                if i > 0 { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 30) }
                VStack(spacing: 3) {
                    Text(items[i].0).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(items[i].2)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Text(items[i].1).font(.caption2).foregroundStyle(Color.kSub).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.snappy, value: items.map { $0.0 })
    }
}

/// Bouton rond de commande ; arc qui tourne en attendant la réponse
struct CmdCircle: View {
    let c: KonaCommand
    let busy: Bool
    let tint: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(Color.primary.opacity(busy ? 0 : 0.22), lineWidth: 1.2)
                if busy { Spinner(tint: tint) }
                Image(systemName: c.icon).font(.system(size: 22, weight: .medium))
                    .foregroundStyle(busy ? tint : Color.primary.opacity(0.9))
                    .symbolEffect(.bounce, value: busy)
            }
            .frame(width: 64, height: 64)
            .shadow(color: tint.opacity(busy ? 0.55 : 0), radius: 14)
            Text(c.label).font(.caption.weight(.medium)).foregroundStyle(busy ? tint : Color.kSub)
        }
        .animation(.easeInOut(duration: 0.25), value: busy)
    }
}

struct Spinner: View {
    let tint: Color
    @State private var spin = false
    var body: some View {
        Circle().trim(from: 0, to: 0.3)
            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
    }
}

/// Emplacement de la voiture garée : adresse, carte, itinéraire à pied
struct ParkingCard: View {
    let pk: Parking
    @State private var adresse: String?

    var body: some View {
        let c = CLLocationCoordinate2D(latitude: pk.lat, longitude: pk.lon)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "location.north.fill").font(.system(size: 18, weight: .medium)).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("EMPLACEMENT").font(.subheadline.weight(.semibold)).tracking(0.9)
                    Text(adresse ?? "Garée ici").font(.caption).foregroundStyle(Color.kSub).lineLimit(1)
                }
                Spacer()
                (Text("il y a ") + Text(pk.date, style: .relative)).font(.caption).foregroundStyle(Color.kSub)
            }
            .padding(.horizontal, 4)
            Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 350, longitudinalMeters: 350))) {
                Marker("Kona", systemImage: "car.fill", coordinate: c).tint(Color.kRed)
                UserAnnotation()
            }
            .mapStyle(.standard(emphasis: .muted))
            .id(pk.date)
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .overlay(alignment: .bottomTrailing) {
                Button {
                    let it = MKMapItem(placemark: MKPlacemark(coordinate: c)); it.name = "Kona"
                    it.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                } label: {
                    Label("Y aller", systemImage: "figure.walk").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(PressStyle())
                .padding(10)
            }
        }
        .task(id: pk.date) {
            let a = await Self.geocode(pk)
            withAnimation(.easeInOut) { adresse = a }
        }
    }

    static func geocode(_ pk: Parking) async -> String? {
        let l = CLLocation(latitude: pk.lat, longitude: pk.lon)
        guard let p = (try? await CLGeocoder().reverseGeocodeLocation(l))?.first else { return nil }
        let rue = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let s = [rue.isEmpty ? nil : rue, p.locality].compactMap { $0 }.joined(separator: ", ")
        return s.isEmpty ? nil : s
    }
}
