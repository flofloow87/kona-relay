import CoreBluetooth
import CoreLocation
import CryptoKit
import Foundation
import BackgroundTasks
import UIKit
import UserNotifications
import WidgetKit

// Home Assistant : état, sauvegarde/restauration, file d'attente, réseaux de l'ESP32, envois HTTP
extension BLERelay {
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
    func item<T: Encodable>(_ kind: String, _ v: T, cout: Double) -> [String: Any]? {
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

    func postBackup(_ items: [[String: Any]], done: ((Bool) -> Void)? = nil) {
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

    var pendingURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("attente.json") }
    func pendingLoad() -> [[String: Any]] {
        guard let d = try? Data(contentsOf: pendingURL) else { return [] }
        return ((try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]]) ?? []
    }
    func pendingSave(_ a: [[String: Any]]) {
        if let d = try? JSONSerialization.data(withJSONObject: a) { try? d.write(to: pendingURL, options: .atomic) }
    }
    func flushPending() {
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
    func nextNet() {
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
    func post(_ body: Data) {
        guard let s = ud.string(forKey: "webhook"), URL(string: s)?.scheme != nil else {
            status = "Webhook données non configuré"; return
        }
        lastPost = Date()
        http(s, body) { ok in
            if ok { self.lastSent = Date(); if self.pendingCount > 0 { self.flushPending() } } else { self.lastPost = .distantPast }   // échec : on retente à la prochaine trame
            if ok != self.lastPostOK { self.lastPostOK = ok; self.st.note(ok ? "Envois vers Home Assistant rétablis" : "Home Assistant injoignable (réseau ?)") }
        }
    }

    func postCommand(_ o: [String: Any], done: @escaping (Bool) -> Void) {
        guard let s = ud.string(forKey: "cmdWebhook"), URL(string: s)?.scheme != nil,
              let body = try? JSONSerialization.data(withJSONObject: o) else {
            done(false); show("Webhook commandes non configuré (Réglages)"); return
        }
        http(s, body, done: done)
    }

    func http(_ url: String, _ body: Data, done: @escaping (Bool) -> Void) {
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
