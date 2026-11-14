import CoreBluetooth
import CoreLocation
import CryptoKit
import Foundation
import BackgroundTasks
import UIKit
import UserNotifications
import WidgetKit

private struct HABackup: Decodable { var trips: [String: Trip]?; var charges: [String: Charge]? }
/// État de la voiture publié par Home Assistant (etat.json) quand l'ESP32 est au WiFi maison
private struct HAEtat: Decodable {
    var lecture: String?
    var soc: Double?; var socBms: Double?; var kw: Double?; var volts: Double?; var v12: Double?
    var tMin: Int?; var tMax: Int?; var odo: Int?; var gear: String?; var charging: Bool?
    var portail: String?; var portailT: String?; var garage: String?; var garageT: String?
}

final class BLERelay: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, CLLocationManagerDelegate {
    static let shared = BLERelay()
    static func uuid(_ n: Int) -> CBUUID { CBUUID(string: String(format: "6E4B%04X-9A3C-4F2B-8C11-4B4F4E415343", n)) }
    static let svc = uuid(1), dat = uuid(2), cmd = uuid(3), ack = uuid(4), ota = uuid(5)

    @Published var status = "Démarrage"
    @Published var connected = false              // abonné aux données de l'ESP32
    @Published var data: KonaData?
    @Published var lastSent: Date?
    @Published var busy: KonaCommand?
    @Published var toast: String?
    @Published var hasGPS = false
    @Published var tripSync: Date?                // dernier trajet synchronisé par Bluetooth
    @Published var otaProgress: Double?           // mise à jour du firmware en cours (0…1)
    @Published var eco = false                    // économie : batterie de l'iPhone faible
    @Published var pendingCount = 0               // sauvegardes en attente (zone blanche)
    private var depart: Date?                     // début du trajet (portail/garage affichés 10 min)
    private var portes: (p: String, g: String)?
    @Published var haSync: Date?                  // dernière lecture réussie dans Home Assistant
    private var haTimer: Timer?
    @Published var espNets: (m: String, p: [String], url: Bool)?
    private var netQueue: [String] = []
    private var flushing = false

    private var cm: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var ackChar: CBCharacteristic?
    private var otaChar: CBCharacteristic?
    private var lastPost = Date.distantPast
    private var lastPostOK = true
    private var buf = Data()
    private let ud = UserDefaults.standard
    private let lm = CLLocationManager()
    private var loc: CLLocation?
    private var toastTask: DispatchWorkItem?
    private var otaData = Data()
    private var otaOff = 0
    private var lastWidget = Date.distantPast
    private var lastLive = Date.distantPast
    private var moving = false
    private var parkedSince: Date?
    private var socNotified = false
    private var st: Store { Store.shared }

    private override init() {
        super.init()
        ud.register(defaults: ["minInterval": 0.0, "cfgMain": 60, "cfgExtra": 300, "consoDefaut": 15.5, "prixMaison": 0.21, "prixBorne": 0.45, "socCible": 80, "ecoAuto": true, "ecoSeuil": 20])
        if let d = ud.data(forKey: "lastData") { data = try? JSONDecoder().decode(KonaData.self, from: d) }
        tripSync = ud.object(forKey: "tripSync") as? Date
        pendingCount = pendingLoad().count
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBest
        lm.distanceFilter = 10
        lm.allowsBackgroundLocationUpdates = true
        lm.pausesLocationUpdatesAutomatically = false
        lm.requestAlwaysAuthorization()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        cm = CBCentralManager(delegate: self, queue: nil,
                              options: [CBCentralManagerOptionRestoreIdentifierKey: "fr.flo.konarelay.central"])
    }

