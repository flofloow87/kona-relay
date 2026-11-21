import SwiftUI
import UIKit

// MARK: - Photo réaliste de la Kona (KonaPhoto.png, détourée, avant de la voiture à droite)
/// Pour changer de photo : remplacer KonaPhoto.png par une autre image détourée (PNG transparent),
/// puis ajuster si besoin les repères `P` ci-dessous (fractions de l'image, 0,0 = coin haut gauche).
enum KonaPhoto {
    static let image: UIImage? = UIImage(named: "KonaPhoto")

    /// Repères sur la photo (x, y en fraction de la largeur / hauteur de l'image)
    fileprivate enum P {
        static let drl = (a: CGPoint(x: 0.62, y: 0.405), b: CGPoint(x: 0.78, y: 0.445))   // feu de jour avant
        static let projecteur = CGPoint(x: 0.705, y: 0.58)                                 // phare principal
        static let phareLoin = CGPoint(x: 0.962, y: 0.415)                                 // phare côté opposé
        static let prise = CGPoint(x: 0.865, y: 0.56)                                      // trappe de recharge (calandre)
        static let klaxon = CGPoint(x: 1.0, y: 0.6)
        static let clignotants = [CGPoint(x: 0.605, y: 0.59), CGPoint(x: 0.38, y: 0.28),
                                  CGPoint(x: 0.04, y: 0.30), CGPoint(x: 0.962, y: 0.43)]
        static let roues = [CGPoint(x: 0.085, y: 0.94), CGPoint(x: 0.545, y: 0.995), CGPoint(x: 0.92, y: 0.89)]
        /// Jantes visibles, vues en ellipse (perspective) : centre, demi-axes (fraction de la largeur / hauteur), inclinaison
        static let jantes = [Jante(c: CGPoint(x: 0.0614, y: 0.6985), rx: 0.0346, ry: 0.1292, incl: 5),
                             Jante(c: CGPoint(x: 0.5333, y: 0.7772), rx: 0.0545, ry: 0.1590, incl: 6)]
        /// Rayon du pneu en fraction de la hauteur de l'image (vitesse de rotation des roues)
        static let pneu: CGFloat = 0.215
    }

    fileprivate struct Jante {
        let c: CGPoint
        let rx: CGFloat
        let ry: CGFloat
        let incl: Double     // degrés, sens horaire
    }
}

/// Rendu d'une image de la scène d'accueil avec la photo : arrivée, reflet, ombre, recharge, commandes
struct PhotoRender {
    let image: UIImage
    let size: CGSize
    let now: Date
    let debut: Date?
    let charging: Bool
    let gear: String?
    let speed: Int?
    let roule: Bool
    let live: Bool
    let done: CmdDone?
    let motion: Bool

    private typealias P = KonaPhoto.P

    func draw(_ ctx0: GraphicsContext) {
        let t = now.timeIntervalSinceReferenceDate
        let tt = CGFloat(t.truncatingRemainder(dividingBy: 3600))
        let ratio = image.size.width / max(image.size.height, 1)
        let w = min(size.width * 0.84, size.height * 0.80 * ratio)
        let h = w / ratio
        let gy = size.height * 0.90

        // Arrivée : la voiture entre par la gauche, en marche avant
        var e: CGFloat = 1
        if motion { e = debut.map { CGFloat(min(max(now.timeIntervalSince($0) / 1.3, 0), 1)) } ?? 0 }
        let ease = 1 - pow(1 - e, 3)
        let shift = -(1 - ease) * size.width * 0.85

        let r = CGRect(x: (size.width - w) / 2 + shift, y: gy - h, width: w, height: h)
        let g = Geo(r: r, gy: gy)

        // Roues : tournent pendant l'arrivée et en roulant, à la vitesse du marquage au sol
        let rayon = KonaPhoto.P.pneu * h
        var angle = shift / rayon
        if roule && motion { angle += vitesseSol(g) * tt / rayon }
        let photo = ctx0.resolve(Image(uiImage: image))

        var c = ctx0
        c.opacity = Double(min(1, e * 2.5))
        let lueur: Color = charging ? .kTeal : (roule ? .kBlue : .white)
        sol(c, g, couleur: lueur, k: charging ? 1 + 0.08 * sin(tt * 2.2) : 1, fort: charging || roule)
        reflet(c, g, photo, angle: angle)
        if roule { route(c, g, tt: tt) }
        ombre(c, g)
        if faisceauxActifs { faisceaux(c, g) }        // derrière la voiture : ne recouvre pas la carrosserie
        voiture(c, g, photo, angle: angle)
        if live && ["D", "R", "N"].contains(gear ?? "") { feuxDeJour(c, g) }
        if charging {
            cable(c, g, tt: tt)                       // devant la voiture : branché sur la trappe de la calandre
            prise(c, g, tt: tt)
        }
        effets(c, g)
    }

