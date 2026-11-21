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
            // pas de fin pendant un départ : l'activité (CarPlay) affiche le portail et le garage
            if !mv && !k.charging && st.curTrip == nil && st.curCharge == nil && !departEnCours { Live.end() }
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

    /// Durée d'affichage du portail et du garage après le début du départ
    static let fenetrePortes: TimeInterval = 720

    var departEnCours: Bool { depart.map { Date().timeIntervalSince($0) < Self.fenetrePortes } ?? false }

    var portesVisibles: (p: String, g: String)? {
        guard departEnCours else { return nil }
        return portes
    }

    /// Départ (CarPlay qui se connecte, ou voiture qui roule) : pendant 12 min, lit le portail et la porte de garage
    /// dans Home Assistant toutes les 20 s. Affiché dès que l'un des deux a bougé entre 20 min avant le départ
    /// et 5 min après (on monte souvent en voiture avant d'ouvrir le garage) : c'est un départ de la maison.
    func surveillerPortes() {
        depart = Date(); portes = nil
        let d0 = depart!
        Task { @MainActor in
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = { (s: String?) in s.flatMap { f.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } }
            var maison = false, alerte = false
            while self.depart == d0, Date().timeIntervalSince(d0) < Self.fenetrePortes {
                if let e: HAEtat = await self.haJSON("etat.json"), let p = e.portail, let g = e.garage {
                    let bouge = [date(e.portailT), date(e.garageT)].compactMap { $0 }.max()    // dernier mouvement
                    if !maison {
                        if let t = bouge, t > d0.addingTimeInterval(-1200), t < d0.addingTimeInterval(300) {
                            maison = true
                            self.st.note("Départ de la maison : portail \(p), garage \(g)")
                        } else if Date().timeIntervalSince(d0) > 300 {
                            return                      // rien n'a bougé : pas un départ de la maison
                        }
                    }
                    if maison {
                        let n = (p: p, g: g)
                        if self.portes?.p != n.p || self.portes?.g != n.g {
                            self.portes = n
                            if Live.current != nil { self.lastLive = Date(); Live.update(self.liveState()) }
                        }
                        // encore ouvert 3 min après son dernier mouvement : prévenir une fois
                        if !alerte, n.p == "open" || n.g == "open", let t = bouge, Date().timeIntervalSince(t) > 180 {
                            alerte = true
                            self.notify(n.g == "open" ? "La porte de garage est restée ouverte" : "Le portail est resté ouvert",
                                        title: "⚠️ Maison", id: "portes")
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
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
