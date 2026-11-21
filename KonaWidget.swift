import ActivityKit
import SwiftUI
import WidgetKit

struct KonaEntry: TimelineEntry { let date: Date; let s: WidgetState? }

struct KonaProvider: TimelineProvider {
    func placeholder(in context: Context) -> KonaEntry {
        KonaEntry(date: .now, s: WidgetState(soc: 80, range: 320, kw: 0, gear: "P", v12: 12.6))
    }
    func getSnapshot(in context: Context, completion: @escaping (KonaEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : KonaEntry(date: .now, s: WidgetState.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<KonaEntry>) -> Void) {
        completion(Timeline(entries: [KonaEntry(date: .now, s: WidgetState.load())], policy: .after(.now.addingTimeInterval(1800))))
    }
}

private func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded())) %" } ?? "—" }
private func km(_ v: Int?) -> String { v.map { "\($0) km" } ?? "—" }

struct SocRing: View {
    let soc: Double?
    var width: CGFloat = 8
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: width)
            Circle().trim(from: 0, to: (soc ?? 0) / 100)
                .stroke(Color.soc(soc), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(soc.map { "\(Int($0.rounded()))" } ?? "—")
                .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Color.soc(soc))
        }
    }
}

/// Batterie horizontale fine (widgets, écran verrouillé)
struct MiniBattery: View {
    let soc: Double?
    var body: some View {
        let f = max(0, min(1, (soc ?? 0) / 100))
        HStack(spacing: 1.5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(.white.opacity(0.4), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.soc(soc))
                        .frame(width: max(2, (g.size.width - 4) * CGFloat(f)))
                        .padding(2)
                }
            }
            RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.4)).frame(width: 2, height: 5)
        }
        .frame(height: 13)
    }
}

struct KonaWidgetView: View {
    @Environment(\.widgetFamily) var family
    let e: KonaEntry

    var body: some View {
        let s = e.s
        switch family {
        case .accessoryCircular:
            Gauge(value: (s?.soc ?? 0) / 100) {
                Image(systemName: s?.charging == true ? "bolt.fill" : "car.fill")
            } currentValueLabel: {
                Text(s?.soc.map { "\(Int($0.rounded()))" } ?? "—")
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Kona \(pct(s?.soc))").font(.headline)
                Text("\(km(s?.range))\(s?.charging == true ? " · en charge" : "")")
                Text(s?.date ?? .now, style: .relative).font(.caption2)
            }
        case .accessoryInline:
            Text("Kona \(pct(s?.soc)) · \(km(s?.range))")
        case .systemMedium:
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    entete(s)
                    autonomie(s, taille: 34)
                    jauge(s)
                    Spacer(minLength: 0)
                    Text(ligne(s)).font(.caption.weight(.semibold))
                        .foregroundStyle(s?.charging == true ? Color.kTeal : Color.kSub)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    row("minus.plus.batteryblock.fill", s?.v12.map { String(format: "%.2f V", $0).replacingOccurrences(of: ".", with: ",") } ?? "—",
                        (s?.v12 ?? 13) < 12.2 ? .kRed : .kSub)
                }
                KonaSide(paint: .current, charging: s?.charging == true, soc: s?.soc)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                entete(s)
                autonomie(s, taille: 30)
                jauge(s)
                Spacer(minLength: 0)
                KonaSide(paint: .current, charging: s?.charging == true, soc: s?.soc)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func entete(_ s: WidgetState?) -> some View {
        HStack(spacing: 4) {
            Text("KONA").font(.caption2.weight(.semibold)).tracking(1.5).foregroundStyle(Color.kSub)
            Spacer(minLength: 4)
            if s?.charging == true {
                Image(systemName: "bolt.fill").font(.caption).foregroundStyle(Color.kTeal)
            } else {
                Text(s?.date ?? .now, style: .relative).font(.caption2).foregroundStyle(Color.kSub)
                    .lineLimit(1).minimumScaleFactor(0.6).multilineTextAlignment(.trailing)
            }
        }
    }

    private func autonomie(_ s: WidgetState?, taille: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(s?.range.map(String.init) ?? "—").font(.system(size: taille, weight: .semibold, design: .rounded))
                .foregroundStyle(.white).minimumScaleFactor(0.6).lineLimit(1)
            Text("km").font(.caption.weight(.medium)).foregroundStyle(Color.kSub)
        }
    }

    private func jauge(_ s: WidgetState?) -> some View {
        HStack(spacing: 6) {
            MiniBattery(soc: s?.soc).frame(width: 36)
            Text(pct(s?.soc)).font(.caption.weight(.semibold)).foregroundStyle(Color.soc(s?.soc))
        }
    }

    private func ligne(_ s: WidgetState?) -> String {
        if s?.charging == true {
            if let m = s?.minLeft, let c = s?.cible { return "\(c) % dans \(m) min" }
            return "En charge" + (s?.kw.map { String(format: " · %.1f kW", abs($0)).replacingOccurrences(of: ".", with: ",") } ?? "")
        }
        return s?.connected == true ? "En route · Bluetooth" : "Garée"
    }

