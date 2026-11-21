import SwiftUI

// MARK: - Teinte de carrosserie (réglage « carColor »)
enum CarPaint: String, CaseIterable, Identifiable {
    case gris, blanc, noir, nuit, rouge, bleu
    var id: String { rawValue }
    var label: String {
        switch self {
        case .gris: "Gris galactique"
        case .blanc: "Blanc craie"
        case .noir: "Noir fantôme"
        case .nuit: "Bleu nuit"
        case .rouge: "Rouge pulse"
        case .bleu: "Bleu céramique"
        }
    }
    private var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .gris: (0.43, 0.45, 0.48)
        case .blanc: (0.88, 0.89, 0.88)
        case .noir: (0.09, 0.10, 0.12)
        case .nuit: (0.15, 0.19, 0.27)
        case .rouge: (0.68, 0.07, 0.10)
        case .bleu: (0.36, 0.62, 0.78)
        }
    }
    /// k < 1 assombrit, k > 1 éclaircit (mélange avec du blanc)
    func tone(_ k: Double) -> Color {
        let c = rgb
        if k <= 1 { return Color(red: c.r * k, green: c.g * k, blue: c.b * k) }
        let w = min(k - 1, 1)
        return Color(red: c.r + (1 - c.r) * w, green: c.g + (1 - c.g) * w, blue: c.b + (1 - c.b) * w)
    }
}

// MARK: - Scène de l'écran d'accueil : Kona de profil dessinée et animée
/// Arrivée en roulant, reflet qui balaie la carrosserie, roues et route en mouvement en roulant,
/// câble et batterie lumineux en charge, phares / clignotants / klaxon quand l'ESP32 confirme une commande.
struct KonaCarScene: View {
    var soc: Double?
    var charging: Bool
    var gear: String?
    var speed: Int?
    var live: Bool
    var paint: CarPaint
    var done: CmdDone?
    var eco: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.scenePhase) private var phase
    @State private var debut: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: eco ? 1.0 / 12 : 1.0 / 30, paused: phase != .active)) { tl in
            Canvas { ctx, size in
                CarRender(size: size, now: tl.date, debut: debut, soc: soc, charging: charging, gear: gear,
                          speed: speed, live: live, paint: paint, done: done, motion: !reduce).draw(ctx)
            }
        }
        .aspectRatio(2.0, contentMode: .fit)
        .onAppear { if debut == nil { debut = Date() } }
        .accessibilityElement()
        .accessibilityLabel(charging ? "Kona en charge" : "Kona")
    }
}

// MARK: - Géométrie (mètres → points). x : de l'avant (0) vers l'arrière, y : depuis le sol.
private enum K {
    static let L: CGFloat = 4.18          // longueur
    static let fw: CGFloat = 0.86         // centre de la roue avant
    static let rw: CGFloat = 3.46         // centre de la roue arrière
    static let wy: CGFloat = 0.33         // hauteur des moyeux
    static let tire: CGFloat = 0.33       // rayon du pneu
    static let arch: CGFloat = 0.41       // rayon des passages de roue
}

private struct Geo {
    var s: CGFloat      // points par mètre
    var x0: CGFloat     // abscisse du bouclier avant
    var gy: CGFloat     // ordonnée du sol
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x0 + x * s, y: gy - y * s) }
    func m(_ v: CGFloat) -> CGFloat { v * s }
    /// Rectangle donné en mètres (xmin, ymin, xmax, ymax)
    func rect(_ xa: CGFloat, _ ya: CGFloat, _ xb: CGFloat, _ yb: CGFloat) -> CGRect {
        let a = p(xa, yb), b = p(xb, ya)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
}

private func rond(_ c: CGPoint, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}

/// Arc en coordonnées voiture (angles en degrés, sens trigonométrique, y vers le haut)
private func arc(_ p: inout Path, _ g: Geo, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat,
                 _ a0: CGFloat, _ a1: CGFloat, move: Bool) {
    let n = 20
    for i in 0...n {
        let a = (a0 + (a1 - a0) * CGFloat(i) / CGFloat(n)) * .pi / 180
        let pt = g.p(cx + r * cos(a), cy + r * sin(a))
        if i == 0 && move { p.move(to: pt) } else { p.addLine(to: pt) }
    }
}

