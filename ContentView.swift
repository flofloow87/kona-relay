import MapKit
import SwiftUI


func fr(_ v: Double?, _ d: Int = 1) -> String {
    guard let v else { return "—" }
    return String(format: "%.\(d)f", v).replacingOccurrences(of: ".", with: ",")
}

func duree(_ s: Int) -> String {
    s < 60 ? "\(s) s" : s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s"
}

extension BLERelay {
    /// Lecture récente : Bluetooth en direct ou moins de 15 min. Sinon, ni charge ni trajet animés.
    func frais(_ now: Date) -> Bool {
        guard let d = data else { return false }
        return connected || now.timeIntervalSince(d.date) < 900
    }
    func enCharge(_ now: Date) -> Bool { data?.charging == true && frais(now) }
    var roule: Bool { connected && ["D", "R"].contains(data?.gear ?? "") }
}

// MARK: - Onglets
enum Onglet: String, CaseIterable, Identifiable {
    case voiture, recharge, trajets, sante, plus
    var id: String { rawValue }
    var label: String {
        switch self {
        case .voiture: "Voiture"
        case .recharge: "Recharge"
        case .trajets: "Trajets"
        case .sante: "Santé"
        case .plus: "Plus"
        }
    }
    var icon: String {
        switch self {
        case .voiture: "car"
        case .recharge: "bolt"
        case .trajets: "map"
        case .sante: "heart.text.square"
        case .plus: "ellipsis.circle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var r: BLERelay
    @EnvironmentObject var st: Store
    @State private var sel: Onglet = .voiture
    @State private var vus: Set<Onglet> = [.voiture]
    @State private var settings = false
    @State private var racine: [Onglet: Int] = [:]       // réappui sur l'onglet actif : page recréée (retour en haut)
    @State private var barre: CGFloat = 76               // hauteur mesurée de la barre d'onglets
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("theme") private var theme = "sombre"
    @AppStorage("accent") private var accent = "turquoise"
    @AppStorage("carColor") private var carColor = "gris"
    @AppStorage("carPhoto") private var carPhoto = true
    @StateObject private var meteo = Meteo.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TimelineView(.everyMinute) { tl in
            ZStack {
                ForEach(Onglet.allCases) { o in
                    // chaque onglet garde sa navigation ; créé à la première visite
                    if vus.contains(o) {
                        page(o, now: tl.date)
                            .id("\(o.rawValue)-\(racine[o, default: 0])")
                            .opacity(sel == o ? 1 : 0)
                            .scaleEffect(sel == o || reduce ? 1 : 0.985)
                            .allowsHitTesting(sel == o)
                            .accessibilityHidden(sel != o)
                    }
                }
            }
            // Barre flottante posée par-dessus les pages. La marge du bas est réservée dans chaque zone qui défile
            // (y compris les pages ouvertes depuis un onglet) : safeAreaInset ne traverse pas toujours NavigationStack.
            .contentMargins(.bottom, barre + 12, for: .scrollContent)
            .overlay(alignment: .bottom) {
                VStack(spacing: 12) {
                    if let t = r.toast {
                        Text(t).font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                            .padding(.horizontal, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                    }
                    KonaTabBar(sel: sel, badges: badges(tl.date)) { o in
                        if o == sel {
                            // deuxième appui : retour à la première page de l'onglet, en haut
                            withAnimation(.snappy(duration: 0.3)) { racine[o, default: 0] += 1 }
                        } else {
                            vus.insert(o)
                            withAnimation(.snappy(duration: 0.3)) { sel = o }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barre = $0 }
                }
            }
        }
        .background(KonaBackdrop().ignoresSafeArea())
        .animation(.spring(duration: 0.4, bounce: 0.3), value: r.toast)
        .onChange(of: r.toast) { _, t in
            if let t { AccessibilityNotification.Announcement(t).post() }
        }
        .sheet(isPresented: $settings) { SettingsView().environmentObject(r).environmentObject(st) }
        .task { await meteo.refresh() }
        .task { CarPaint.partager(carColor); KonaVisuel.partager(carPhoto) }
        .onChange(of: carColor) { _, v in CarPaint.partager(v) }
        .onChange(of: carPhoto) { _, v in KonaVisuel.partager(v) }
        .onChange(of: phase, initial: true) { _, p in
            if p == .active { r.startHAPolling() } else { r.stopHAPolling(); if p == .background { BLERelay.scheduleHA() } }
        }
        .preferredColorScheme(Theme.scheme)
        .tint(Theme.accent)
        .id(theme + accent)
    }

    @ViewBuilder private func page(_ o: Onglet, now: Date) -> some View {
        switch o {
        case .voiture: VoiturePage(now: now, actif: sel == .voiture)
        case .recharge: RechargePage(now: now)
        case .trajets: TrajetsPage()
        case .sante: SantePage()
        case .plus: PlusPage { settings = true }
        }
    }

    /// Pastilles de la barre : charge en cours, trajet en cours, 12 V bas, sauvegardes en attente
    private func badges(_ now: Date) -> [Onglet: Pastille] {
        var b: [Onglet: Pastille] = [:]
        if r.enCharge(now) { b[.recharge] = Pastille(couleur: .kTeal, texte: "en charge") }
        if st.curTrip != nil { b[.trajets] = Pastille(couleur: .kBlue, texte: "trajet en cours") }
        if let v = r.data?.v12d ?? r.data?.v12, v < 12.2 { b[.sante] = Pastille(couleur: .kRed, texte: "batterie 12 V faible") }
        if r.pendingCount > 0 { b[.plus] = Pastille(couleur: .kGold, texte: "\(r.pendingCount) sauvegardes en attente") }
        return b
    }
}

/// Pastille d'onglet : couleur affichée, texte lu par VoiceOver
struct Pastille: Equatable {
    let couleur: Color
    let texte: String
}

// MARK: - Barre d'onglets flottante (comme le tableau de bord Home Assistant)
struct KonaTabBar: View {
    let sel: Onglet
    let badges: [Onglet: Pastille]
    let choisir: (Onglet) -> Void
    @Namespace private var ns
    @State private var taps: [Onglet: Int] = [:]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Onglet.allCases) { o in
                Button {
                    taps[o, default: 0] += 1
                    choisir(o)
                } label: {
                    item(o)
                }
                .buttonStyle(PressStyle(scale: 0.92))
                .accessibilityLabel(o.label)
                .accessibilityValue(badges[o]?.texte ?? "")
                .accessibilityAddTraits(sel == o ? .isSelected : [])
                .accessibilityShowsLargeContentViewer { Label(o.label, systemImage: o.icon) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Onglets")
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.kBg1.opacity(Theme.clair ? 0.15 : 0.45)))
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)   // comme la barre iOS : loupe au lieu de grossir
        .sensoryFeedback(.selection, trigger: sel)
    }