    // MARK: Géométrie
    private struct Geo {
        let r: CGRect
        let gy: CGFloat
        func p(_ u: CGPoint) -> CGPoint { CGPoint(x: r.minX + u.x * r.width, y: r.minY + u.y * r.height) }
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { p(CGPoint(x: x, y: y)) }
        func m(_ f: CGFloat) -> CGFloat { f * r.width }      // longueur en fraction de la largeur de la voiture
    }

    // MARK: Sol, reflet, ombre, route
    private func sol(_ ctx: GraphicsContext, _ g: Geo, couleur: Color, k: CGFloat, fort: Bool) {
        var l = ctx
        l.translateBy(x: g.r.midX, y: g.gy - g.m(0.01))
        l.scaleBy(x: 1, y: 0.18)
        let rr = g.m(0.62) * k
        let o = fort ? 0.38 : 0.14
        l.fill(rond(.zero, rr), with: .radialGradient(Gradient(colors: [couleur.opacity(o), couleur.opacity(0)]),
                                                      center: .zero, startRadius: 0, endRadius: rr))
    }

    /// Reflet de la voiture sur un sol brillant, effacé rapidement
    private func reflet(_ ctx: GraphicsContext, _ g: Geo, _ photo: GraphicsContext.ResolvedImage, angle: CGFloat) {
        ctx.drawLayer { l in
            l.drawLayer { m in
                m.translateBy(x: 0, y: g.gy * 2)
                m.scaleBy(x: 1, y: -1)
                voiture(m, g, photo, angle: angle)
            }
            l.blendMode = .destinationIn
            l.fill(Path(CGRect(x: 0, y: g.gy, width: size.width, height: g.r.height * 0.4)),
                   with: .linearGradient(Gradient(colors: [.white.opacity(0.2), .white.opacity(0)]),
                                         startPoint: CGPoint(x: 0, y: g.gy), endPoint: CGPoint(x: 0, y: g.gy + g.r.height * 0.3)))
        }
    }

    private func ombre(_ ctx: GraphicsContext, _ g: Geo) {
        var l = ctx
        l.addFilter(.blur(radius: g.m(0.022)))
        l.fill(Path(ellipseIn: CGRect(x: g.r.minX + g.m(0.02), y: g.p(0, 0.90).y, width: g.m(0.96), height: g.r.height * 0.11)),
               with: .color(.black.opacity(0.55)))
        for w in P.roues {
            let c = g.p(w)
            l.fill(Path(ellipseIn: CGRect(x: c.x - g.m(0.055), y: c.y - g.m(0.012), width: g.m(0.11), height: g.m(0.024))),
                   with: .color(.black.opacity(0.85)))
        }
    }

    /// Marquage au sol qui défile sous la voiture en roulant
    /// Vitesse de défilement (points / s, négative en marche arrière), commune à la route et aux roues
    private func vitesseSol(_ g: Geo) -> CGFloat {
        (gear == "R" ? -1 : 1) * g.m(0.9) * CGFloat(min(0.35 + Double(speed ?? 6) / 45, 2.2))
    }