/// Silhouette de la Kona Electric (SUV compact, capot court, toit fuyant, aileron, habillage noir)
private enum Silhouette {
    static func body(_ g: Geo) -> Path {
        var p = Path()
        p.move(to: g.p(0.12, 0.30))
        p.addQuadCurve(to: g.p(0.0, 0.50), control: g.p(0.0, 0.30))
        p.addLine(to: g.p(0.02, 0.74))
        p.addQuadCurve(to: g.p(0.16, 0.90), control: g.p(0.03, 0.88))
        p.addQuadCurve(to: g.p(1.22, 1.05), control: g.p(0.75, 1.01))
        p.addQuadCurve(to: g.p(1.98, 1.50), control: g.p(1.55, 1.38))
        p.addQuadCurve(to: g.p(3.62, 1.49), control: g.p(2.85, 1.58))
        p.addLine(to: g.p(3.96, 1.45))
        p.addQuadCurve(to: g.p(4.04, 1.37), control: g.p(4.04, 1.45))
        p.addLine(to: g.p(4.11, 1.10))
        p.addQuadCurve(to: g.p(4.18, 0.80), control: g.p(4.18, 1.00))
        p.addLine(to: g.p(4.16, 0.50))
        p.addQuadCurve(to: g.p(4.00, 0.30), control: g.p(4.15, 0.31))
        arc(&p, g, K.rw, K.wy, K.arch, -8, 188, move: false)
        arc(&p, g, K.fw, K.wy, K.arch, -8, 188, move: false)
        p.closeSubpath()
        return p
    }

    static func glass(_ g: Geo) -> Path {
        var p = Path()
        p.move(to: g.p(1.34, 1.07))
        p.addQuadCurve(to: g.p(2.00, 1.45), control: g.p(1.62, 1.34))
        p.addQuadCurve(to: g.p(3.50, 1.44), control: g.p(2.80, 1.52))
        p.addQuadCurve(to: g.p(3.86, 1.24), control: g.p(3.80, 1.42))
        p.addLine(to: g.p(3.84, 1.17))
        p.closeSubpath()
        return p
    }

    static func wells(_ g: Geo) -> Path {
        var p = Path()
        for cx in [K.fw, K.rw] {
            arc(&p, g, cx, K.wy, K.arch, -8, 188, move: true)
            p.closeSubpath()
        }
        return p
    }

    /// Élargisseurs d'ailes (à remplir découpés par la carrosserie)
    static func arches(_ g: Geo) -> Path {
        var p = Path()
        for cx in [K.fw, K.rw] {
            arc(&p, g, cx, K.wy, K.arch + 0.075, -10, 190, move: true)
            arc(&p, g, cx, K.wy, K.arch - 0.01, 190, -10, move: false)
            p.closeSubpath()
        }
        return p
    }

    /// Bas de caisse et bas des boucliers
    static func lower(_ g: Geo) -> Path {
        var p = Path()
        p.addRect(g.rect(K.fw, 0.2, K.rw, 0.40))
        p.addRect(g.rect(0.0, 0.2, 0.5, 0.40))
        p.addRect(g.rect(3.85, 0.2, 4.3, 0.44))
        return p
    }

    static func pillarB(_ g: Geo) -> Path {
        Path { p in
            p.addLines([g.p(2.55, 1.11), g.p(2.63, 1.11), g.p(2.67, 1.49), g.p(2.59, 1.49)])
            p.closeSubpath()
        }
    }

    static func pillarC(_ g: Geo) -> Path {
        Path { p in
            p.addLines([g.p(3.30, 1.15), g.p(3.44, 1.15), g.p(3.60, 1.46), g.p(3.44, 1.47)])
            p.closeSubpath()
        }
    }

    static func rails(_ g: Geo) -> Path {
        Path { p in
            p.move(to: g.p(2.05, 1.548))
            p.addQuadCurve(to: g.p(3.55, 1.532), control: g.p(2.85, 1.598))
        }
    }