    private func item(_ o: Onglet) -> some View {
        let on = sel == o
        return VStack(spacing: 4) {
            Image(systemName: o.icon)
                .font(.title3.weight(on ? .semibold : .regular))
                .symbolEffect(.bounce, value: taps[o, default: 0])
                .overlay(alignment: .topTrailing) {
                    if let p = badges[o] {
                        Circle().fill(p.couleur).frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color.kBg1, lineWidth: 1.5))
                            .offset(x: 6, y: -4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(height: 24)
            Text(o.label).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(on ? Color.primary : Color.kSub)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background {
            if on {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.accent.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.accent.opacity(0.25)))
                    .matchedGeometryEffect(id: "pastille", in: ns)
            }
        }
        .contentShape(Rectangle())
        .animation(.spring(duration: 0.3), value: badges[o] != nil)
    }
}

// MARK: - Onglet Voiture
struct VoiturePage: View {
    @EnvironmentObject var r: BLERelay
    @EnvironmentObject var st: Store
    @StateObject private var meteo = Meteo.shared
    let now: Date
    let actif: Bool
    @AppStorage("carColor") private var carColor = "gris"
    @State private var confirm: KonaCommand?
    @State private var shown = false
    @State private var visible: CGFloat = 0          // hauteur visible de la page (sans barre d'état ni barre d'onglets)
    @ScaledMetric(relativeTo: .largeTitle) private var tailleAuto: CGFloat = 48
    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        let charge = r.enCharge(now)
        NavigationStack {
            ScrollView {
                // Tout tient sur un écran : la carte prend la place libre, la voiture rétrécit si besoin.
                // Si ça ne suffit pas (très grande police, courbe de charge en plus), la page défile.
                PleinePage(hauteur: max(0, visible - 16), espace: dts.isAccessibilitySize ? 20 : 14) {
                    heroHaut.modifier(Reveal(on: shown, delay: 0))
                    voiture.modifier(Reveal(on: shown, delay: 0.06))
                        .layoutValue(key: PleinePage.Role.self, value: .voiture(min: 150))
                    heroStats(r.data, r.data?.soc ?? r.data?.socBms).modifier(Reveal(on: shown, delay: 0.1))
                    actions.modifier(Reveal(on: shown, delay: 0.16))
                    if charge, let c = st.curCharge, (c.samples?.count ?? 0) >= 2 {
                        ChargeCurveCard(c: c).modifier(Reveal(on: shown, delay: 0.24))
                    }
                    if let pk = st.parking, !r.roule {
                        ParkingCard(pk: pk).modifier(Reveal(on: shown, delay: 0.24))
                            .layoutValue(key: PleinePage.Role.self, value: .carte(min: dts.isAccessibilitySize ? 170 : 120))
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            // containerSize : zone visible, déjà sans barre d'état ni barre d'onglets (marges de contenu)
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, h in visible = h }
            .konaScroll(glow: lueur)
            .refreshable { await r.fetchHA(); await meteo.refresh(force: true) }
            .task { shown = true }
            .confirmationDialog(confirm.map { "\($0.label) la Kona ?" } ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                if let c = confirm { Button(c.label) { r.send(c) } }
                Button("Annuler", role: .cancel) {}
            }
        }
    }

    /// Halo du fond : vert en charge, bleu en roulant, bleu-vert sinon
    private var lueur: Color {
        if r.enCharge(now) { return .kTeal }
        if r.roule { return .kBlue }
        return KonaBackdrop.defaut
    }

    // MARK: Charge et autonomie, état, lecture
    private var heroHaut: some View {
        let d = r.data
        let soc = d?.soc ?? d?.socBms
        let charge = r.enCharge(now)
        let autonomie = meteo.range(soc) ?? st.range(soc)
        let (etat, couleur) = statut(d)
        return VStack(spacing: 6) {
            // état au centre, liaison avec la voiture en haut à droite
            ZStack {
                Text(etat).font(.headline).foregroundStyle(couleur)
                    .contentTransition(.interpolate)
                    .animation(.snappy, value: etat)
                    .padding(.horizontal, 44)
                HStack { Spacer(); liaison }
            }
            HStack(alignment: .center, spacing: 14) {
                BatteryBar(soc: soc, charging: charge)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(autonomie.map { "\($0)" } ?? "—")
                        .font(.system(size: min(tailleAuto, 84), weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(autonomie ?? 0)))
                    Text("km").font(.title3.weight(.medium)).foregroundStyle(Color.kSub)
                }
            }
            .animation(.snappy, value: autonomie)
        }
    }

