import Foundation

/// Valeurs principales décodées des réponses UDS brutes envoyées par l'ESP32 (mêmes octets que le firmware).
struct KonaData: Codable, Equatable {
    var soc: Double?          // SOC affiché (7E4 220105, octet 34 / 2)
    var socBms: Double?       // SOC BMS (7E4 220101, octet 7 / 2)
    var kw: Double?
    var volts: Double?
    var amps: Double?
    var tMin: Int?
    var tMax: Int?
    var v12: Double?
    var v12d: Double?        // 12 V mesuré par l'ESP32
    var cec: Double?         // énergie cumulée chargée (kWh)
    var ced: Double?         // énergie cumulée déchargée (kWh)
    var odo: Int?
    var charging = false
    var gear: String?
    var speed: Int?
    var date = Date()

    static func decode(_ d: Data) -> KonaData? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let rx = o["rx"] as? [[String: Any]] else { return nil }
        func bytes(_ cmd: String) -> [UInt8]? {
            guard let r = rx.first(where: { ($0["cmd"] as? String) == cmd })?["resp"] as? String else { return nil }
            let b = r.split(separator: " ").compactMap { UInt8($0, radix: 16) }
            return b.first == 0x62 ? b : nil
        }
        guard let b = bytes("7E4 220101"), b.count >= 49 else { return nil }
        var k = KonaData()
        k.socBms = Double(b[7]) / 2
        let cur = Double(Int16(bitPattern: UInt16(b[13]) << 8 | UInt16(b[14]))) / 10
        let v = Double(UInt16(b[15]) << 8 | UInt16(b[16])) / 10
        k.amps = cur; k.volts = v; k.kw = cur * v / 1000
        k.tMax = Int(Int8(bitPattern: b[17])); k.tMin = Int(Int8(bitPattern: b[18]))
        k.v12 = Double(b[32]) / 10
        k.charging = b[12] & 0x80 != 0
        func u32(_ i: Int) -> Double {
            let hi = UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16
            let lo = UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
            return Double(hi | lo) / 10
        }
        k.cec = u32(41); k.ced = u32(45)
        k.v12d = o["v12d"] as? Double
        if let c = bytes("7E4 220105"), c.count >= 35 { k.soc = Double(c[34]) / 2 }
        if let p = bytes("7C6 22B002"), p.count >= 12 { k.odo = Int(p[9]) << 16 | Int(p[10]) << 8 | Int(p[11]) }
        k.gear = o["g"] as? String
        return k
    }
}

enum KonaCommand: String, CaseIterable, Identifiable {
    case deverrouiller, verrouiller, feux, klaxon
    var id: String { rawValue }
    var label: String { ["deverrouiller": "Ouvrir", "verrouiller": "Fermer", "feux": "Phares", "klaxon": "Klaxon"][rawValue]! }
    var icon: String { ["deverrouiller": "lock.open.fill", "verrouiller": "lock.fill", "feux": "headlight.high.beam.fill", "klaxon": "megaphone.fill"][rawValue]! }
    var needsConfirm: Bool { self == .deverrouiller || self == .verrouiller }
}
