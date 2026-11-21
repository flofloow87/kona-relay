import SwiftUI

// MARK: - Scène de l'écran d'accueil : Kona de profil dessinée et animée
/// Arrivée en roulant, reflet qui balaie la carrosserie, roues et route en mouvement en roulant,
/// câble et batterie lumineux en charge, phares / clignotants / klaxon quand l'ESP32 confirme une commande.
/// Ne redessine que si quelque chose bouge (garée : seulement pendant le reflet), et jamais hors écran.
struct KonaCarScene: View {
    var soc: Double?
    var charging: Bool
    var gear: String?
    var speed: Int?
    var live: Bool
    var paint: CarPaint
    var done: CmdDone?
    var eco: Bool
    var actif = true                // onglet affiché
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.scenePhase) private var phase
    @AppStorage("carPhoto") private var carPhoto = true
    @State private var debut: Date?
    @State private var visible = true

    private var roule: Bool { live && (gear == "D" || gear == "R") && (speed ?? 1) > 0 }

    var body: some View {
        let finArrivee = (debut ?? Date()).addingTimeInterval(1.4)
        let finCommande = done.map { $0.date.addingTimeInterval(2.7) } ?? .distantPast
        let vivant = actif && visible && phase == .active
        // 30 images/s en roulant (roues, route), 20 en recharge (câble, halo) : assez fluide et plus léger
        let horaire = CarSchedule(actif: vivant,
                                  continu: !reduce && (roule || charging),
                                  jusqua: max(finArrivee, finCommande),
                                  dt: reduce ? 0.25 : (eco ? 1.0 / 12 : (roule ? 1.0 / 30 : 1.0 / 20)),
                                  reflet: false)
        TimelineView(horaire) { tl in
            Canvas { ctx, size in
                if carPhoto, let img = KonaPhoto.image {
                    PhotoRender(image: img, size: size, now: tl.date, debut: debut, charging: charging, gear: gear,
                                speed: speed, roule: roule, live: live, done: done, motion: !reduce).draw(ctx)
                } else {
                    CarRender(size: size, now: tl.date, debut: debut, soc: soc, charging: charging, gear: gear,
                              speed: speed, roule: roule, live: live, paint: paint, done: done, motion: !reduce).draw(ctx)
                }
            }
        }
        // Nouvelle horloge à chaque reprise (retour dans l'app, dans l'onglet, fin d'une alerte) : sans ça,
        // une animation interrompue (arrivée, commande) restait figée sur l'image où elle s'était arrêtée.
        .id(vivant)
        .aspectRatio(2.0, contentMode: .fit)
        .onAppear { if debut == nil { debut = Date() } }
        .onScrollVisibilityChange(threshold: 0.02) { visible = $0 }
        .accessibilityElement()
        .accessibilityLabel("Kona")
        .accessibilityValue([soc.map { "\(Int($0.rounded())) %" }, charging ? "en charge" : roule ? "en route" : "garée"]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

/// Dates d'affichage : continues en roulant / en charge / pendant une animation ponctuelle,
/// sinon seulement pendant le reflet (1,7 s toutes les 7 s). Rien quand la scène n'est pas visible.
private struct CarSchedule: TimelineSchedule {
    let actif: Bool
    let continu: Bool
    let jusqua: Date
    let dt: Double
    let reflet: Bool

    func entries(from start: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(t: start, s: self, actif: actif && mode == .normal)
    }

    struct Entries: Sequence, IteratorProtocol {
        var t: Date
        let s: CarSchedule
        let actif: Bool
        var fini = false

        mutating func next() -> Date? {
            guard !fini else { return nil }
            let cur = t
            guard actif else { fini = true; return cur }
            var n = t.addingTimeInterval(s.dt)
            if !s.continu && n > s.jusqua.addingTimeInterval(s.dt) {
                guard s.reflet else { fini = true; return cur }
                // en dehors du reflet : saut au début du suivant
                let ph = n.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600).truncatingRemainder(dividingBy: 7)
                if ph > 1.7 + s.dt * 1.5 { n = n.addingTimeInterval(7 - ph) }
            }
            t = n
            return cur
        }
    }
}

// MARK: - Rendu d'une image
private struct CarRender {
    let size: CGSize
    let now: Date
    let debut: Date?
    let soc: Double?
    let charging: Bool
    let gear: String?
    let speed: Int?
    let roule: Bool
    let live: Bool
    let paint: CarPaint
    let done: CmdDone?
    let motion: Bool

    func draw(_ ctx0: GraphicsContext) {
        let t = now.timeIntervalSinceReferenceDate
        let tt = CGFloat(t.truncatingRemainder(dividingBy: 3600))
        let s = min(size.width * 0.78 / Dim.L, size.height / 2.7)

        // Arrivée : la voiture entre par la droite en roulant
        var e: CGFloat = 1
        if motion {
            e = debut.map { CGFloat(min(max(now.timeIntervalSince($0) / 1.3, 0), 1)) } ?? 0
        }
        let ease = 1 - pow(1 - e, 3)
        let course = size.width * 0.85
        let shift = (1 - ease) * course

        // Klaxon : la voiture tremble un instant
        var shake: CGFloat = 0
        if motion, let d = done, d.c == .klaxon {
            let x = CGFloat(now.timeIntervalSince(d.date))
            if x >= 0 && x < 0.7 { shake = sin(x * 90) * 1.6 * (1 - x / 0.7) }
        }
        let g = CarGeo(s: s, x0: (size.width - Dim.L * s) / 2 + shift + shake, gy: s * 2.15)

        // En roulant : roues et marquage au sol à la même vitesse
        let dir: CGFloat = gear == "R" ? -1 : 1
        let revs = CGFloat(min(0.35 + Double(speed ?? 6) / 45, 2.2))
        let rt = g.m(Dim.tire)
        var angle = -(course - shift) / rt
        var roadPhase: CGFloat = 0
        if roule && motion {
            angle -= dir * 2 * .pi * revs * tt
            roadPhase = -dir * 2 * .pi * rt * revs * tt
        }
        let allume = live && ["D", "R", "N"].contains(gear ?? "")

        var c = ctx0
        c.opacity = Double(min(1, e * 2.5))
        let lueur: Color = charging ? .kTeal : (roule ? .kBlue : .white)
        sol(c, g, couleur: lueur, k: charging ? 1 + 0.08 * sin(tt * 2.2) : 1, fort: charging || roule)
        reflet(c, g, angle: angle, tt: tt)
        if roule { route(c, g, phase: roadPhase) }
        ombre(c, g)
        voiture(c, g, angle: angle, tt: tt, allume: allume, reflet: false)
        if charging {
            batterie(c, g, tt: tt)
            cable(c, g, tt: tt)
        }
        effets(c, g)
    }

    // MARK: Sol, reflet, ombre
    private func sol(_ ctx: GraphicsContext, _ g: CarGeo, couleur: Color, k: CGFloat, fort: Bool) {
        var l = ctx
        l.translateBy(x: g.p(Dim.L / 2, 0).x, y: g.gy)
        l.scaleBy(x: 1, y: 0.2)
        let r = g.m(2.6) * k
        let o = fort ? 0.35 : 0.14
        l.fill(rond(.zero, r), with: .radialGradient(Gradient(colors: [couleur.opacity(o), couleur.opacity(0)]),
                                                     center: .zero, startRadius: 0, endRadius: r))
    }

    private func reflet(_ ctx: GraphicsContext, _ g: CarGeo, angle: CGFloat, tt: CGFloat) {
        ctx.drawLayer { l in
            l.translateBy(x: 0, y: g.gy * 2)
            l.scaleBy(x: 1, y: -1)
            voiture(l, g, angle: angle, tt: tt, allume: false, reflet: true)
            // fondu : visible au ras du sol, effacé 60 cm plus bas
            l.blendMode = .destinationIn
            l.fill(Path(CGRect(x: -size.width, y: g.p(0, 1.9).y, width: size.width * 3, height: g.m(2.0))),
                   with: .linearGradient(Gradient(colors: [.white.opacity(0.18), .white.opacity(0)]),
                                         startPoint: CGPoint(x: 0, y: g.gy), endPoint: CGPoint(x: 0, y: g.p(0, 0.6).y)))
        }
    }

    private func ombre(_ ctx: GraphicsContext, _ g: CarGeo) {
        var l = ctx
        l.addFilter(.blur(radius: g.m(0.09)))
        l.fill(Path(ellipseIn: CGRect(x: g.p(0.15, 0).x, y: g.gy - g.m(0.07), width: g.m(3.9), height: g.m(0.15))),
               with: .color(.black.opacity(0.7)))
        for cx in [Dim.fw, Dim.rw] {
            l.fill(Path(ellipseIn: CGRect(x: g.p(cx - 0.32, 0).x, y: g.gy - g.m(0.04), width: g.m(0.64), height: g.m(0.08))),
                   with: .color(.black.opacity(0.9)))
        }
    }

    private func route(_ ctx: GraphicsContext, _ g: CarGeo, phase: CGFloat) {
        let y = g.gy + g.m(0.07)
        let pat = g.m(0.9)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: y))
        p.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(p, with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.35), .white.opacity(0)]),
                                            startPoint: CGPoint(x: 0, y: y), endPoint: CGPoint(x: size.width, y: y)),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [g.m(0.4), pat - g.m(0.4)],
                                      dashPhase: phase.truncatingRemainder(dividingBy: pat)))
    }

    // MARK: Voiture
    private func voiture(_ ctx: GraphicsContext, _ g: CarGeo, angle: CGFloat, tt: CGFloat, allume: Bool, reflet: Bool) {
        let body = Silhouette.body(g)
        let glass = Silhouette.glass(g)

        ctx.fill(Silhouette.wells(g), with: .color(Color(white: 0.02)))
        roue(ctx, g, cx: Dim.fw, angle: angle)
        roue(ctx, g, cx: Dim.rw, angle: angle)

        // Peinture : reflet de toit, ligne d'épaule claire, bas de caisse dans l'ombre
        let haut = g.p(0, 1.58).y, bas = g.p(0, 0.27).y
        ctx.fill(body, with: .linearGradient(Gradient(stops: [
            .init(color: paint.tone(1.35), location: 0),
            .init(color: paint.tone(1.0), location: 0.30),
            .init(color: paint.tone(1.22), location: 0.47),
            .init(color: paint.tone(0.92), location: 0.56),
            .init(color: paint.tone(0.6), location: 1),
        ]), startPoint: CGPoint(x: 0, y: haut), endPoint: CGPoint(x: 0, y: bas)))

        var dedans = ctx
        dedans.clip(to: body)
        let noir = Color(white: 0.09)
        dedans.fill(Silhouette.arches(g), with: .color(noir))
        dedans.fill(Silhouette.lower(g), with: .color(noir))

        // Vitres teintées et reflet du ciel
        ctx.fill(glass, with: .linearGradient(Gradient(colors: [Color(white: 0.32), Color(white: 0.07), Color(white: 0.03)]),
                                              startPoint: g.p(0, 1.5), endPoint: g.p(0, 1.07)))
        var vitre = ctx
        vitre.clip(to: glass)
        vitre.fill(Path { p in
            p.addLines([g.p(2.2, 1.6), g.p(2.6, 1.6), g.p(2.2, 1.0), g.p(1.8, 1.0)])
            p.closeSubpath()
        }, with: .color(.white.opacity(0.07)))
        ctx.fill(Silhouette.pillarB(g), with: .color(Color(white: 0.02)))
        ctx.fill(Silhouette.pillarC(g), with: .linearGradient(Gradient(colors: [paint.tone(1.15), paint.tone(0.95)]),
                                                              startPoint: g.p(0, 1.47), endPoint: g.p(0, 1.15)))
        ctx.stroke(Silhouette.rails(g), with: .color(Color(white: 0.12)),
                   style: StrokeStyle(lineWidth: g.m(0.035), lineCap: .round))

        // Détails
        ctx.stroke(Silhouette.doors(g), with: .color(.black.opacity(0.35)), lineWidth: 0.8)
        ctx.stroke(Silhouette.crease(g), with: .color(.black.opacity(0.15)), lineWidth: 1)
        ctx.fill(Silhouette.handles(g), with: .color(paint.tone(0.7)))
        ctx.fill(Silhouette.mirror(g), with: .color(Color(white: 0.08)))
        ctx.stroke(Silhouette.shoulder(g), with: .color(.white.opacity(0.22)), lineWidth: max(1, g.m(0.012)))
        feux(ctx, g, allume: allume, halo: !reflet)

    }

    private func roue(_ ctx: GraphicsContext, _ g: CarGeo, cx: CGFloat, angle: CGFloat) {
        let c = g.p(cx, Dim.wy)
        let rt = g.m(Dim.tire), rr = g.m(Dim.rim)
        ctx.fill(rond(c, rt), with: .color(Color(white: 0.06)))
        ctx.stroke(rond(c, rt * 0.86), with: .color(.white.opacity(0.07)), lineWidth: 1)
        var w = ctx
        w.translateBy(x: c.x, y: c.y)
        w.fill(rond(.zero, rr), with: .linearGradient(Gradient(colors: [Color(white: 0.80), Color(white: 0.45), Color(white: 0.62)]),
                                                      startPoint: CGPoint(x: 0, y: -rr), endPoint: CGPoint(x: 0, y: rr)))
        w.rotate(by: .radians(Double(angle)))
        for k in 0..<5 {
            var b = w
            b.rotate(by: .degrees(Double(k) * 72))
            b.fill(Path(roundedRect: CGRect(x: rr * 0.30, y: -rr * 0.13, width: rr * 0.60, height: rr * 0.26), cornerRadius: rr * 0.1),
                   with: .color(Color(white: 0.16)))
        }
        w.fill(rond(.zero, rr * 0.2), with: .color(Color(white: 0.55)))
        w.stroke(rond(.zero, rr), with: .color(.white.opacity(0.25)), lineWidth: 0.8)
    }

    private func feux(_ ctx: GraphicsContext, _ g: CarGeo, allume: Bool, halo: Bool) {
        let drl = Silhouette.drl(g)
        if allume && halo {
            var h = ctx
            h.addFilter(.blur(radius: g.m(0.05)))
            h.stroke(drl, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: g.m(0.05), lineCap: .round))
        }
        ctx.stroke(drl, with: .color(.white.opacity(allume ? 1 : 0.55)), style: StrokeStyle(lineWidth: g.m(0.022), lineCap: .round))
        ctx.fill(Silhouette.headlamp(g), with: .linearGradient(Gradient(colors: [Color(white: allume ? 0.9 : 0.45), Color(white: 0.15)]),
                                                               startPoint: g.p(0, 0.67), endPoint: g.p(0, 0.55)))
        let rouge = Color(red: 0.95, green: 0.12, blue: 0.15)
        ctx.stroke(Silhouette.tail(g), with: .color(rouge.opacity(allume ? 1 : 0.6)), style: StrokeStyle(lineWidth: g.m(0.03), lineCap: .round))
        ctx.fill(Silhouette.tailLow(g), with: .color(rouge.opacity(allume ? 0.9 : 0.45)))
    }

    // MARK: Recharge
    private func batterie(_ ctx: GraphicsContext, _ g: CarGeo, tt: CGFloat) {
        let rect = Silhouette.pack(g)
        let f = CGFloat(max(0.04, min(1, (soc ?? 0) / 100)))
        var h = ctx
        h.addFilter(.blur(radius: g.m(0.08)))
        let pulse = motion ? 0.55 + 0.25 * sin(tt * 3) : 0.6
        h.fill(Path(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: 3), with: .color(Color.kTeal.opacity(Double(pulse))))
        ctx.fill(Path(roundedRect: rect, cornerRadius: g.m(0.03)), with: .color(.black.opacity(0.75)))
        let plein = CGRect(x: rect.minX + 1.5, y: rect.minY + 1.5, width: (rect.width - 3) * f, height: rect.height - 3)
        ctx.fill(Path(roundedRect: plein, cornerRadius: g.m(0.02)),
                 with: .linearGradient(Gradient(colors: [Color.kTeal.opacity(0.55), Color.kTeal]),
                                       startPoint: CGPoint(x: plein.minX, y: 0), endPoint: CGPoint(x: plein.maxX, y: 0)))
        if motion {
            let x = plein.minX + (tt * 0.6).truncatingRemainder(dividingBy: 1) * plein.width
            var r = ctx
            r.clip(to: Path(plein))
            r.fill(Path(CGRect(x: x - g.m(0.15), y: plein.minY, width: g.m(0.3), height: plein.height)),
                   with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.6), .white.opacity(0)]),
                                         startPoint: CGPoint(x: x - g.m(0.15), y: 0), endPoint: CGPoint(x: x + g.m(0.15), y: 0)))
        }
        var sep = Path()
        for i in 1..<8 {
            let x = rect.minX + rect.width * CGFloat(i) / 8
            sep.move(to: CGPoint(x: x, y: rect.minY))
            sep.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        ctx.stroke(sep, with: .color(.black.opacity(0.4)), lineWidth: 0.6)
    }

    /// Câble posé au sol jusqu'à la trappe avant, énergie qui circule vers la voiture
    private func cable(_ ctx: GraphicsContext, _ g: CarGeo, tt: CGFloat) {
        let port = g.p(0.01, 0.70)
        var p = Path()
        p.move(to: CGPoint(x: -6, y: g.gy - g.m(0.03)))
        p.addCurve(to: port, control1: CGPoint(x: port.x - g.m(0.5), y: g.gy - g.m(0.03)),
                   control2: CGPoint(x: port.x - g.m(0.3), y: port.y))
        ctx.stroke(p, with: .color(Color(white: 0.13)), style: StrokeStyle(lineWidth: g.m(0.05), lineCap: .round))
        var e = ctx
        e.blendMode = .plusLighter
        let pat = g.m(0.18)
        let phase = motion ? -(tt * g.m(0.5)).truncatingRemainder(dividingBy: pat) : 0
        e.stroke(p, with: .color(Color.kTeal),
                 style: StrokeStyle(lineWidth: g.m(0.022), lineCap: .round, dash: [g.m(0.05), pat - g.m(0.05)], dashPhase: phase))
        ctx.fill(Path(roundedRect: CGRect(x: port.x - g.m(0.13), y: port.y - g.m(0.05), width: g.m(0.14), height: g.m(0.10)),
                      cornerRadius: g.m(0.025)), with: .color(Color(white: 0.2)))
        if motion {
            let f = (tt * 0.7).truncatingRemainder(dividingBy: 1)
            e.stroke(rond(port, g.m(0.06 + 0.3 * f)), with: .color(Color.kTeal.opacity(Double((1 - f) * 0.8))), lineWidth: 1.5)
        }
    }

    // MARK: Commandes confirmées par l'ESP32
    private func effets(_ ctx: GraphicsContext, _ g: CarGeo) {
        guard let d = done else { return }
        let e = CGFloat(now.timeIntervalSince(d.date))
        guard e >= 0, e < 2.6 else { return }
        switch d.c {
        case .feux: phares(ctx, g, e)
        case .klaxon: klaxon(ctx, g, e)
        case .verrouiller, .deverrouiller:
            clignotants(ctx, g, e, deux: d.c == .deverrouiller)
            cadenas(ctx, g, e, ouvert: d.c == .deverrouiller)
        }
    }

    /// Appel de phares : faisceaux qui clignotent devant la voiture
    private func phares(_ ctx: GraphicsContext, _ g: CarGeo, _ e: CGFloat) {
        let on = e < 2.2 && (!motion || Int(e / 0.32) % 2 == 0)
        guard on else { return }
        let a = g.p(0.03, 0.66), b = g.p(0.03, 0.56)
        let loin = g.m(2.2)
        var c = ctx
        c.blendMode = .plusLighter
        let faisceau = Path { p in
            p.move(to: a)
            p.addLine(to: CGPoint(x: a.x - loin, y: a.y - g.m(0.25)))
            p.addLine(to: CGPoint(x: b.x - loin, y: g.gy + g.m(0.02)))
            p.addLine(to: b)
            p.closeSubpath()
        }
        c.fill(faisceau, with: .linearGradient(Gradient(colors: [.white.opacity(0.55), .white.opacity(0)]),
                                               startPoint: a, endPoint: CGPoint(x: a.x - loin, y: a.y)))
        var h = c
        h.addFilter(.blur(radius: g.m(0.06)))
        h.fill(rond(CGPoint(x: a.x, y: (a.y + b.y) / 2), g.m(0.12)), with: .color(.white))
    }

    /// Klaxon : ondes sonores devant la voiture
    private func klaxon(_ ctx: GraphicsContext, _ g: CarGeo, _ e: CGFloat) {
        guard e < 1.8 else { return }
        let c0 = g.p(-0.05, 0.62)
        let env = min(1, (1.8 - e) / 0.5)
        for k in 0..<3 {
            let f = motion ? (e * 1.3 + CGFloat(k) / 3).truncatingRemainder(dividingBy: 1) : CGFloat(k) / 3 + 0.15
            let r = g.m(0.15 + 0.9 * f)
            var p = Path()
            for i in 0...16 {
                let a = (150 + 60 * CGFloat(i) / 16) * .pi / 180
                let pt = CGPoint(x: c0.x + r * cos(a), y: c0.y + r * sin(a))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(Color.kGold.opacity(Double((1 - f) * env))),
                       style: StrokeStyle(lineWidth: g.m(0.03), lineCap: .round))
        }
    }

    /// Feux de détresse : 1 éclat à la fermeture, 2 à l'ouverture (comme la voiture)
    private func clignotants(_ ctx: GraphicsContext, _ g: CarGeo, _ e: CGFloat, deux: Bool) {
        let on: Bool
        if !motion { on = e < 1.0 }
        else if deux { on = (e > 0.05 && e < 0.4) || (e > 0.65 && e < 1.0) }
        else { on = e > 0.05 && e < 0.6 }
        guard on else { return }
        var c = ctx
        c.blendMode = .plusLighter
        let ambre = Color(red: 1, green: 0.62, blue: 0.1)
        for pt in [g.p(0.06, 0.62), g.p(1.47, 1.07), g.p(4.12, 1.05)] {
            let r = g.m(0.16)
            c.fill(rond(pt, r), with: .radialGradient(Gradient(colors: [ambre.opacity(0.95), ambre.opacity(0)]),
                                                      center: pt, startRadius: 0, endRadius: r))
        }
    }

    /// Cadenas au-dessus du toit, petit rebond et onde
    private func cadenas(_ ctx: GraphicsContext, _ g: CarGeo, _ e: CGFloat, ouvert: Bool) {
        let c0 = g.p(2.75, 1.86)
        var sc: CGFloat = 1
        if motion {
            sc = e < 0.35 ? 0.6 + 0.55 * (e / 0.35) : 1.15 - 0.15 * min(1, (e - 0.35) / 0.2)
        }
        let r = g.m(0.2) * sc
        let teinte: Color = ouvert ? .kGold : .kTeal
        var c = ctx
        c.opacity = Double(e < 2.0 ? 1 : max(0, 1 - (e - 2.0) / 0.5))
        if motion && e < 1 {
            c.stroke(rond(c0, r + g.m(0.5) * e), with: .color(teinte.opacity(Double(1 - e))), lineWidth: 1.2)
        }
        c.fill(rond(c0, r), with: .color(.black.opacity(0.55)))
        c.stroke(rond(c0, r), with: .color(teinte), lineWidth: 1.5)
        let sym = c.resolve(Text(Image(systemName: ouvert ? "lock.open.fill" : "lock.fill"))
            .font(.system(size: r * 0.95, weight: .semibold))
            .foregroundStyle(Color.white))
        c.draw(sym, at: c0, anchor: .center)
    }
}