    /// Liaison avec la voiture : Bluetooth direct, WiFi maison (lecture via Home Assistant) ou hors ligne
    private var liaison: some View {
        let viaHA = r.haSync.map { now.timeIntervalSince($0) < 180 } == true
        let (icone, col, txt): (String, Color, String) =
            r.connected ? ("antenna.radiowaves.left.and.right", .kBlue, "Bluetooth")
            : viaHA ? ("wifi", .kTeal, "WiFi maison")
            : ("wifi.slash", Color.kSub, "Hors ligne")
        return Image(systemName: icone)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(col)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, isActive: !r.connected && !viaHA && r.status.hasPrefix("Recherche"))
            .frame(width: 34, height: 34)
            .background(col.opacity(0.14), in: Circle())
            .animation(.easeInOut(duration: 0.3), value: icone)
            .accessibilityElement()
            .accessibilityLabel("Connexion")
            .accessibilityValue(txt)
    }

    // MARK: Voiture animée
    private var voiture: some View {
        let d = r.data
        return VStack(spacing: 2) {
            KonaCarScene(soc: d?.soc ?? d?.socBms, charging: r.enCharge(now), gear: d?.gear, speed: d?.speed, live: r.connected,
                         paint: CarPaint(rawValue: carColor) ?? .gris, done: r.done, eco: r.eco, actif: actif)
                .padding(.horizontal, -16)
            lecture(d).font(.footnote).foregroundStyle(Color.kSub)
        }
    }

    private func statut(_ d: KonaData?) -> (String, Color) {
        guard let d else { return ("Aucune lecture", Color.kSub) }
        if d.charging {
            return r.frais(now) ? ("En charge · \(fr(abs(d.kw ?? 0))) kW", Color.kTeal) : ("En charge à la dernière lecture", Color.kSub)
        }
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

    /// Date de la dernière lecture (sous la voiture), feuille en mode économie
    private func lecture(_ d: KonaData?) -> Text {
        let eco = r.eco ? Text(Image(systemName: "leaf.fill")).foregroundColor(.kGold) + Text(" ") : Text("")
        guard let d else { return eco + Text("Aucune lecture pour l'instant") }
        let heure = d.date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(d.date) {
            return eco + Text("Dernière lecture à \(heure) · il y a \(d.date, style: .relative)")
        }
        return eco + Text("Dernière lecture le \(d.date.formatted(.dateTime.day().month(.abbreviated))) à \(heure)")
    }

    private func heroStats(_ d: KonaData?, _ soc: Double?) -> some View {
        var items: [(String, String, Color)] = []
        items.append((soc.map { "\(Int($0.rounded())) %" } ?? "—", "Charge", Color.soc(soc)))
        if r.frais(now), let eta = r.chargeETA(d) {
            let fin = now.addingTimeInterval(Double(eta.min) * 60).formatted(date: .omitted, time: .shortened)
            items.append((fin, "\(eta.cible) % atteints", Color.kTeal))
        } else {
            items.append((d?.kw.map { "\(fr(abs($0))) kW" } ?? "—", r.enCharge(now) ? "Charge" : "Puissance", Color.primary))
        }
        if r.roule, let v = d?.speed {
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: dts.isAccessibilitySize ? 2 : 4), spacing: 16) {
                ForEach(KonaCommand.allCases) { c in
                    Button {
                        if c.needsConfirm { confirm = c } else { r.send(c) }
                    } label: {
                        CmdCircle(c: c, busy: r.busy == c, tint: color(c))
                    }
                    .buttonStyle(PressStyle(scale: 0.88))
                    .disabled(r.busy != nil)
                    .opacity(r.busy != nil && r.busy != c ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.2), value: r.busy)
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
}

// MARK: - Empilement plein écran de l'onglet Voiture
/// Empile les blocs comme un VStack centré, en visant exactement `hauteur` :
/// la place libre va à la carte, et s'il en manque la voiture rétrécit (jusqu'à son minimum).
/// Si tout ne tient toujours pas, la pile dépasse et la page défile.
struct PleinePage: Layout {
    var hauteur: CGFloat
    var espace: CGFloat

    enum Souple: Equatable { case voiture(min: CGFloat), carte(min: CGFloat) }
    struct Role: LayoutValueKey { static let defaultValue: Souple? = nil }

    private func hauteurs(_ largeur: CGFloat?, _ vues: Subviews) -> [CGFloat] {
        var h = vues.map { $0.sizeThatFits(ProposedViewSize(width: largeur, height: nil)).height }
        guard hauteur > 0 else { return h }          // hauteur visible pas encore mesurée
        let total = h.reduce(0, +) + espace * CGFloat(max(vues.count - 1, 0))
        if total < hauteur, let i = vues.firstIndex(where: { if case .carte = $0[Role.self] { true } else { false } }) {
            h[i] += hauteur - total
        } else if total > hauteur, let i = vues.firstIndex(where: { if case .voiture = $0[Role.self] { true } else { false } }),
                  case let .voiture(mini)? = vues[i][Role.self] {
            h[i] = max(mini, h[i] - (total - hauteur))
        }
        return h
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let h = hauteurs(proposal.width, subviews)
        return CGSize(width: proposal.width ?? 0, height: h.reduce(0, +) + espace * CGFloat(max(subviews.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let h = hauteurs(bounds.width, subviews)
        var y = bounds.minY
        for (i, v) in subviews.enumerated() {
            v.place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: ProposedViewSize(width: bounds.width, height: h[i]))
            y += h[i] + espace
        }
    }
}

// MARK: - Éléments communs

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

/// Fond façon Tesla : halo bleu-vert en haut (qui dérive lentement sur l'onglet Voiture), noir en bas
/// Fond fixe : dégradé et halo en haut, dont seule la couleur change (charge, route)
struct KonaBackdrop: View {
    static let defaut = Color(red: 0.32, green: 0.58, blue: 0.68)
    var glow = KonaBackdrop.defaut

    var body: some View {
        ZStack {
            LinearGradient(colors: [.kBg2, .kBg1, .kBg1], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [glow.opacity(Theme.clair ? 0.22 : 0.38), glow.opacity(0)],
                           center: .top, startRadius: 10, endRadius: 460)
                .scaleEffect(1.06, anchor: .top)
                .offset(y: -40)
        }
        .animation(.easeInOut(duration: 1.5), value: glow)
    }
}

extension View {
    /// Pages secondaires : même fond que l'accueil, lignes de liste translucides
    func konaPage() -> some View {
        scrollContentBackground(.hidden)
            .background(KonaBackdrop().ignoresSafeArea())
    }

    /// Pages d'onglet : défilement sans barre de navigation, fond Kona
    func konaScroll(glow: Color = KonaBackdrop.defaut) -> some View {
        scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
            .background(KonaBackdrop(glow: glow).ignoresSafeArea())
    }

    /// Lignes de liste translucides sur le fond Kona
    func konaRows() -> some View {
        listRowBackground(Color.primary.opacity(0.06))
    }
}

/// Apparition en fondu et glissement, décalée selon la position
struct Reveal: ViewModifier {
    let on: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on || reduce ? 0 : 20)
            .animation(reduce ? .easeOut(duration: 0.25) : .spring(duration: 0.65, bounce: 0.2).delay(delay), value: on)
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

/// Titre centré d'un onglet
struct PageTitle: View {
    let titre: String
    var sous = ""
    var body: some View {
        VStack(spacing: 4) {
            Text(titre).font(.title2.weight(.semibold))
            if !sous.isEmpty {
                Text(sous).font(.footnote).foregroundStyle(Color.kSub).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }
}

/// Groupe de lignes avec petit titre en capitales
struct MenuSection<Content: View>: View {
    var titre = ""
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !titre.isEmpty {
                Text(titre.uppercased()).font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(Color.kSub)
                    .padding(.leading, 4).padding(.bottom, 2)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Ligne de menu qui ouvre une page
struct MenuLink<D: View>: View {
    let icon: String
    let title: String
    let sub: String
    var tint: Color = Color.primary.opacity(0.9)
    var actif = false
    @ViewBuilder let dest: () -> D
    var body: some View {
        NavigationLink { dest().konaPage() } label: {
            TeslaRow(icon: icon, title: title, sub: sub, tint: tint, actif: actif)
        }
        .buttonStyle(RowStyle())
    }
}

/// Ligne de menu : icône, titre en capitales, sous-titre gris, chevron
struct TeslaRow: View {
    let icon: String
    let title: String
    let sub: String
    let tint: Color
    var actif = false
    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.title3.weight(.medium)).foregroundStyle(tint)
                .frame(width: 28)
                .symbolEffect(.pulse, isActive: actif)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(.subheadline.weight(.semibold)).tracking(0.9)
                    .foregroundStyle(Color.primary.opacity(0.92))
                if !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(actif ? tint : Color.kSub).lineLimit(dts.isAccessibilitySize ? 3 : 1)
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

/// Reflet lumineux qui balaie une batterie en charge
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

/// Bandeau de valeurs séparées par de fins traits ; liste lisible aux grandes tailles de texte
struct StatStrip: View {
    let items: [(String, String, Color)]
    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        Group {
            if dts.isAccessibilitySize {
                VStack(spacing: 10) {
                    ForEach(items.indices, id: \.self) { i in
                        if i > 0 { Divider().overlay(Color.primary.opacity(0.08)) }
                        HStack(alignment: .firstTextBaseline) {
                            Text(items[i].1).font(.subheadline).foregroundStyle(Color.kSub)
                            Spacer(minLength: 8)
                            Text(items[i].0).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(items[i].2)
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(items[i].1)
                        .accessibilityValue(items[i].0)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { i in
                        if i > 0 { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 30) }
                        VStack(spacing: 3) {
                            Text(items[i].0).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(items[i].2)
                                .lineLimit(1).minimumScaleFactor(0.75)
                                .contentTransition(.numericText())
                            Text(items[i].1).font(.caption2).foregroundStyle(Color.kSub).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(items[i].1)
                        .accessibilityValue(items[i].0)
                    }
                }
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
    @ScaledMetric(relativeTo: .title2) private var d: CGFloat = 64

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(Color.primary.opacity(busy ? 0 : 0.22), lineWidth: 1.2)
                if busy { Spinner(tint: tint) }
                Image(systemName: c.icon).font(.title2.weight(.medium))
                    .foregroundStyle(busy ? tint : Color.primary.opacity(0.9))
                    .symbolEffect(.bounce, value: busy)
            }
            .frame(width: min(d, 92), height: min(d, 92))
            .shadow(color: tint.opacity(busy ? 0.55 : 0), radius: 14)
            Text(c.label).font(.caption.weight(.medium)).foregroundStyle(busy ? tint : Color.kSub)
        }
        .animation(.easeInOut(duration: 0.25), value: busy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(c.label)
        .accessibilityValue(busy ? "en cours" : "")
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

/// Courbes de la recharge en cours
struct ChargeCurveCard: View {
    let c: Charge
    var body: some View {
        let sm = c.samples ?? []
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

/// Emplacement de la voiture garée : adresse, carte, itinéraire à pied
struct ParkingCard: View {
    let pk: Parking
    @State private var adresse: String?
    @State private var taille: CGSize = .zero         // taille de la carte

    var body: some View {
        let c = CLLocationCoordinate2D(latitude: pk.lat, longitude: pk.lon)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "location.north.fill").font(.body.weight(.medium)).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("EMPLACEMENT").font(.subheadline.weight(.semibold)).tracking(0.9)
                    Text(adresse ?? "Garée ici").font(.caption).foregroundStyle(Color.kSub).lineLimit(1)
                }
                Spacer()
                Text("il y a \(pk.date, style: .relative)").font(.caption).foregroundStyle(Color.kSub)
            }
            .padding(.horizontal, 4)
            // carte fixe : le défilement de la page n'est pas capturé ; un appui ouvre Plans
            // La hauteur de la carte suit la place libre de l'onglet Voiture. MapKit garde le zoom calculé à la création :
            // la carte n'est créée qu'à sa taille définitive, et recréée si cette taille change.
            Color.primary.opacity(0.05)
                .frame(minHeight: 120, idealHeight: 120, maxHeight: .infinity)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { taille = $0 }
                .overlay {
                    if taille.width > 0 && taille.height >= 60 {
                        Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 350, longitudinalMeters: 350)),
                            interactionModes: []) {
                            Marker("Kona", systemImage: "car.fill", coordinate: c).tint(Color.kRed)
                            UserAnnotation()
                        }
                        .mapStyle(.standard(emphasis: .muted))
                        .id("\(pk.date.timeIntervalSince1970)-\(Int(taille.width))x\(Int(taille.height))")
                    }
                }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .contentShape(Rectangle())
            .onTapGesture { ouvrir(c, aPied: false) }
            .accessibilityElement()
            .accessibilityLabel("Carte de l'emplacement")
            .accessibilityHint("Ouvre Plans")
            .accessibilityAddTraits(.isButton)
            .overlay(alignment: .bottomTrailing) {
                Button {
                    ouvrir(c, aPied: true)
                } label: {
                    Label("Y aller", systemImage: "figure.walk").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
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

    private func ouvrir(_ c: CLLocationCoordinate2D, aPied: Bool) {
        let it = MKMapItem(placemark: MKPlacemark(coordinate: c)); it.name = "Kona"
        it.openInMaps(launchOptions: aPied ? [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking] : nil)
    }

    static func geocode(_ pk: Parking) async -> String? {
        let l = CLLocation(latitude: pk.lat, longitude: pk.lon)
        guard let p = (try? await CLGeocoder().reverseGeocodeLocation(l))?.first else { return nil }
        let rue = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let s = [rue.isEmpty ? nil : rue, p.locality].compactMap { $0 }.joined(separator: ", ")
        return s.isEmpty ? nil : s
    }
}
