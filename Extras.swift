import Charts
import PhotosUI
import SwiftUI

private func euros(_ v: Double?) -> String { String(format: "%.2f €", v ?? 0).replacingOccurrences(of: ".", with: ",") }

// MARK: - Origine de l'énergie d'une recharge maison (HC, HP, solaire, batterie maison)
struct MixBar: View {
    let c: HomeCharge
    var body: some View {
        let parts: [(String, Double, Color)] = [("HC", c.kwh_hc ?? 0, .kBlue), ("HP", c.kwh_hp ?? 0, .kRed),
                                                ("Solaire", c.kwh_solaire ?? 0, .kGold), ("Batterie", c.kwh_zendure ?? 0, .kTeal)]
        let tot = max(parts.map(\.1).reduce(0, +), 0.01)
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(parts.indices, id: \.self) { i in
                        if parts[i].1 > 0 { Rectangle().fill(parts[i].2).frame(width: g.size.width * parts[i].1 / tot) }
                    }
                }
            }
            .frame(height: 6).clipShape(Capsule())
            Text(parts.filter { $0.1 >= 0.05 }.map { "\($0.0) \(fr($0.1))" }.joined(separator: " · ") + " kWh")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 14. Comparer les bornes : puissance selon le niveau de charge
struct BornesView: View {
    @EnvironmentObject var st: Store

    private struct Pt: Identifiable { let id = UUID(); let lieu: String; let soc: Double; let kw: Double }
    private struct Borne: Identifiable {
        let lieu: String; let n: Int; let maxKw: Double; let moyKw: Double?; let kwh: Double
        var id: String { lieu }
    }

    private var groupes: [String: [Charge]] {
        Dictionary(grouping: st.charges.filter { ($0.samples?.count ?? 0) >= 3 }) { $0.lieu ?? "Lieu inconnu" }
    }
    private var bornes: [Borne] {
        groupes.map { l, cs in
            let pts = cs.flatMap { $0.samples ?? [] }.filter { ($0.soc ?? 0) >= 10 && ($0.soc ?? 100) <= 80 && $0.kw > 0.5 }
            return Borne(lieu: l, n: cs.count, maxKw: cs.map(\.maxKw).max() ?? 0,
                         moyKw: pts.isEmpty ? nil : pts.map(\.kw).reduce(0, +) / Double(pts.count), kwh: cs.map(\.kwh).reduce(0, +))
        }
        .sorted { ($0.moyKw ?? 0) > ($1.moyKw ?? 0) }
    }
    /// Courbe moyenne par tranche de 5 % de SOC, pour les 5 lieux les plus utilisés
    private var courbes: [Pt] {
        let top = groupes.sorted { $0.value.count > $1.value.count }.prefix(5)
        return top.flatMap { l, cs -> [Pt] in
            let sm = cs.flatMap { $0.samples ?? [] }.filter { $0.soc != nil && $0.kw > 0.5 }
            let parTranche = Dictionary(grouping: sm) { Int(($0.soc ?? 0) / 5) * 5 }
            return parTranche.keys.sorted().map { k in
                let v = parTranche[k]!; return Pt(lieu: l, soc: Double(k) + 2.5, kw: v.map(\.kw).reduce(0, +) / Double(v.count))
            }
        }
    }

    var body: some View {
        List {
            if bornes.isEmpty {
                Text("Pas encore de recharge sur borne enregistrée avec sa courbe. Elles apparaîtront ici après tes prochaines recharges hors de la maison.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    Chart(courbes) { p in
                        LineMark(x: .value("SOC", p.soc), y: .value("kW", p.kw))
                            .foregroundStyle(by: .value("Lieu", p.lieu))
                            .interpolationMethod(.monotone)
                    }
                    .chartXAxisLabel("Niveau de charge (%)").chartYAxisLabel("kW")
                    .chartXScale(domain: 0...100)
                    .frame(height: 240)
                } header: {
                    Text("Puissance selon le niveau de charge")
                } footer: {
                    Text("Moyenne de toutes les recharges de chaque lieu (5 lieux les plus utilisés).")
                }
                Section("Classement (puissance moyenne entre 10 et 80 %)") {
                    ForEach(bornes) { b in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(b.lieu).font(.headline).lineLimit(1)
                                Spacer()
                                Text(b.moyKw.map { "\(fr($0, 0)) kW" } ?? "—").font(.headline).foregroundStyle(Color.kTeal)
                            }
                            Text("\(b.n) recharge\(b.n > 1 ? "s" : "") · maxi \(fr(b.maxKw, 0)) kW · \(fr(b.kwh, 0)) kWh au total")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Comparer les bornes")
    }
}

// MARK: - 18. Carnet d'entretien (factures en photo, kilométrage)
struct Entretien: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var titre = ""
    var km: Int?
    var cout: Double?
    var note = ""
    var photos: [String] = []
}

final class EntretienStore: ObservableObject {
    static let shared = EntretienStore()
    @Published var items: [Entretien] = []
    private let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("entretien", isDirectory: true)
    private var file: URL { dir.appendingPathComponent("carnet.json") }