    private func route(_ ctx: GraphicsContext, _ g: Geo, tt: CGFloat) {
        let v = vitesseSol(g)
        let y = g.gy + g.m(0.02)
        let pat = g.m(0.22)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: y))
        p.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(p, with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.35), .white.opacity(0)]),
                                            startPoint: CGPoint(x: 0, y: y), endPoint: CGPoint(x: size.width, y: y)),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [g.m(0.1), pat - g.m(0.1)],
                                      dashPhase: motion ? (v * tt).truncatingRemainder(dividingBy: pat) : 0))
    }

    // MARK: Voiture
    /// Photo, puis jantes redessinées tournées de `angle` (rotation dans le plan de la roue, perspective conservée)
    private func voiture(_ ctx: GraphicsContext, _ g: Geo, _ photo: GraphicsContext.ResolvedImage, angle: CGFloat) {
        ctx.draw(photo, in: g.r)
        let a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        guard abs(a) > 0.001 else { return }
        for j in P.jantes {
            let c = g.p(j.c)
            // cercle unité → ellipse de la jante à l'écran
            let t = CGAffineTransform(scaleX: j.rx * g.r.width, y: j.ry * g.r.height)
                .concatenating(CGAffineTransform(rotationAngle: j.incl * .pi / 180))
            let rot = t.inverted().concatenating(CGAffineTransform(rotationAngle: a)).concatenating(t)
            var l = ctx
            l.clip(to: Path(ellipseIn: CGRect(x: -0.97, y: -0.97, width: 1.94, height: 1.94))
                .applying(t.concatenating(CGAffineTransform(translationX: c.x, y: c.y))))
            l.translateBy(x: c.x, y: c.y)
            l.concatenate(rot)
            l.translateBy(x: -c.x, y: -c.y)
            l.draw(photo, in: g.r)
        }
    }

    /// Feux de jour allumés quand la voiture est démarrée
    private func feuxDeJour(_ ctx: GraphicsContext, _ g: Geo) {
        var c = ctx
        c.blendMode = .plusLighter
        c.addFilter(.blur(radius: g.m(0.006)))
        var p = Path()
        p.move(to: g.p(P.drl.a))
        p.addLine(to: g.p(P.drl.b))
        c.stroke(p, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: g.m(0.008), lineCap: .round))
        let f = g.p(P.phareLoin)
        c.fill(rond(f, g.m(0.012)), with: .color(.white.opacity(0.6)))
    }

    // MARK: Recharge
    /// Câble posé au sol depuis la droite jusqu'à la trappe de la calandre, énergie qui circule vers la voiture
    private func cable(_ ctx: GraphicsContext, _ g: Geo, tt: CGFloat) {
        let port = g.p(P.prise)
        let depart = CGPoint(x: size.width + 6, y: g.gy - g.m(0.005))
        var p = Path()
        p.move(to: depart)
        p.addCurve(to: port, control1: CGPoint(x: port.x + g.m(0.12), y: depart.y),
                   control2: CGPoint(x: port.x + g.m(0.04), y: port.y + g.m(0.04)))
        ctx.stroke(p, with: .color(Color(white: 0.13)), style: StrokeStyle(lineWidth: g.m(0.012), lineCap: .round))
        var e = ctx
        e.blendMode = .plusLighter
        let pat = g.m(0.045)
        let phase = motion ? -(tt * g.m(0.12)).truncatingRemainder(dividingBy: pat) : 0
        e.stroke(p, with: .color(Color.kTeal),
                 style: StrokeStyle(lineWidth: g.m(0.005), lineCap: .round, dash: [g.m(0.012), pat - g.m(0.012)], dashPhase: phase))
    }

    private func prise(_ ctx: GraphicsContext, _ g: Geo, tt: CGFloat) {
        let port = g.p(P.prise)
        var e = ctx
        e.blendMode = .plusLighter
        var h = e
        h.addFilter(.blur(radius: g.m(0.01)))
        let pulse = motion ? 0.55 + 0.3 * sin(tt * 3) : 0.7
        h.fill(rond(port, g.m(0.018)), with: .color(Color.kTeal.opacity(Double(pulse))))
        if motion {
            let f = (tt * 0.7).truncatingRemainder(dividingBy: 1)
            e.stroke(rond(port, g.m(0.015 + 0.07 * f)), with: .color(Color.kTeal.opacity(Double((1 - f) * 0.8))), lineWidth: 1.5)
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

    /// Appel de phares en cours et dans sa phase allumée (clignote toutes les 0,32 s)
    private var faisceauxActifs: Bool {
        guard let d = done, d.c == .feux else { return false }
        let e = CGFloat(now.timeIntervalSince(d.date))
        return e >= 0 && e < 2.2 && (!motion || Int(e / 0.32) % 2 == 0)
    }

    /// Faisceau vers l'avant (à droite), dessiné sous la voiture
    private func faisceaux(_ ctx: GraphicsContext, _ g: Geo) {
        var c = ctx
        c.blendMode = .plusLighter
        let a = g.p(P.phareLoin), b = g.p(P.projecteur)
        let loin = size.width - a.x + 10
        let faisceau = Path { p in
            p.move(to: CGPoint(x: a.x, y: a.y - g.m(0.01)))
            p.addLine(to: CGPoint(x: a.x + loin, y: a.y - g.m(0.06)))
            p.addLine(to: CGPoint(x: a.x + loin, y: g.gy))
            p.addLine(to: CGPoint(x: b.x, y: b.y + g.m(0.02)))
            p.closeSubpath()
        }
        c.fill(faisceau, with: .linearGradient(Gradient(colors: [.white.opacity(0.4), .white.opacity(0)]),
                                               startPoint: a, endPoint: CGPoint(x: a.x + loin, y: a.y)))
    }

    /// Appel de phares : les phares s'allument
    private func phares(_ ctx: GraphicsContext, _ g: Geo, _ e: CGFloat) {
        guard faisceauxActifs else { return }
        var c = ctx
        c.blendMode = .plusLighter
        var h = c
        h.addFilter(.blur(radius: g.m(0.012)))
        for pt in [g.p(P.projecteur), g.p(P.phareLoin), g.p(P.drl.a), g.p(P.drl.b)] {
            h.fill(rond(pt, g.m(0.022)), with: .color(.white))
        }
    }

    /// Klaxon : ondes sonores devant la voiture
    private func klaxon(_ ctx: GraphicsContext, _ g: Geo, _ e: CGFloat) {
        guard e < 1.8 else { return }
        let c0 = g.p(P.klaxon)
        let env = min(1, (1.8 - e) / 0.5)
        for k in 0..<3 {
            let f = motion ? (e * 1.3 + CGFloat(k) / 3).truncatingRemainder(dividingBy: 1) : CGFloat(k) / 3 + 0.15
            let rr = g.m(0.03 + 0.16 * f)
            var p = Path()
            for i in 0...16 {
                let a = (-30 + 60 * CGFloat(i) / 16) * .pi / 180
                let pt = CGPoint(x: c0.x + rr * cos(a), y: c0.y + rr * sin(a))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(Color.kGold.opacity(Double((1 - f) * env))),
                       style: StrokeStyle(lineWidth: g.m(0.007), lineCap: .round))
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
        for pt in P.clignotants.map(g.p) {
            let rr = g.m(0.035)
            c.fill(rond(pt, rr), with: .radialGradient(Gradient(colors: [ambre.opacity(0.95), ambre.opacity(0)]),
                                                       center: pt, startRadius: 0, endRadius: rr))
        }
    }

    /// Cadenas au-dessus du toit, petit rebond et onde
    private func cadenas(_ ctx: GraphicsContext, _ g: Geo, _ e: CGFloat, ouvert: Bool) {
        var sc: CGFloat = 1
        if motion { sc = e < 0.35 ? 0.6 + 0.55 * (e / 0.35) : 1.15 - 0.15 * min(1, (e - 0.35) / 0.2) }
        let rr = g.m(0.045) * sc
        let c0 = CGPoint(x: g.p(0.47, 0).x, y: max(g.m(0.045) + 3, g.r.minY - g.m(0.03)))
        let teinte: Color = ouvert ? .kGold : .kTeal
        var c = ctx
        c.opacity = Double(e < 2.0 ? 1 : max(0, 1 - (e - 2.0) / 0.5))
        if motion && e < 1 {
            c.stroke(rond(c0, rr + g.m(0.11) * e), with: .color(teinte.opacity(Double(1 - e))), lineWidth: 1.2)
        }
        c.fill(rond(c0, rr), with: .color(.black.opacity(0.55)))
        c.stroke(rond(c0, rr), with: .color(teinte), lineWidth: 1.5)
        let sym = c.resolve(Text(Image(systemName: ouvert ? "lock.open.fill" : "lock.fill"))
            .font(.system(size: rr * 0.95, weight: .semibold))
            .foregroundStyle(Color.white))
        c.draw(sym, at: c0, anchor: .center)
    }
}
