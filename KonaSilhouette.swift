import SwiftUI
import WidgetKit

// Partagé entre l'app et les widgets : teintes et silhouette de la Kona Electric

// MARK: - Teinte de carrosserie (réglage « carColor », recopié dans le groupe d'apps pour les widgets)
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
    /// Teinte vue par les widgets
    static var current: CarPaint { CarPaint(rawValue: AppGroup.defaults.string(forKey: "carColor") ?? "") ?? .gris }
    /// Recopie le réglage de l'app pour les widgets et l'activité en direct
    static func partager(_ raw: String) {
        guard AppGroup.defaults.string(forKey: "carColor") != raw else { return }
        AppGroup.defaults.set(raw, forKey: "carColor")
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Visuel de la Kona hors de l'app : photo réaliste (réglage « carPhoto ») ou dessin teinté
/// Widgets et activité en direct. La photo réduite (KonaPhotoWidget.png) reste légère pour WidgetKit.
struct KonaVisuel: View {
    var charging = false
    var soc: Double?

    static let image: UIImage? = UIImage(named: "KonaPhotoWidget")?.preparingForDisplay()
    /// Réglage de l'app, recopié dans le groupe d'apps (photo par défaut)
    static var photo: Bool { AppGroup.defaults.object(forKey: "carPhoto") as? Bool ?? true }

    var body: some View {
        if Self.photo, let img = Self.image {
            Image(uiImage: img).resizable().scaledToFit()
                .accessibilityLabel("Kona")
        } else {
            KonaSide(paint: .current, charging: charging, soc: soc)
        }
    }

    /// Recopie le réglage de l'app pour les widgets et l'activité en direct
    static func partager(_ on: Bool) {
        guard AppGroup.defaults.object(forKey: "carPhoto") as? Bool != on else { return }
        AppGroup.defaults.set(on, forKey: "carPhoto")
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Géométrie (mètres → points). x : de l'avant (0) vers l'arrière, y : depuis le sol.
enum Dim {
    static let L: CGFloat = 4.18          // longueur
    static let H: CGFloat = 1.62          // hauteur avec barres de toit
    static let fw: CGFloat = 0.86         // centre de la roue avant
    static let rw: CGFloat = 3.46         // centre de la roue arrière
    static let wy: CGFloat = 0.33         // hauteur des moyeux
    static let tire: CGFloat = 0.33       // rayon du pneu
    static let rim: CGFloat = 0.225       // rayon de la jante
    static let arch: CGFloat = 0.41       // rayon des passages de roue
}

struct CarGeo {
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

func rond(_ c: CGPoint, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}

/// Arc en coordonnées voiture (angles en degrés, sens trigonométrique, y vers le haut)
func carArc(_ p: inout Path, _ g: CarGeo, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat,
            _ a0: CGFloat, _ a1: CGFloat, move: Bool) {
    let n = 20
    for i in 0...n {
        let a = (a0 + (a1 - a0) * CGFloat(i) / CGFloat(n)) * .pi / 180
        let pt = g.p(cx + r * cos(a), cy + r * sin(a))
        if i == 0 && move { p.move(to: pt) } else { p.addLine(to: pt) }
    }
}

/// Silhouette de la Kona Electric (SUV compact, capot court, toit fuyant, aileron, habillage noir)
enum Silhouette {
    static func body(_ g: CarGeo) -> Path {
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
        carArc(&p, g, Dim.rw, Dim.wy, Dim.arch, -8, 188, move: false)
        carArc(&p, g, Dim.fw, Dim.wy, Dim.arch, -8, 188, move: false)
        p.closeSubpath()
        return p
    }

    static func glass(_ g: CarGeo) -> Path {
        var p = Path()
        p.move(to: g.p(1.34, 1.07))
        p.addQuadCurve(to: g.p(2.00, 1.45), control: g.p(1.62, 1.34))
        p.addQuadCurve(to: g.p(3.50, 1.44), control: g.p(2.80, 1.52))
        p.addQuadCurve(to: g.p(3.86, 1.24), control: g.p(3.80, 1.42))
        p.addLine(to: g.p(3.84, 1.17))
        p.closeSubpath()
        return p
    }

    static func wells(_ g: CarGeo) -> Path {
        var p = Path()
        for cx in [Dim.fw, Dim.rw] {
            carArc(&p, g, cx, Dim.wy, Dim.arch, -8, 188, move: true)
            p.closeSubpath()
        }
        return p
    }

    /// Élargisseurs d'ailes (à remplir découpés par la carrosserie)
    static func arches(_ g: CarGeo) -> Path {
        var p = Path()
        for cx in [Dim.fw, Dim.rw] {
            carArc(&p, g, cx, Dim.wy, Dim.arch + 0.075, -10, 190, move: true)
            carArc(&p, g, cx, Dim.wy, Dim.arch - 0.01, 190, -10, move: false)
            p.closeSubpath()
        }
        return p
    }

    /// Bas de caisse et bas des boucliers (à remplir découpés par la carrosserie)
    static func lower(_ g: CarGeo) -> Path {
        var p = Path()
        p.addRect(g.rect(Dim.fw, 0.2, Dim.rw, 0.40))
        p.addRect(g.rect(0.0, 0.2, 0.5, 0.40))
        p.addRect(g.rect(3.85, 0.2, 4.3, 0.44))
        return p
    }

    static func pillarB(_ g: CarGeo) -> Path {
        Path { p in
            p.addLines([g.p(2.55, 1.11), g.p(2.63, 1.11), g.p(2.67, 1.49), g.p(2.59, 1.49)])
            p.closeSubpath()
        }
    }

    static func pillarC(_ g: CarGeo) -> Path {
        Path { p in
            p.addLines([g.p(3.30, 1.15), g.p(3.44, 1.15), g.p(3.60, 1.46), g.p(3.44, 1.47)])
            p.closeSubpath()
        }
    }

    static func rails(_ g: CarGeo) -> Path {
        Path { p in
            p.move(to: g.p(2.05, 1.548))
            p.addQuadCurve(to: g.p(3.55, 1.532), control: g.p(2.85, 1.598))
        }
    }

    static func doors(_ g: CarGeo) -> Path {
        var p = Path()
        p.move(to: g.p(1.36, 0.44))
        p.addQuadCurve(to: g.p(1.33, 1.06), control: g.p(1.40, 0.80))
        p.move(to: g.p(2.60, 0.41))
        p.addLine(to: g.p(2.60, 1.11))
        p.move(to: g.p(3.00, 0.44))
        p.addQuadCurve(to: g.p(3.30, 1.14), control: g.p(3.12, 0.98))
        return p
    }

    static func handles(_ g: CarGeo) -> Path {
        var p = Path()
        let r = CGSize(width: g.m(0.017), height: g.m(0.017))
        p.addRoundedRect(in: g.rect(2.18, 0.955, 2.36, 0.99), cornerSize: r)
        p.addRoundedRect(in: g.rect(3.00, 0.975, 3.16, 1.01), cornerSize: r)
        return p
    }

    static func mirror(_ g: CarGeo) -> Path {
        Path { p in
            p.move(to: g.p(1.36, 1.05))
            p.addQuadCurve(to: g.p(1.60, 1.12), control: g.p(1.50, 1.04))
            p.addQuadCurve(to: g.p(1.40, 1.19), control: g.p(1.58, 1.20))
            p.closeSubpath()
        }
    }

    static func shoulder(_ g: CarGeo) -> Path {
        Path { p in
            p.move(to: g.p(0.35, 0.93))
            p.addQuadCurve(to: g.p(4.10, 1.02), control: g.p(2.2, 0.95))
        }
    }

    static func crease(_ g: CarGeo) -> Path {
        Path { p in
            p.move(to: g.p(1.40, 0.60))
            p.addQuadCurve(to: g.p(3.00, 0.66), control: g.p(2.2, 0.60))
        }
    }

    static func drl(_ g: CarGeo) -> Path {
        Path { p in
            p.move(to: g.p(0.07, 0.86))
            p.addQuadCurve(to: g.p(0.50, 0.94), control: g.p(0.25, 0.92))
        }
    }

    static func headlamp(_ g: CarGeo) -> Path { Path(roundedRect: g.rect(0.01, 0.55, 0.26, 0.67), cornerRadius: g.m(0.04)) }

    static func tail(_ g: CarGeo) -> Path {
        Path { p in
            p.move(to: g.p(3.98, 1.14))
            p.addLine(to: g.p(4.13, 1.03))
        }
    }

    static func tailLow(_ g: CarGeo) -> Path { Path(roundedRect: g.rect(4.05, 0.55, 4.17, 0.63), cornerRadius: g.m(0.02)) }

    /// Batterie sous le plancher (affichée en charge)
    static func pack(_ g: CarGeo) -> CGRect { g.rect(1.42, 0.31, 2.94, 0.40) }
}

// MARK: - Kona fixe dessinée avec des formes (widgets, activité en direct, réglages)
struct KonaSide: View {
    var paint: CarPaint
    var charging = false
    var soc: Double?

    var body: some View {
        Color.clear
            .aspectRatio(Dim.L / Dim.H, contentMode: .fit)
            .overlay {
                GeometryReader { gr in
                    dessin(CarGeo(s: gr.size.width / Dim.L, x0: 0, gy: gr.size.height))
                }
            }
    }

    private func y(_ m: CGFloat) -> CGFloat { (Dim.H - m) / Dim.H }   // hauteur en mètres → fraction de la vue

    @ViewBuilder private func dessin(_ g: CarGeo) -> some View {
        let noir = Color(white: 0.09)
        ZStack {
            Silhouette.wells(g).fill(Color(white: 0.02))
            roue(g, Dim.fw)
            roue(g, Dim.rw)
            Silhouette.body(g).fill(LinearGradient(stops: [
                .init(color: paint.tone(1.35), location: 0),
                .init(color: paint.tone(1.0), location: 0.30),
                .init(color: paint.tone(1.22), location: 0.47),
                .init(color: paint.tone(0.92), location: 0.56),
                .init(color: paint.tone(0.6), location: 1),
            ], startPoint: UnitPoint(x: 0.5, y: y(1.58)), endPoint: UnitPoint(x: 0.5, y: y(0.27))))
            ZStack {
                Silhouette.arches(g).fill(noir)
                Silhouette.lower(g).fill(noir)
            }
            .clipShape(Silhouette.body(g))
            Silhouette.glass(g).fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.07), Color(white: 0.03)],
                                                    startPoint: UnitPoint(x: 0.5, y: y(1.5)), endPoint: UnitPoint(x: 0.5, y: y(1.07))))
            Silhouette.pillarB(g).fill(Color(white: 0.02))
            Silhouette.pillarC(g).fill(paint.tone(1.05))
            Silhouette.rails(g).stroke(Color(white: 0.12), style: StrokeStyle(lineWidth: g.m(0.035), lineCap: .round))
            Silhouette.doors(g).stroke(Color.black.opacity(0.35), lineWidth: 0.6)
            Silhouette.handles(g).fill(paint.tone(0.7))
            Silhouette.mirror(g).fill(Color(white: 0.08))
            Silhouette.shoulder(g).stroke(Color.white.opacity(0.22), lineWidth: max(0.6, g.m(0.012)))
            Silhouette.drl(g).stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: g.m(0.022), lineCap: .round))
            Silhouette.headlamp(g).fill(Color(white: 0.45))
            Silhouette.tail(g).stroke(Color(red: 0.95, green: 0.12, blue: 0.15).opacity(0.75),
                                      style: StrokeStyle(lineWidth: g.m(0.03), lineCap: .round))
            Silhouette.tailLow(g).fill(Color(red: 0.95, green: 0.12, blue: 0.15).opacity(0.5))
            if charging {
                let r = Silhouette.pack(g)
                let f = CGFloat(max(0.04, min(1, (soc ?? 60) / 100)))
                Path(roundedRect: r, cornerRadius: g.m(0.03)).fill(Color.black.opacity(0.75))
                Path(roundedRect: CGRect(x: r.minX + 1, y: r.minY + 1, width: (r.width - 2) * f, height: r.height - 2),
                     cornerRadius: g.m(0.02)).fill(Color.kTeal)
                    .shadow(color: Color.kTeal.opacity(0.8), radius: 3)
            }
        }
    }

    private func roue(_ g: CarGeo, _ cx: CGFloat) -> some View {
        let rt = g.m(Dim.tire), rr = g.m(Dim.rim)
        return ZStack {
            Circle().fill(Color(white: 0.06))
            Circle().fill(LinearGradient(colors: [Color(white: 0.80), Color(white: 0.45), Color(white: 0.62)], startPoint: .top, endPoint: .bottom))
                .frame(width: rr * 2, height: rr * 2)
            ForEach(0..<5, id: \.self) { k in
                RoundedRectangle(cornerRadius: rr * 0.1).fill(Color(white: 0.16))
                    .frame(width: rr * 0.6, height: rr * 0.26)
                    .offset(x: rr * 0.6)
                    .rotationEffect(.degrees(Double(k) * 72 + 18))
            }
            Circle().fill(Color(white: 0.55)).frame(width: rr * 0.4, height: rr * 0.4)
        }
        .frame(width: rt * 2, height: rt * 2)
        .position(g.p(cx, Dim.wy))
    }
}