    // MARK: Central
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = p; p.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { status = "Bluetooth indisponible"; return }
        if let p = peripheral {
            if p.state == .connected { p.discoverServices([Self.svc]) }
            else { c.connect(p); status = "En attente de la Kona" }
        } else if let s = ud.string(forKey: "pid"), let id = UUID(uuidString: s),
                  let p = c.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = p; p.delegate = self
            c.connect(p)                       // connexion en attente sans timeout
            status = "En attente de la Kona"
        } else {
            c.scanForPeripherals(withServices: [Self.svc])
            status = "Recherche…"
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        c.stopScan()
        peripheral = p; p.delegate = self
        ud.set(p.identifier.uuidString, forKey: "pid")
        st.note("ESP32 trouvé")
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "Connexion…"
        p.discoverServices([Self.svc])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        if connected { st.note("Bluetooth déconnecté" + (error.map { " (\($0.localizedDescription))" } ?? "")) }
        connected = false; cmdChar = nil; ackChar = nil; otaChar = nil
        if busy != nil { busy = nil; show("Liaison Bluetooth perdue") }
        if otaProgress != nil { otaProgress = nil; show("Mise à jour interrompue") }
        status = "En attente de la Kona"
        st.disconnected(loc)
        Live.end()
        if let k = data { widgetSave(k); WidgetCenter.shared.reloadAllTimelines() }
        lm.stopUpdatingLocation()      // GPS seulement pendant la connexion à l'ESP
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if p.identifier == peripheral?.identifier { c.connect(p) }
    }

    // MARK: Peripheral
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.svc }) else { return }
        p.discoverCharacteristics([Self.dat, Self.cmd, Self.ack, Self.ota], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        cmdChar = s.characteristics?.first(where: { $0.uuid == Self.cmd })
        ackChar = s.characteristics?.first(where: { $0.uuid == Self.ack })
        otaChar = s.characteristics?.first(where: { $0.uuid == Self.ota })
        if let a = ackChar {                       // heure exacte pour l'horodatage des trajets
            p.writeValue(Data("time:\(Int64(Date().timeIntervalSince1970 * 1000))".utf8), for: a, type: .withoutResponse)
        }
        guard let ch = s.characteristics?.first(where: { $0.uuid == Self.dat }) else { return }
        buf.removeAll()
        p.setNotifyValue(true, for: ch)
        lm.desiredAccuracy = kCLLocationAccuracyBest; lm.distanceFilter = 10
        lm.startUpdatingLocation()
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == Self.dat else { return }
        let was = connected
        connected = ch.isNotifying
        status = connected ? "Connecté en Bluetooth" : "En attente de la Kona"
        if connected && !was { st.note("Connecté à l'ESP32"); notify("Kona connectée, relais actif") }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let chunk = ch.value else { return }
        buf.append(chunk)                                   // message JSON découpé en morceaux, terminé par \n
        if buf.count > 65536 { buf.removeAll(); return }
        while let nl = buf.firstIndex(of: 0x0A) {
            let d = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            guard !d.isEmpty else { continue }
            if let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                if let ack = o["ack"] as? String { handleAck(ack, ok: o["ok"] as? Bool ?? false, o); continue }
                if let kind = o["trip"] as? String { relayTrip(d, ack: kind == "done" ? "done" : "\(o["part"] ?? "")", p: p); continue }
                if var k = KonaData.decode(d) {
                    if let l = loc, -l.timestamp.timeIntervalSinceNow < 120, l.speed >= 0 { k.speed = Int(l.speed * 3.6) }
                    data = k
                    if let e = try? JSONEncoder().encode(k) { ud.set(e, forKey: "lastData") }
                    afterData(k, quick: false)
                } else if let g = o["g"] as? String, var k = data {      // envoi rapide : rapport, 12 V
                    k.gear = g == "-" || g == "?" ? nil : g
                    if let v = o["v12d"] as? Double { k.v12d = v }
                    data = k
                    afterData(k, quick: true)
                }
            }
            let minI = eco ? max(ud.double(forKey: "minInterval"), 120) : ud.double(forKey: "minInterval")
            if Date().timeIntervalSince(lastPost) >= minI { post(withLocation(d)) }
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        guard let e = error else { return }
        busy = nil
        if otaProgress != nil { otaProgress = nil }
        st.note("Écriture Bluetooth refusée : \(e.localizedDescription)")
        show("Échec Bluetooth : \(e.localizedDescription)")
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) { pumpOTA() }

    // MARK: Après chaque lecture : historique, GPS, widget, activité en direct
    private func afterData(_ k: KonaData, quick: Bool) {
        checkBattery()
        let mv = ["D", "R", "N"].contains(k.gear ?? "")
        if !quick { st.feed(k, loc: loc) }
        adaptGPS(mv)
        if mv && !moving && (depart == nil || Date().timeIntervalSince(depart!) > 1800) { surveillerPortes() }
        widgetSave(k)
        if quick || mv != moving || Date().timeIntervalSince(lastWidget) > 300 {
            lastWidget = Date(); WidgetCenter.shared.reloadAllTimelines()
        }
        if Live.current != nil {
            if quick || Date().timeIntervalSince(lastLive) > (eco ? 60 : 15) { lastLive = Date(); Live.update(liveState(k)) }
            if !mv && !k.charging && st.curTrip == nil && st.curCharge == nil { Live.end() }
        } else if (mv || k.charging) && UIApplication.shared.applicationState == .active {
            Live.start(k.charging ? "Recharge" : "Trajet", liveState(k))
        }
        if k.charging, let s = k.soc ?? k.socBms {          // objectif de charge atteint
            let cible = Double(ud.integer(forKey: "socCible"))
            if cible > 0, s >= cible, !socNotified {
                socNotified = true
                let c = st.curCharge
                notify("Objectif de \(Int(cible)) % atteint" + (c.map { " · +\(fr($0.kwh)) kWh en \(Int($0.end.timeIntervalSince($0.start) / 60)) min" } ?? ""),
                       title: "🔋 Kona à \(Int(s)) %", id: "soc")
                st.note("Objectif de charge atteint (\(Int(s)) %)")
            }
        } else if !k.charging { socNotified = false }
        moving = mv
    }

    func liveState(_ k: KonaData? = nil) -> KonaActivityAttributes.ContentState {
        let k = k ?? data
        let soc = k?.soc ?? k?.socBms ?? 0
        let eta = chargeETA(k)
        return .init(soc: soc, range: st.range(soc) ?? 0, kw: k?.kw ?? 0, speed: k?.speed ?? 0,
                     gear: k?.gear ?? "–", charging: k?.charging ?? false, updated: Date(),
                     minLeft: eta?.min ?? 0, cible: eta?.cible ?? 80,
                     tripKm: st.curTrip?.km ?? 0, tripConso: st.curTrip?.conso ?? 0,
                     portail: portesVisibles?.p ?? "", garage: portesVisibles?.g ?? "")
    }

    private var portesVisibles: (p: String, g: String)? {
        guard let d = depart, Date().timeIntervalSince(d) < 600 else { return nil }
        return portes
    }

    /// Départ : pendant 10 min, lit le portail et la porte de garage dans Home Assistant (toutes les 30 s).
    /// Affiché seulement si l'un des deux a bougé dans les 20 min avant le départ (donc départ de la maison).
    private func surveillerPortes() {
        depart = Date(); portes = nil
        let d0 = depart!
        Task { @MainActor in
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = { (s: String?) in s.flatMap { f.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } }
            var maison: Bool?
            while self.depart == d0, Date().timeIntervalSince(d0) < 600 {
                if let e: HAEtat = await self.haJSON("etat.json"), let p = e.portail, let g = e.garage {
                    if maison == nil {
                        let t = [date(e.portailT), date(e.garageT)].compactMap { $0 }.max()
                        maison = t.map { d0.timeIntervalSince($0) < 1200 } ?? false
                        if maison == true { self.st.note("Départ de la maison : portail \(p), garage \(g)") }
                    }
                    if maison == false { return }
                    let n = (p: p, g: g)
                    if self.portes?.p != n.p || self.portes?.g != n.g {
                        self.portes = n
                        if Live.current != nil { self.lastLive = Date(); Live.update(self.liveState()) }
                        if n.p == "open" || n.g == "open", Date().timeIntervalSince(d0) > 120 {
                            self.notify(n.g == "open" ? "La porte de garage est restée ouverte" : "Le portail est resté ouvert",
                                        title: "⚠️ Maison", id: "portes")
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
            if self.depart == d0, Live.current != nil { self.lastLive = Date(); Live.update(self.liveState()) }   // retire l'affichage
        }
    }

    /// Recharge : minutes estimées jusqu'à l'objectif (puissance mesurée, ralentissement au-delà de 80 % en charge rapide)
    func chargeETA(_ k: KonaData?) -> (min: Int, cible: Int)? {
        guard let k, k.charging, let soc = k.soc ?? k.socBms else { return nil }
        let cible = Double(max(ud.integer(forKey: "socCible"), 50))
        guard soc < cible else { return nil }
        var kw = abs(k.kw ?? 0)
        if kw < 0.5, let c = st.curCharge, c.end.timeIntervalSince(c.start) > 300 { kw = c.kwh / (c.end.timeIntervalSince(c.start) / 3600) }
        guard kw >= 0.5 else { return nil }
        let cap = 64.0, haut = 80.0
        let kwhBas = max(0, min(cible, haut) - min(soc, haut)) / 100 * cap
        let kwhHaut = max(0, cible - max(soc, haut)) / 100 * cap
        let h = kwhBas / kw + kwhHaut / (kw > 22 ? kw * 0.45 : kw)
        return (Int((h * 60 / 0.95).rounded()), Int(cible))
    }

    /// Mode économie quand la batterie de l'iPhone est faible (et qu'il ne charge pas)
    private func checkBattery() {
        let dev = UIDevice.current
        dev.isBatteryMonitoringEnabled = true
        let lvl = dev.batteryLevel
        let charge = dev.batteryState == .charging || dev.batteryState == .full
        let seuil = Float(ud.integer(forKey: "ecoSeuil")) / 100
        let faible = ud.bool(forKey: "ecoAuto") && !charge && lvl >= 0 && lvl < (eco ? seuil + 0.05 : seuil)
        guard faible != eco else { return }
        eco = faible
        st.note(eco ? "Mode économie : batterie iPhone à \(Int(lvl * 100)) %" : "Fin du mode économie")
        parkedSince = nil
        lm.desiredAccuracy = eco ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyBest
        lm.distanceFilter = eco ? 150 : 10
    }

    private func widgetSave(_ k: KonaData) {
        let soc = k.soc ?? k.socBms
        let eta = chargeETA(k)
        WidgetState(soc: soc, range: st.range(soc), kw: k.kw, charging: k.charging, gear: k.gear,
                    v12: k.v12d ?? k.v12, date: k.date, connected: connected, minLeft: eta?.min, cible: eta?.cible).save()
    }

    /// GPS précis en roulant, économe à l'arrêt depuis 2 min
    private func adaptGPS(_ mv: Bool) {
        if eco { return }                           // mode économie : GPS déjà réduit
        if mv {
            parkedSince = nil
            if lm.desiredAccuracy != kCLLocationAccuracyBest { lm.desiredAccuracy = kCLLocationAccuracyBest; lm.distanceFilter = 10 }
        } else {
            if parkedSince == nil { parkedSince = Date() }
            if let p = parkedSince, Date().timeIntervalSince(p) > 120, lm.desiredAccuracy != kCLLocationAccuracyHundredMeters {
                lm.desiredAccuracy = kCLLocationAccuracyHundredMeters; lm.distanceFilter = 100
                st.note("GPS en mode économe (à l'arrêt)")
            }
        }
    }

    // MARK: Trajets enregistrés (synchro BLE)
    /// Paquet de trajet : posté tel quel au webhook, puis accusé à l'ESP32 qui l'efface de sa mémoire.
    private func relayTrip(_ d: Data, ack: String, p: CBPeripheral) {
        guard let s = ud.string(forKey: "webhook"), URL(string: s)?.scheme != nil else { return }
        http(s, d) { ok in
            guard ok, let ch = self.ackChar, p.state == .connected else { return }
            p.writeValue(Data("tack:\(ack)".utf8), for: ch, type: .withoutResponse)
            if ack == "done" {
                self.tripSync = Date(); self.ud.set(self.tripSync, forKey: "tripSync")
                self.st.note("Trajet enregistré synchronisé avec Home Assistant")
            }
        }
    }

    // MARK: Commandes et réglages
    var bleReady: Bool { connected && cmdChar != nil && peripheral?.state == .connected }

    func send(_ c: KonaCommand) {
        guard busy == nil else { return }
        if bleReady, let p = peripheral, let ch = cmdChar {
            busy = c
            st.note("Commande \(c.label) (Bluetooth)")
            p.writeValue(Data("cmd:\(c.rawValue)".utf8), for: ch, type: .withResponse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                guard let self, self.busy == c else { return }
                self.busy = nil; self.show("\(c.label) : pas de réponse de l'ESP32")
            }
        } else {
            busy = c
            st.note("Commande \(c.label) (Home Assistant)")
            postCommand(["commande": c.rawValue]) { ok in
                self.busy = nil
                self.show(ok ? "\(c.label) envoyé via Home Assistant" : "\(c.label) : Home Assistant injoignable")
            }
        }
    }

    func applyCadence(main: Int, extra: Int) {
        ud.set(main, forKey: "cfgMain"); ud.set(extra, forKey: "cfgExtra")
        st.note("Cadences : \(main) s / \(extra) s")
        if bleReady, let p = peripheral, let ch = cmdChar {
            p.writeValue(Data("cfg:\(main),\(extra)".utf8), for: ch, type: .withResponse)
        }
        postCommand(["cfg": ["main": main, "extra": extra]]) { ok in
            if !self.bleReady { self.show(ok ? "Cadences enregistrées, appliquées au prochain contact avec l'ESP32" : "Home Assistant injoignable") }
        }
    }

    private func handleAck(_ ack: String, ok: Bool, _ o: [String: Any]) {
        switch ack {
        case "cfg":
            show(ok ? "Cadences appliquées : \(o["main"] ?? "?") s / \(o["extra"] ?? "?") s" : "Cadences refusées")
        case "net", "url":
            if !ok { netQueue.removeAll(); show("L'ESP32 a refusé un réglage réseau"); return }
            if netQueue.isEmpty { st.note("Réseaux de l'ESP32 mis à jour"); show("Réseaux enregistrés dans l'ESP32 ✓"); espReadNets() } else { nextNet() }
        case "netlist":
            espNets = (o["m"] as? String ?? "", o["p"] as? [String] ?? [], o["url"] as? Bool ?? false)
            nextNet()
        case "ota_begin":
            if ok { st.note("Mise à jour : envoi de \(otaData.count / 1024) Ko"); pumpOTA() }
            else { otaProgress = nil; show("L'ESP32 refuse la mise à jour") }
        case "ota_end":
            otaProgress = nil
            st.note(ok ? "Firmware installé, redémarrage de l'ESP32" : "Échec de la mise à jour (\(o["got"] ?? "?") octets reçus)")
            show(ok ? "Firmware installé, l'ESP32 redémarre ✓" : "Échec de la mise à jour, réessaie")
        default:
            let c = KonaCommand(rawValue: ack)
            if c == busy { busy = nil }
            st.note("\(c?.label ?? ack) : \(ok ? "OK" : "pas de réponse de la voiture")")
            show(ok ? "\(c?.label ?? ack) ✓" : "\(c?.label ?? ack) : la voiture n'a pas répondu")
        }
    }

    // MARK: Mise à jour du firmware par Bluetooth
    func startOTA(_ d: Data) {
        guard bleReady, let p = peripheral, let ch = cmdChar, otaChar != nil else { show("ESP32 non connecté en Bluetooth"); return }
        otaData = d; otaOff = 0; otaProgress = 0
        let md5 = Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
        st.note("Mise à jour du firmware demandée (\(d.count / 1024) Ko)")
        p.writeValue(Data("ota:begin:\(d.count):\(md5)".utf8), for: ch, type: .withResponse)
    }

    private func pumpOTA() {
        guard let p = peripheral, let ch = otaChar, otaProgress != nil, otaOff < otaData.count else { return }
        let n = min(p.maximumWriteValueLength(for: .withoutResponse), 244)
        while p.canSendWriteWithoutResponse && otaOff < otaData.count {
            let e = min(otaOff + n, otaData.count)
            p.writeValue(otaData.subdata(in: otaOff..<e), for: ch, type: .withoutResponse)
            otaOff = e
        }
        otaProgress = Double(otaOff) / Double(max(otaData.count, 1))
        if otaOff >= otaData.count, let c = cmdChar { p.writeValue(Data("ota:end".utf8), for: c, type: .withResponse) }
    }

    func show(_ t: String) {
        toast = t
        toastTask?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastTask = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: w)
        UINotificationFeedbackGenerator().notificationOccurred(t.contains("✓") || t.contains("envoyé") || t.contains("appliquées") ? .success : .warning)
    }

    // MARK: Position
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        loc = l.last; hasGPS = true
        if let x = loc { st.addPoint(x) }
    }

    private func withLocation(_ d: Data) -> Data {
        guard var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return d }
        o["via"] = "ble"
        let dev = UIDevice.current
        let app: [String: Any] = ["v": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                                  "bat": dev.batteryLevel >= 0 ? Int(dev.batteryLevel * 100) : -1, "eco": eco,
                                  "charge": dev.batteryState == .charging || dev.batteryState == .full]
        o["app"] = app
        guard let l = loc, -l.timestamp.timeIntervalSinceNow < 120 else {
            return (try? JSONSerialization.data(withJSONObject: o)) ?? d
        }
        o["latitude"] = l.coordinate.latitude
        o["longitude"] = l.coordinate.longitude
        o["gps_accuracy"] = Int(l.horizontalAccuracy)
        if l.speed >= 0 { o["gps_kmh"] = Int(l.speed * 3.6) }
        if l.course >= 0 { o["cap"] = Int(l.course) }
        return (try? JSONSerialization.data(withJSONObject: o)) ?? d
    }

    /// Relance la recherche / la connexion (appelé par le raccourci)
    func kick() { if cm.state == .poweredOn { centralManagerDidUpdateState(cm) } }

    func notify(_ text: String, title: String = "Kona Relay", id: String = "etat") {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    var lastLocation: CLLocation? { loc }

    // MARK: Données via Home Assistant (voiture au WiFi maison, Bluetooth coupé)
    func startHAPolling() {
        haTimer?.invalidate()
        haTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { await self?.fetchHA() } }
        Task { await fetchHA() }
    }
    func stopHAPolling() { haTimer?.invalidate(); haTimer = nil }

    @MainActor func fetchHA() async {
        guard !connected, let e: HAEtat = await haJSON("etat.json"), e.soc != nil || e.socBms != nil else { return }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = e.lecture.flatMap { f.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? Date()
        haSync = Date()
        if let cur = data, cur.src != "ha", cur.date >= d { return }          // lecture Bluetooth plus récente
        var k = KonaData()
        k.soc = e.soc; k.socBms = e.socBms; k.kw = e.kw; k.volts = e.volts; k.v12d = e.v12
        k.tMin = e.tMin; k.tMax = e.tMax; k.odo = e.odo; k.gear = e.gear; k.charging = e.charging ?? false
        k.date = d; k.src = "ha"
        let neuf = data?.date != d
        data = k
        if let x = try? JSONEncoder().encode(k) { ud.set(x, forKey: "lastData") }
        widgetSave(k)
        if neuf { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Rafraîchissement en arrière-plan (iOS choisit le moment) : met à jour l'app et les widgets
    static let haTask = "fr.flo.konarelay.ha"
    static func scheduleHA() {
        let r = BGAppRefreshTaskRequest(identifier: haTask)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// Lien konarelay://config?w=…&c=…&f=… (page « Configurer l'app iPhone » de Home Assistant)
    func applyConfig(_ url: URL) {
        guard url.scheme == "konarelay", let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        var n = 0
        for (k, key) in [("w", "webhook"), ("c", "cmdWebhook"), ("f", "haFolder")] {
            if let v = q.first(where: { $0.name == k })?.value, v.hasPrefix("https://") { ud.set(v, forKey: key); n += 1 }
        }
        st.note("Configuration importée (\(n) adresses)")
        show(n > 0 ? "Configuration importée ✓" : "Lien de configuration invalide")
    }

    /// Lit un fichier JSON du dossier de l'app sur Home Assistant
    func haJSON<T: Decodable>(_ file: String) async -> T? {
        guard let base = haFolder(), let u = URL(string: base + file + "?t=\(Int(Date().timeIntervalSince1970))") else { return nil }
        guard let res = try? await URLSession.shared.data(for: URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: res.0)
    }

    // MARK: Sauvegarde de l'historique dans Home Assistant (webhook données -> Node-RED -> config HA)
    private func item<T: Encodable>(_ kind: String, _ v: T, cout: Double) -> [String: Any]? {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        guard let d = try? e.encode(v), var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        o["cout"] = (cout * 100).rounded() / 100
        return ["kind": kind, "item": o]
    }

    func backup(trip t: Trip) { if let i = item("trip", t, cout: t.kwh * ud.double(forKey: "prixMaison")) { postBackup([i]) } }
    func backup(charge c: Charge) { if let i = item("charge", c, cout: c.kwh * ud.double(forKey: "prixBorne")) { postBackup([i]) } }

    func backupAll() {
        let pm = ud.double(forKey: "prixMaison"), pb = ud.double(forKey: "prixBorne")
        let items = st.trips.compactMap { item("trip", $0, cout: $0.kwh * pm) } + st.charges.compactMap { item("charge", $0, cout: $0.kwh * pb) }
        guard !items.isEmpty else { show("Rien à sauvegarder pour l'instant"); return }
        let lots = stride(from: 0, to: items.count, by: 10).map { Array(items[$0..<min($0 + 10, items.count)]) }
        var reste = lots.count, tout = true
        for l in lots {
            postBackup(l) { ok in
                tout = tout && ok; reste -= 1
                if reste == 0 { self.show(tout ? "Historique sauvegardé dans Home Assistant ✓" : "Sauvegarde incomplète, réessaie") }
            }
        }
    }

    private func postBackup(_ items: [[String: Any]], done: ((Bool) -> Void)? = nil) {
        guard let s = ud.string(forKey: "webhook"), URL(string: s)?.scheme != nil,
              let body = try? JSONSerialization.data(withJSONObject: ["backup": ["items": items]]) else { done?(false); return }
        http(s, body) { ok in
            done?(ok)
            if ok { self.flushPending(); return }
            var a = self.pendingLoad(); a += items                  // zone blanche : mis en attente, renvoyé au retour du réseau
            if a.count > 2000 { a.removeFirst(a.count - 2000) }
            self.pendingSave(a); self.pendingCount = a.count
            self.st.note("Sauvegarde mise en attente (\(a.count) en attente)")
        }
    }

    private var pendingURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("attente.json") }
    private func pendingLoad() -> [[String: Any]] {
        guard let d = try? Data(contentsOf: pendingURL) else { return [] }
        return ((try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]]) ?? []
    }
    private func pendingSave(_ a: [[String: Any]]) {
        if let d = try? JSONSerialization.data(withJSONObject: a) { try? d.write(to: pendingURL, options: .atomic) }
    }
    private func flushPending() {
        guard !flushing, let s = ud.string(forKey: "webhook"), URL(string: s)?.scheme != nil else { return }
        let a = pendingLoad()
        guard !a.isEmpty else { pendingCount = 0; return }
        let lot = Array(a.prefix(20))
        guard let body = try? JSONSerialization.data(withJSONObject: ["backup": ["items": lot]]) else { return }
        flushing = true
        http(s, body) { ok in
            self.flushing = false
            guard ok else { return }
            var r = self.pendingLoad(); r.removeFirst(min(lot.count, r.count))
            self.pendingSave(r); self.pendingCount = r.count
            if r.isEmpty { self.st.note("Envois en attente rattrapés") } else { self.flushPending() }
        }
    }

    // MARK: Réseaux de l'ESP32 (réglés depuis l'app, commandes envoyées une par une)
    func espReadNets() { netSend(["netlist"]) }
    func netSend(_ cmds: [String]) {
        guard bleReady else { show("ESP32 non connecté en Bluetooth"); return }
        netQueue = cmds; nextNet()
    }
    private func nextNet() {
        guard !netQueue.isEmpty, let p = peripheral, let ch = cmdChar else { return }
        p.writeValue(Data(netQueue.removeFirst().utf8), for: ch, type: .withResponse)
    }

    /// Dossier de l'app sur HA (fichiers publics à jeton : v12.json, sauvegarde.json, rapports.json)
    func haFolder() -> String? {
        guard var s = ud.string(forKey: "haFolder")?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("http") else { return nil }
        if !s.hasSuffix("/") { s += "/" }
        return s
    }

    func restore() {
        guard let base = haFolder(), let u = URL(string: base + "sauvegarde.json?t=\(Int(Date().timeIntervalSince1970))") else {
            show("Dossier Home Assistant non configuré (Réglages)"); return
        }
        URLSession.shared.dataTask(with: URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)) { d, _, _ in
            DispatchQueue.main.async {
                let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
                guard let d, let b = try? dec.decode(HABackup.self, from: d) else { self.show("Sauvegarde introuvable ou illisible"); return }
                let n = self.st.merge(trips: Array((b.trips ?? [:]).values), charges: Array((b.charges ?? [:]).values))
                self.st.note("Restauration depuis Home Assistant : \(n) éléments")
                self.show("\(n) éléments restaurés ✓")
            }
        }.resume()
    }

    func forget() {
        ud.removeObject(forKey: "pid")
        let old = peripheral; peripheral = nil; connected = false; cmdChar = nil; ackChar = nil; otaChar = nil
        if let o = old { cm.cancelPeripheralConnection(o) }
        cm.scanForPeripherals(withServices: [Self.svc])
        status = "Recherche…"
        st.note("ESP32 oublié, nouvelle recherche")
    }

    // MARK: Home Assistant
    private func post(_ body: Data) {
        guard let s = ud.string(forKey: "webhook"), URL(string: s)?.scheme != nil else {
            status = "Webhook données non configuré"; return
        }
        lastPost = Date()
        http(s, body) { ok in
            if ok { self.lastSent = Date(); if self.pendingCount > 0 { self.flushPending() } } else { self.lastPost = .distantPast }   // échec : on retente à la prochaine trame
            if ok != self.lastPostOK { self.lastPostOK = ok; self.st.note(ok ? "Envois vers Home Assistant rétablis" : "Home Assistant injoignable (réseau ?)") }
        }
    }

    private func postCommand(_ o: [String: Any], done: @escaping (Bool) -> Void) {
        guard let s = ud.string(forKey: "cmdWebhook"), URL(string: s)?.scheme != nil,
              let body = try? JSONSerialization.data(withJSONObject: o) else {
            done(false); show("Webhook commandes non configuré (Réglages)"); return
        }
        http(s, body, done: done)
    }

    private func http(_ url: String, _ body: Data, done: @escaping (Bool) -> Void) {
        guard let u = URL(string: url) else { done(false); return }
        var req = URLRequest(url: u, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            DispatchQueue.main.async {
                done((resp as? HTTPURLResponse)?.statusCode == 200)
                if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
            }
        }.resume()
    }
}
