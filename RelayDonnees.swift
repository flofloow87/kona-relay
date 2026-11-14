import CoreBluetooth
import CoreLocation
import CryptoKit
import Foundation
import BackgroundTasks
import UIKit
import UserNotifications
import WidgetKit

// Après chaque lecture : historique, GPS, widget, activité en direct, portail/garage, mode éco
extension BLERelay {
    // MARK: Après chaque lecture : historique, GPS, widget, activité en direct
    func afterData(_ k: KonaData, quick: Bool) {
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

    var portesVisibles: (p: String, g: String)? {
        guard let d = depart, Date().timeIntervalSince(d) < 600 else { return nil }
        return portes
    }

    /// Départ : pendant 10 min, lit le portail et la porte de garage dans Home Assistant (toutes les 30 s).
    /// Affiché seulement si l'un des deux a bougé dans les 20 min avant le départ (donc départ de la maison).
    func surveillerPortes() {
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
    func checkBattery() {
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

    func widgetSave(_ k: KonaData) {
        let soc = k.soc ?? k.socBms
        let eta = chargeETA(k)
        WidgetState(soc: soc, range: st.range(soc), kw: k.kw, charging: k.charging, gear: k.gear,
                    v12: k.v12d ?? k.v12, date: k.date, connected: connected, minLeft: eta?.min, cible: eta?.cible).save()
    }

    /// GPS précis en roulant, économe à l'arrêt depuis 2 min
    func adaptGPS(_ mv: Bool) {
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

}