    static func doors(_ g: Geo) -> Path {
        var p = Path()
        p.move(to: g.p(1.36, 0.44))
        p.addQuadCurve(to: g.p(1.33, 1.06), control: g.p(1.40, 0.80))
        p.move(to: g.p(2.60, 0.41))
        p.addLine(to: g.p(2.60, 1.11))
        p.move(to: g.p(3.00, 0.44))
        p.addQuadCurve(to: g.p(3.30, 1.14), control: g.p(3.12, 0.98))
        return p
    }

    static func handles(_ g: Geo) -> Path {
        var p = Path()
        let r = CGSize(width: g.m(0.017), height: g.m(0.017))
        p.addRoundedRect(in: g.rect(2.18, 0.955, 2.36, 0.99), cornerSize: r)
        p.addRoundedRect(in: g.rect(3.00, 0.975, 3.16, 1.01), cornerSize: r)
        return p
    }

    static func mirror(_ g: Geo) -> Path {
        Path { p in
            p.move(to: g.p(1.36, 1.05))
            p.addQuadCurve(to: g.p(1.60, 1.12), control: g.p(1.50, 1.04))
            p.addQuadCurve(to: g.p(1.40, 1.19), control: g.p(1.58, 1.20))
            p.closeSubpath()
        }
    }

    static func shoulder(_ g: Geo) -> Path {
        Path { p in
            p.move(to: g.p(0.35, 0.93))
            p.addQuadCurve(to: g.p(4.10, 1.02), control: g.p(2.2, 0.95))
        }
    }

    static func crease(_ g: Geo) -> Path {
        Path { p in
            p.move(to: g.p(1.40, 0.60))
            p.addQuadCurve(to: g.p(3.00, 0.66), control: g.p(2.2, 0.60))
        }
    }

    static func drl(_ g: Geo) -> Path {
        Path { p in
            p.move(to: g.p(0.07, 0.86))
            p.addQuadCurve(to: g.p(0.50, 0.94), control: g.p(0.25, 0.92))
        }
    }

    static func headlamp(_ g: Geo) -> Path { Path(roundedRect: g.rect(0.01, 0.55, 0.26, 0.67), cornerRadius: g.m(0.04)) }

    static func tail(_ g: Geo) -> Path {
        Path { p in
            p.move(to: g.p(3.98, 1.14))
            p.addLine(to: g.p(4.13, 1.03))
        }
    }

    static func tailLow(_ g: Geo) -> Path { Path(roundedRect: g.rect(4.05, 0.55, 4.17, 0.63), cornerRadius: g.m(0.02)) }
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
    let live: Bool
    let paint: CarPaint
    let done: CmdDone?
    let motion: Bool

