import CoreBluetooth
import CoreLocation
import CryptoKit
import Foundation
import BackgroundTasks
import UIKit
import UserNotifications
import WidgetKit

struct HABackup: Decodable { var trips: [String: Trip]?; var charges: [String: Charge]? }
/// État de la voiture publié par Home Assistant (etat.json) quand l'ESP32 est au WiFi maison
struct HAEtat: Decodable {
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
    var depart: Date?                     // début du trajet (portail/garage affichés 10 min)
    var portes: (p: String, g: String)?
    @Published var haSync: Date?                  // dernière lecture réussie dans Home Assistant
    var haTimer: Timer?
    @Published var espNets: (m: String, p: [String], url: Bool)?
    var netQueue: [String] = []
    var flushing = false

    var cm: CBCentralManager!
    var peripheral: CBPeripheral?
    var cmdChar: CBCharacteristic?
    var ackChar: CBCharacteristic?
    var otaChar: CBCharacteristic?
    var lastPost = Date.distantPast
    var lastPostOK = true
    var buf = Data()
    let ud = UserDefaults.standard
    let lm = CLLocationManager()
    var loc: CLLocation?
    var toastTask: DispatchWorkItem?
    var otaData = Data()
    var otaOff = 0
    var lastWidget = Date.distantPast
    var lastLive = Date.distantPast
    var moving = false
    var parkedSince: Date?
    var socNotified = false
    var st: Store { Store.shared }

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

}