    private init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file), let l = try? d.decode([Entretien].self, from: data) { items = l }
    }
    func save() {
        items.sort { $0.date > $1.date }
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let d = try? e.encode(items) { try? d.write(to: file, options: .atomic) }
    }
    func upsert(_ x: Entretien) {
        if let i = items.firstIndex(where: { $0.id == x.id }) { items[i] = x } else { items.append(x) }
        save()
    }
    func delete(_ x: Entretien) {
        x.photos.forEach { try? FileManager.default.removeItem(at: dir.appendingPathComponent($0)) }
        items.removeAll { $0.id == x.id }; save()
    }
    func photoURL(_ n: String) -> URL { dir.appendingPathComponent(n) }
    func addPhoto(_ data: Data) -> String? {
        guard let img = UIImage(data: data), let jpg = img.jpegData(compressionQuality: 0.7) else { return nil }
        let n = UUID().uuidString + ".jpg"
        return (try? jpg.write(to: photoURL(n))) != nil ? n : nil
    }
    func image(_ n: String) -> UIImage? { UIImage(contentsOfFile: photoURL(n).path) }
}

struct EntretienView: View {
    @StateObject private var s = EntretienStore.shared
    @State private var edit: Entretien?

    var body: some View {
        List {
            if s.items.isEmpty {
                Text("Aucune intervention. Ajoute tes révisions, pneus, factures… avec une photo de la facture.").foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(s.items) { x in
                        NavigationLink { EntretienDetail(x: x, edit: $edit) } label: {
                            HStack(spacing: 12) {
                                if let p = x.photos.first, let img = s.image(p) {
                                    Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    Image(systemName: "wrench.and.screwdriver.fill").frame(width: 44, height: 44).foregroundStyle(Color.kGold)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(x.titre.isEmpty ? "Intervention" : x.titre).font(.headline)
                                    Text(x.date.formatted(date: .abbreviated, time: .omitted) + (x.km.map { " · \($0) km" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let c = x.cout { Text(euros(c)).font(.subheadline.weight(.semibold)) }
                            }
                        }
                    }
                    .onDelete { i in i.map { s.items[$0] }.forEach(s.delete) }
                } header: {
                    Text("\(s.items.count) interventions · \(euros(s.items.compactMap(\.cout).reduce(0, +)))")
                }
            }
        }
        .navigationTitle("Carnet d'entretien")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { edit = Entretien(km: BLERelay.shared.data?.odo) } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $edit) { x in EntretienForm(x: x) }
    }
}

struct EntretienDetail: View {
    let x: Entretien
    @Binding var edit: Entretien?
    @State private var plein: String?
    @ObservedObject private var s = EntretienStore.shared
    var body: some View {
        let cur = s.items.first { $0.id == x.id } ?? x
        List {
            Section {
                LabeledContent("Date", value: cur.date.formatted(date: .long, time: .omitted))
                if let k = cur.km { LabeledContent("Kilométrage", value: "\(k) km") }
                if let c = cur.cout { LabeledContent("Coût", value: euros(c)) }
                if !cur.note.isEmpty { Text(cur.note) }
            }
            if !cur.photos.isEmpty {
                Section("Factures et photos") {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(cur.photos, id: \.self) { p in
                                if let img = s.image(p) {
                                    Image(uiImage: img).resizable().scaledToFill().frame(width: 120, height: 160)
                                        .clipShape(RoundedRectangle(cornerRadius: 10)).onTapGesture { plein = p }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(cur.titre.isEmpty ? "Intervention" : cur.titre)
        .toolbar { Button("Modifier") { edit = cur } }
        .fullScreenCover(item: Binding(get: { plein.map { PhotoID(n: $0) } }, set: { plein = $0?.n })) { p in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                if let img = s.image(p.n) { Image(uiImage: img).resizable().scaledToFit() }
                Button { plein = nil } label: { Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.white) }.padding()
            }
        }
    }
    private struct PhotoID: Identifiable { let n: String; var id: String { n } }
}

struct EntretienForm: View {
    @Environment(\.dismiss) private var dismiss
    @State var x: Entretien
    @State private var sel: [PhotosPickerItem] = []
    @State private var km = ""
    @State private var cout = ""
    private let modeles = ["Révision", "Pneus", "Liquide de frein", "Filtre d'habitacle", "Batterie 12 V", "Essuie-glaces", "Contrôle technique", "Carrosserie"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Intitulé", text: $x.titre)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(modeles, id: \.self) { m in Button(m) { x.titre = m }.buttonStyle(.bordered).font(.caption) } }
                    }
                    DatePicker("Date", selection: $x.date, displayedComponents: .date)
                    TextField("Kilométrage", text: $km).keyboardType(.numberPad)
                    TextField("Coût (€)", text: $cout).keyboardType(.decimalPad)
                }
                Section("Notes") { TextField("Garage, détails…", text: $x.note, axis: .vertical).lineLimit(3...8) }
                Section("Factures et photos") {
                    PhotosPicker(selection: $sel, maxSelectionCount: 6, matching: .images) { Label("Ajouter des photos", systemImage: "photo.on.rectangle") }
                    if !x.photos.isEmpty { Text("\(x.photos.count) photo(s)").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Intervention")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        x.km = Int(km.filter(\.isNumber)); x.cout = Double(cout.replacingOccurrences(of: ",", with: "."))
                        EntretienStore.shared.upsert(x); dismiss()
                    }
                }
            }
            .onAppear { km = x.km.map(String.init) ?? ""; cout = x.cout.map { fr($0, 2) } ?? "" }
            .onChange(of: sel) { _, items in
                Task {
                    for it in items { if let d = try? await it.loadTransferable(type: Data.self), let n = EntretienStore.shared.addPhoto(d) { x.photos.append(n) } }
                    sel = []
                }
            }
        }
        .preferredColorScheme(Theme.scheme)
    }
}

// MARK: - 30. Ma Kona : identité, batterie, logiciels, codes défaut
private struct MaKonaFile: Decodable {
    struct Ecu: Decodable, Identifiable { var id: String; var nom: String; var version: String }
    struct Dtc: Decodable, Hashable { var code: String; var ecu: String }
    var fw: String?; var vin: String?; var ecus: [Ecu]; var invDate: String?; var dtc: [Dtc]; var dtcDate: String?
}
private struct SOHPts: Decodable { struct P: Decodable { var d: String; var soh: Double }; var hist: [P] }

struct MaKonaView: View {
    @EnvironmentObject var r: BLERelay
    @EnvironmentObject var st: Store
    @AppStorage("achat") private var achat = 0.0
    @AppStorage("achatKm") private var achatKm = 0
    @State private var f: MaKonaFile?
    @State private var soh: Double?