    func draw(_ ctx0: GraphicsContext) {
        let t = now.timeIntervalSinceReferenceDate
        let tt = CGFloat(t.truncatingRemainder(dividingBy: 3600))
        let s = min(size.width * 0.78 / K.L, size.height / 2.7)

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
        let g = Geo(s: s, x0: (size.width - K.L * s) / 2 + shift + shake, gy: s * 2.15)

        // En roulant : roues et marquage au sol à la même vitesse
        let roule = live && (gear == "D" || gear == "R") && (speed ?? 1) > 0
        let dir: CGFloat = gear == "R" ? -1 : 1
        let revs = CGFloat(min(0.35 + Double(speed ?? 6) / 45, 2.2))
        let rt = g.m(K.tire)
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
    private func sol(_ ctx: GraphicsContext, _ g: Geo, couleur: Color, k: CGFloat, fort: Bool) {
        var l = ctx
        l.translateBy(x: g.p(K.L / 2, 0).x, y: g.gy)
        l.scaleBy(x: 1, y: 0.2)
        let r = g.m(2.6) * k
        let o = fort ? 0.35 : 0.14
        l.fill(rond(.zero, r), with: .radialGradient(Gradient(colors: [couleur.opacity(o), couleur.opacity(0)]),
                                                     center: .zero, startRadius: 0, endRadius: r))
    }

    private func reflet(_ ctx: GraphicsContext, _ g: Geo, angle: CGFloat, tt: CGFloat) {
        var c = ctx
        c.drawLayer { l in
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

    private func ombre(_ ctx: GraphicsContext, _ g: Geo) {
        var l = ctx
        l.addFilter(.blur(radius: g.m(0.09)))
        l.fill(Path(ellipseIn: CGRect(x: g.p(0.15, 0).x, y: g.gy - g.m(0.07), width: g.m(3.9), height: g.m(0.15))),
               with: .color(.black.opacity(0.7)))
        for cx in [K.fw, K.rw] {
            l.fill(Path(ellipseIn: CGRect(x: g.p(cx - 0.32, 0).x, y: g.gy - g.m(0.04), width: g.m(0.64), height: g.m(0.08))),
                   with: .color(.black.opacity(0.9)))
        }
    }

    private func route(_ ctx: GraphicsContext, _ g: Geo, phase: CGFloat) {
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
    private func voiture(_ ctx: GraphicsContext, _ g: Geo, angle: CGFloat, tt: CGFloat, allume: Bool, reflet: Bool) {
        let body = Silhouette.body(g)
        let glass = Silhouette.glass(g)

        ctx.fill(Silhouette.wells(g), with: .color(Color(white: 0.02)))
        roue(ctx, g, cx: K.fw, angle: angle)
        roue(ctx, g, cx: K.rw, angle: angle)

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

        if !reflet { balayage(ctx, g, body: body, tt: tt) }
    }

    private func roue(_ ctx: GraphicsContext, _ g: Geo, cx: CGFloat, angle: CGFloat) {
        let c = g.p(cx, K.wy)
        let rt = g.m(K.tire), rr = g.m(0.225)
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

    private func feux(_ ctx: GraphicsContext, _ g: Geo, allume: Bool, halo: Bool) {
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

    /// Reflet de lumière qui traverse la carrosserie toutes les 7 s
    private func balayage(_ ctx: GraphicsContext, _ g: Geo, body: Path, tt: CGFloat) {
        guard motion else { return }
        let ph = tt.truncatingRemainder(dividingBy: 7)
        let dur: CGFloat = 1.7
        guard ph < dur else { return }
        let w = g.m(0.7), sk = g.m(0.5)
        let x = g.p(-0.8, 0).x + ph / dur * g.m(K.L + 1.8)
        let haut = g.p(0, 1.6).y, bas = g.p(0, 0.25).y
        var c = ctx
        c.clip(to: body)
        let bande = Path { p in
            p.addLines([CGPoint(x: x, y: haut), CGPoint(x: x + w, y: haut), CGPoint(x: x + w - sk, y: bas), CGPoint(x: x - sk, y: bas)])
            p.closeSubpath()
        }
        c.fill(bande, with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.28), .white.opacity(0)]),
                                            startPoint: CGPoint(x: x - sk, y: bas), endPoint: CGPoint(x: x + w, y: haut)))
    }

    // MARK: Recharge
    private func batterie(_ ctx: GraphicsContext, _ g: Geo, tt: CGFloat) {
        let rect = g.rect(1.42, 0.31, 2.94, 0.40)
        let f = CGFloat(max(0.04, min(1, (soc ?? 0) / 100)))
        var h = ctx
        h.addFilter(.blur(radius: g.m(0.08)))
        let pulse = 0.55 + 0.25 * sin(tt * 3)
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
    private func cable(_ ctx: GraphicsContext, _ g: Geo, tt: CGFloat) {
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
    private func effets(_ ctx: GraphicsContext, _ g: Geo) {
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
    private func phares(_ ctx: GraphicsContext, _ g: Geo, _ e: CGFloat) {
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
    private func klaxon(_ ctx: GraphicsContext, _ g: Geo, _ e: CGFloat) {
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
    private func clignotants(_ ctx: GraphicsContext, _ g: Geo, _ e: CGFloat, deux: Bool) {
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
    private func cadenas(_ ctx: GraphicsContext, _ g: Geo, _ e: CGFloat, ouvert: Bool) {
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
