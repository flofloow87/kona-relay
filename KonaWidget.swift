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
            HStack(spacing: 16) {
                SocRing(soc: s?.soc, width: 10).frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Kona Electric").font(.headline).foregroundStyle(.white)
                    row("road.lanes", km(s?.range), .kTeal)
                    row(s?.charging == true ? "bolt.fill" : "gauge.with.dots.needle.33percent",
                        s?.kw.map { String(format: "%.1f kW", abs($0)).replacingOccurrences(of: ".", with: ",") } ?? "—", .kGold)
                    row("minus.plus.batteryblock.fill", s?.v12.map { String(format: "%.2f V", $0).replacingOccurrences(of: ".", with: ",") } ?? "—", .kBlue)
                    Text(s?.date ?? .now, style: .relative).font(.caption2).foregroundStyle(Color.kSub)
                }
                Spacer(minLength: 0)
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    SocRing(soc: s?.soc, width: 9).frame(width: 64, height: 64)
                    Spacer()
                    if s?.charging == true { Image(systemName: "bolt.fill").font(.title3).foregroundStyle(Color.kTeal) }
                }
                Spacer(minLength: 0)
                Text(km(s?.range)).font(.title2.weight(.bold)).foregroundStyle(.white).minimumScaleFactor(0.7).lineLimit(1)
                Group {
                    if s?.charging == true, let m = s?.minLeft, let c = s?.cible { Text("\(c) % dans \(m) min") }
                    else { Text(s?.date ?? .now, style: .relative) }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(s?.charging == true ? Color.kTeal : Color.kSub).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
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
        HStack(spacing: 14) {
            SocRing(soc: st.soc, width: 7).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(Color.kSub)
                Text("≈ \(st.range) km").font(.title3.weight(.bold)).foregroundStyle(.white)
                Text(st.charging ? (st.minLeft > 0 ? "\(st.cible) % dans ≈ \(st.minLeft) min" : String(format: "En charge · %.1f kW", abs(st.kw))) : "\(st.speed) km/h · \(st.gear)")
                    .font(.subheadline).foregroundStyle(st.charging ? Color.kTeal : .white)
            }
            Spacer()
            Text(st.updated, style: .time).font(.caption2).foregroundStyle(Color.kSub)
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
                Text(ligne).font(.caption.weight(.semibold)).foregroundStyle(st.charging ? Color.kTeal : .secondary)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
    }
    private var ligne: String {
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
