import CoreBluetooth
import CoreLocation
import Foundation
import UIKit
import UserNotifications

final class BLERelay: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, CLLocationManagerDelegate {
    static let shared = BLERelay()
    static let svc = CBUUID(string: "6E4B0001-9A3C-4F2B-8C11-4B4F4E415343")
    static let dat = CBUUID(string: "6E4B0002-9A3C-4F2B-8C11-4B4F4E415343")

    @Published var status = "Démarrage"
    @Published var last = "—"
    @Published var lastSent: Date?

    private var cm: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var lastPost = Date.distantPast
    private var buf = Data()
    private let ud = UserDefaults.standard
    private let lm = CLLocationManager()
    private var loc: CLLocation?

    private override init() {
        super.init()
        ud.register(defaults: ["minInterval": 0.0])
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
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
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "Connecté"
        p.discoverServices([Self.svc])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        status = "En attente de la Kona"
        lm.stopUpdatingLocation()      // GPS seulement pendant la connexion à l'ESP
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if p.identifier == peripheral?.identifier { c.connect(p) }
    }

    // MARK: Peripheral
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.svc }) else { return }
        p.discoverCharacteristics([Self.dat], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let ch = s.characteristics?.first(where: { $0.uuid == Self.dat }) else { return }
        buf.removeAll()
        p.setNotifyValue(true, for: ch)
        lm.startUpdatingLocation()
        if !ch.isNotifying { notify("Kona connectée, relais actif") }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let chunk = ch.value else { return }
        buf.append(chunk)                                   // message JSON découpé en morceaux, terminé par \n
        if buf.count > 65536 { buf.removeAll(); return }
        while let nl = buf.firstIndex(of: 0x0A) {
            let d = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            guard !d.isEmpty else { continue }
            last = String(data: d.prefix(200), encoding: .utf8) ?? "—"
            if Date().timeIntervalSince(lastPost) >= ud.double(forKey: "minInterval") { post(withLocation(d)) }
        }
    }

    // MARK: Position
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) { loc = l.last }

    private func withLocation(_ d: Data) -> Data {
        guard var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return d }
        o["via"] = "ble"
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

    private func notify(_ text: String) {
        let c = UNMutableNotificationContent()
        c.title = "Kona Relay"; c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "etat", content: c, trigger: nil))
    }

    func forget() {
        ud.removeObject(forKey: "pid")
        let old = peripheral; peripheral = nil
        if let o = old { cm.cancelPeripheralConnection(o) }
        cm.scanForPeripherals(withServices: [Self.svc])
        status = "Recherche…"
    }

    // MARK: Home Assistant
    private func post(_ body: Data) {
        guard let url = URL(string: ud.string(forKey: "webhook") ?? ""), url.scheme != nil else {
            status = "Webhook non configuré"; return
        }
        lastPost = Date()
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            DispatchQueue.main.async {
                if (resp as? HTTPURLResponse)?.statusCode == 200 { self.lastSent = Date() }
                else { self.lastPost = .distantPast }   // échec (pas de réseau) : on retente à la prochaine trame
                if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
            }
        }.resume()
    }
}
