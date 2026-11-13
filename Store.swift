import CoreLocation
import Foundation

struct GeoPt: Codable { var lat: Double; var lon: Double; var kw: Double? }
struct TripSample: Codable { var s: Int; var kw: Double; var soc: Double?; var kmh: Int? }      // s : secondes depuis le départ
struct ChargeSample: Codable { var s: Int; var kw: Double; var soc: Double? }

struct Trip: Codable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date
    var odoStart: Int?
    var odoEnd: Int?
    var kwh = 0.0                 // énergie nette : déchargée - récupérée
    var socStart: Double?
    var socEnd: Double?
    var maxKmh = 0
    var pts: [GeoPt] = []
    var samples: [TripSample]?
    var km: Double? { if let a = odoStart, let b = odoEnd, b >= a { return Double(b - a) }; return nil }
    var conso: Double? { guard let k = km, k >= 1, kwh > 0 else { return nil }; return kwh / k * 100 }
    var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

struct Charge: Codable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date
    var socStart: Double?
    var socEnd: Double?
    var kwh = 0.0
    var maxKw = 0.0
    var lat: Double?
    var lon: Double?
    var lieu: String?
    var samples: [ChargeSample]?
}

struct Parking: Codable { var lat: Double; var lon: Double; var date: Date }
struct LogEntry: Codable, Identifiable { var id = UUID(); var date = Date(); var text: String }

/// Historique local de l'app : trajets (tracé GPS), recharges hors maison, stationnement, journal
final class Store: ObservableObject {
    static let shared = Store()
    @Published var trips: [Trip] = []
    @Published var charges: [Charge] = []
    @Published var parking: Parking?
    @Published var log: [LogEntry] = []
    @Published var curTrip: Trip?
    @Published var curCharge: Charge?

    private struct Saved: Codable { var trips: [Trip]; var charges: [Charge]; var parking: Parking?; var log: [LogEntry] }
    private var cedStart: Double?, cecStart: Double?, cecCharge: Double?
    private var lastPt: CLLocation?
    private var pSince: Date?
    private var notChg = 0
    private var lastKw: Double?
    private var unsaved = 0
    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("kona.json")