    private func date(_ s: String?) -> String {
        guard let s, let d = ISO8601DateFormatter().date(from: s) ?? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s) }() else { return "—" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        let odo = r.data?.odo
        List {
            Section("Véhicule") {
                LabeledContent("Modèle", value: "Kona Electric 64 kWh")
                LabeledContent("VIN", value: (f?.vin).flatMap { $0.isEmpty ? nil : $0 } ?? "non lu par l'ESP32")
                LabeledContent("Kilométrage", value: odo.map { "\($0) km" } ?? "—")
                DatePicker("Date d'achat", selection: Binding(get: { achat > 0 ? Date(timeIntervalSince1970: achat) : Date() },
                                                              set: { achat = $0.timeIntervalSince1970 }), displayedComponents: .date)
                Stepper(value: $achatKm, in: 0...300_000, step: 500) { LabeledContent("Km à l'achat", value: "\(achatKm)") }
                if achat > 0, let o = odo, o > achatKm {
                    let ans = max(Date().timeIntervalSince1970 - achat, 86400 * 30) / (365.25 * 86400)
                    LabeledContent("Depuis l'achat", value: "\(o - achatKm) km · \(fr(Double(o - achatKm) / ans, 0)) km/an")
                }
            }
            Section("Batterie") {
                LabeledContent("État de santé (SOH)", value: soh.map { "\(fr($0)) %" } ?? "—")
                if let s = soh { LabeledContent("Capacité estimée", value: "\(fr(64 * s / 100)) kWh") }
                LabeledContent("12 V", value: (r.data?.v12d ?? r.data?.v12).map { "\(fr($0, 2)) V" } ?? "—")
                LabeledContent("Trajets enregistrés", value: "\(st.trips.count) · \(fr(st.conso)) kWh/100 km")
            }
            Section {
                LabeledContent("Firmware ESP32", value: f?.fw ?? "—")
                ForEach(f?.ecus ?? []) { e in LabeledContent(e.nom.prefix(1).uppercased() + e.nom.dropFirst(), value: e.version) }
            } header: { Text("Logiciels") } footer: {
                if let d = f?.invDate { Text("Inventaire du \(date(d)). Une mise à jour en concession est signalée par notification.") }
            }
            Section {
                if let l = f?.dtc, !l.isEmpty {
                    ForEach(l, id: \.self) { d in LabeledContent(d.code, value: d.ecu) }
                } else {
                    Label(f == nil ? "Chargement…" : "Aucun code défaut", systemImage: f == nil ? "hourglass" : "checkmark.circle.fill")
                        .foregroundStyle(f == nil ? Color.secondary : Color.kTeal)
                }
            } header: { Text("Codes défaut") } footer: {
                if let d = f?.dtcDate { Text("Dernier contrôle le \(date(d)).") }
            }
        }
        .navigationTitle("Ma Kona")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        f = await r.haJSON("ma_kona.json")
        if let s: SOHPts = await r.haJSON("soh.json") { soh = s.hist.last?.soh }
    }
}