    private func row(_ i: String, _ t: String, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: i).font(.caption).foregroundStyle(c).frame(width: 16)
            Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
        }
    }
}

struct KonaStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KonaStatus", provider: KonaProvider()) { e in
            KonaWidgetView(e: e)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [.kBg2, .kBg1], startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("Kona")
        .description("Charge, autonomie et 12 V de la Kona.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct KonaLockView: View {
    let st: KonaActivityAttributes.ContentState
    let title: String
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(Color.kSub)
                    Text(st.updated, style: .time).font(.caption2).foregroundStyle(Color.kSub)
                }
                Text("≈ \(st.range) km").font(.title2.weight(.semibold)).foregroundStyle(.white)
                HStack(spacing: 6) {
                    MiniBattery(soc: st.soc).frame(width: 32)
                    Text("\(Int(st.soc.rounded())) %").font(.caption.weight(.semibold)).foregroundStyle(Color.soc(st.soc))
                }
                Text(st.charging ? (st.minLeft > 0 ? "\(st.cible) % dans ≈ \(st.minLeft) min" : String(format: "En charge · %.1f kW", abs(st.kw))) : "\(st.speed) km/h · \(st.gear)")
                    .font(.subheadline).foregroundStyle(st.charging ? Color.kTeal : .white)
            }
            Spacer(minLength: 0)
            KonaSide(paint: .current, charging: st.charging, soc: st.soc).frame(width: 128)
        }
    }
}

/// Activité en direct dans CarPlay (iOS 26) et la pile intelligente de l'Apple Watch : très lisible, deux lignes
struct KonaCarView: View {
    let st: KonaActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 10) {
            SocRing(soc: st.soc, width: 6).frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text("≈ \(st.range) km").font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
                Text(ligne).font(.caption.weight(.semibold)).foregroundStyle(couleur)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
    }
    private var couleur: Color {
        if !st.portail.isEmpty || !st.garage.isEmpty { return st.portail == "closed" && st.garage == "closed" ? .kTeal : .kRed }
        return st.charging ? .kTeal : .secondary
    }
    private var ligne: String {
        if !st.portail.isEmpty || !st.garage.isEmpty {
            if st.portail == "closed" && st.garage == "closed" { return "Portail ✓ · Garage ✓" }
            let nom = ["open": "ouvert", "opening": "s'ouvre", "closing": "se ferme", "closed": "✓"]
            return "Portail \(nom[st.portail] ?? "?") · Garage \(nom[st.garage] ?? "?")"
        }
        if st.charging { return st.minLeft > 0 ? "\(st.cible) % dans \(st.minLeft) min" : String(format: "Charge %.0f kW", abs(st.kw)) }
        if st.tripKm >= 1 {
            return "\(Int(st.tripKm)) km" + (st.tripConso > 0 ? String(format: " · %.1f kWh/100", st.tripConso).replacingOccurrences(of: ".", with: ",") : "")
        }
        return String(format: "%.0f kW · %d km/h", st.kw, st.speed)
    }
}

struct KonaActivityView: View {
    @Environment(\.activityFamily) private var family
    let st: KonaActivityAttributes.ContentState
    let title: String
    var body: some View {
        switch family {
        case .small: KonaCarView(st: st)
        default: KonaLockView(st: st, title: title).padding(16)
        }
    }
}

struct KonaLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KonaActivityAttributes.self) { ctx in
            KonaActivityView(st: ctx.state, title: ctx.attributes.title)
                .activityBackgroundTint(Color.kBg1)
                .activitySystemActionForegroundColor(Color.kTeal)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(pct(ctx.state.soc), systemImage: ctx.state.charging ? "bolt.fill" : "car.fill")
                        .font(.headline).foregroundStyle(Color.soc(ctx.state.soc))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("≈ \(ctx.state.range) km").font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(String(format: "%.1f kW", abs(ctx.state.kw)).replacingOccurrences(of: ".", with: ","))
                        Spacer()
                        Text(ctx.state.charging ? (ctx.state.minLeft > 0 ? "\(ctx.state.cible) % dans \(ctx.state.minLeft) min" : "En charge") : "\(ctx.state.speed) km/h · \(ctx.state.gear)")
                    }
                    .font(.subheadline).foregroundStyle(Color.kSub)
                }
            } compactLeading: {
                Image(systemName: ctx.state.charging ? "bolt.fill" : "car.fill").foregroundStyle(Color.soc(ctx.state.soc))
            } compactTrailing: {
                Text("\(Int(ctx.state.soc.rounded()))%").foregroundStyle(Color.soc(ctx.state.soc))
            } minimal: {
                Text("\(Int(ctx.state.soc.rounded()))").foregroundStyle(Color.soc(ctx.state.soc))
            }
        }
        .supplementalActivityFamilies([.small, .medium])
    }
}

@main
struct KonaWidgets: WidgetBundle {
    var body: some Widget {
        KonaStatusWidget()
        KonaLiveActivity()
    }
}
