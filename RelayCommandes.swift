import CoreBluetooth
import CoreLocation
import CryptoKit
import Foundation
import BackgroundTasks
import UIKit
import UserNotifications
import WidgetKit

// Trajets synchronisés, commandes, réglages, mise à jour du firmware, position
extension BLERelay {
    // MARK: Trajets enregistrés (synchro BLE)
    /// Paquet de trajet : posté tel quel au webhook, puis accusé à l'ESP32 qui l'efface de sa mémoire.
    func relayTrip(_ d: Data, ack: String, p: CBPeripheral) {
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

    func handleAck(_ ack: String, ok: Bool, _ o: [String: Any]) {
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

    func pumpOTA() {
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

    func withLocation(_ d: Data) -> Data {
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

    func notify(_ text: String, title: String = "Kona", id: String = "etat") {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    var lastLocation: CLLocation? { loc }

}