    init() {
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            trips = s.trips; charges = s.charges; parking = s.parking; log = s.log
        }
    }

    func save() {
        unsaved = 0
        let s = Saved(trips: trips, charges: charges, parking: parking, log: log)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }

    func note(_ t: String) {
        log.append(LogEntry(text: t))
        if log.count > 400 { log.removeFirst(log.count - 400) }
        unsaved += 1
        if unsaved >= 5 { save() }
    }

    // MARK: Autonomie : conso des ~300 derniers km parcourus
    var conso: Double {
        var km = 0.0, kwh = 0.0
        for t in trips {
            guard let k = t.km, k >= 2, t.kwh > 0 else { continue }
            km += k; kwh += t.kwh
            if km >= 300 { break }
        }
        if km >= 20 { return kwh / km * 100 }
        let d = UserDefaults.standard.double(forKey: "consoDefaut")
        return d > 0 ? d : 15.5
    }

    func range(_ soc: Double?) -> Int? {
        guard let s = soc, conso > 0 else { return nil }
        return Int(s / 100 * 64 / conso * 100)
    }

    // MARK: Détection des trajets et recharges
    func feed(_ k: KonaData, loc: CLLocation?) {
        lastKw = k.kw
        let moving = ["D", "R", "N"].contains(k.gear ?? "")
        let soc = k.soc ?? k.socBms
        if moving {
            if curTrip == nil {
                curTrip = Trip(start: Date(), end: Date(), odoStart: k.odo, socStart: soc)
                cedStart = k.ced; cecStart = k.cec; lastPt = nil
                note("Début de trajet")
            }
            pSince = nil
        } else if curTrip != nil {
            if pSince == nil { pSince = Date() }
            if let p = pSince, Date().timeIntervalSince(p) > 120 { finishTrip(loc) }
        }
        if var t = curTrip {
            t.end = Date()
            if let o = k.odo { t.odoEnd = o; if t.odoStart == nil { t.odoStart = o } }
            if let s = soc { t.socEnd = s }
            if let d = k.ced, let c = k.cec, let d0 = cedStart, let c0 = cecStart { t.kwh = max(0, (d - d0) - (c - c0)) }
            if let v = k.speed { t.maxKmh = max(t.maxKmh, v) }
            var sm = t.samples ?? []
            sm.append(TripSample(s: Int(Date().timeIntervalSince(t.start)), kw: k.kw ?? 0, soc: soc, kmh: k.speed))
            if sm.count > 2000 { sm.removeFirst() }
            t.samples = sm
            curTrip = t
        }
        if k.charging {
            notChg = 0
            if curCharge == nil {
                curCharge = Charge(start: Date(), end: Date(), socStart: soc, lat: loc?.coordinate.latitude, lon: loc?.coordinate.longitude)
                cecCharge = k.cec
                note("Début de recharge")
            }
            if var c = curCharge {
                c.end = Date(); c.socEnd = soc
                if let e = k.cec, let e0 = cecCharge { c.kwh = max(0, e - e0) }
                c.maxKw = max(c.maxKw, abs(k.kw ?? 0))
                if c.lat == nil, let l = loc { c.lat = l.coordinate.latitude; c.lon = l.coordinate.longitude }
                var sm = c.samples ?? []
                sm.append(ChargeSample(s: Int(Date().timeIntervalSince(c.start)), kw: abs(k.kw ?? 0), soc: soc))
                if sm.count > 1500 { sm.removeFirst() }
                c.samples = sm
                curCharge = c
            }
        } else if curCharge != nil {
            notChg += 1
            if notChg >= 2 { finishCharge() }
        }
    }

    /// Fusionne une sauvegarde (par identifiant), renvoie le nombre d'éléments ajoutés
    func merge(trips t: [Trip], charges c: [Charge]) -> Int {
        let ti = Set(trips.map(\.id)), ci = Set(charges.map(\.id))
        let nt = t.filter { !ti.contains($0.id) }, nc = c.filter { !ci.contains($0.id) }
        trips += nt; charges += nc
        trips.sort { $0.start > $1.start }; charges.sort { $0.start > $1.start }
        save()
        return nt.count + nc.count
    }

    func addPoint(_ l: CLLocation) {
        guard var t = curTrip, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 50 else { return }
        if let p = lastPt, l.distance(from: p) < 40 { return }
        lastPt = l
        t.pts.append(GeoPt(lat: l.coordinate.latitude, lon: l.coordinate.longitude, kw: lastKw))
        if t.pts.count > 3000 { t.pts.removeFirst() }
        curTrip = t
    }

    func disconnected(_ loc: CLLocation?) {
        if curTrip != nil { finishTrip(loc) }
        if curCharge != nil { finishCharge() }
    }

    private func finishTrip(_ loc: CLLocation?) {
        guard let t = curTrip else { return }
        curTrip = nil; pSince = nil
        if (t.km ?? 0) >= 0.5 || t.minutes >= 2 {
            trips.insert(t, at: 0)
            if trips.count > 300 { trips.removeLast() }
            note("Fin de trajet : \(Int(t.km ?? 0)) km, \(String(format: "%.1f", t.kwh)) kWh")
            BLERelay.shared.backup(trip: t)
        }
        let p = loc ?? lastPt
        if let p { parking = Parking(lat: p.coordinate.latitude, lon: p.coordinate.longitude, date: Date()) }
        else if let g = t.pts.last { parking = Parking(lat: g.lat, lon: g.lon, date: Date()) }
        save()
    }

    private func finishCharge() {
        guard let c = curCharge else { return }
        curCharge = nil; notChg = 0
        guard c.kwh >= 0.3 || c.end.timeIntervalSince(c.start) > 300 else { return }
        charges.insert(c, at: 0)
        if charges.count > 200 { charges.removeLast() }
        note("Fin de recharge : \(String(format: "%.1f", c.kwh)) kWh")
        save()
        BLERelay.shared.backup(charge: c)
        BLERelay.shared.notify("+\(fr(c.kwh)) kWh en \(Int(c.end.timeIntervalSince(c.start) / 60)) min, SOC \(fr(c.socStart, 0)) → \(fr(c.socEnd, 0)) %",
                               title: "🔌 Recharge terminée", id: "charge")
        if let la = c.lat, let lo = c.lon {
            let id = c.id
            CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: la, longitude: lo)) { pm, _ in
                guard let p = pm?.first else { return }
                let lieu = [p.name, p.locality].compactMap { $0 }.joined(separator: ", ")
                DispatchQueue.main.async {
                    if let i = self.charges.firstIndex(where: { $0.id == id }) {
                        self.charges[i].lieu = lieu; self.save()
                        BLERelay.shared.backup(charge: self.charges[i])
                    }
                }
            }
        }
    }
}
