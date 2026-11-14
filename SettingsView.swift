import SwiftUI
import UniformTypeIdentifiers

private func version(_ d: Data) -> String {
    let s = String(decoding: d, as: UTF8.self)
    guard let r = s.range(of: "ws-[0-9]+\\.[0-9]+", options: .regularExpression) else { return "version ?" }
    return String(s[r])
}

struct SettingsView: View {
    @AppStorage("theme") private var theme = "sombre"
    @AppStorage("accent") private var accent = "turquoise"
    @EnvironmentObject var r: BLERelay
    @Environment(\.dismiss) private var dismiss
    @AppStorage("webhook") private var webhook = ""
    @AppStorage("cmdWebhook") private var cmdWebhook = ""
    @AppStorage("cfgMain") private var cfgMain = 60
    @AppStorage("cfgExtra") private var cfgExtra = 300
    @AppStorage("prixMaison") private var prixMaison = 0.21
    @AppStorage("prixBorne") private var prixBorne = 0.45
    @AppStorage("consoDefaut") private var consoDefaut = 15.5
    @AppStorage("haFolder") private var haFolder = ""
    @AppStorage("socCible") private var socCible = 80
    @AppStorage("ecoAuto") private var ecoAuto = true
    @AppStorage("ecoSeuil") private var ecoSeuil = 20
    @State private var main = 60
    @State private var extra = 300
    @State private var fw: Data?
    @State private var fwName = ""
    @State private var pick = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $main, in: 10...600, step: main < 60 ? 5 : 15) {
                        LabeledContent("Principales", value: "toutes les \(duree(main))")
                    }
                    Stepper(value: $extra, in: 30...3600, step: extra < 300 ? 30 : 60) {
                        LabeledContent("Secondaires", value: "toutes les \(duree(extra))")
                    }
                    Button {
                        r.applyCadence(main: main, extra: extra)
                    } label: {
                        Label("Appliquer", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(main == cfgMain && extra == cfgExtra)
                } header: {
                    Text("Fréquence de rafraîchissement")
                } footer: {
                    Text("Principales : SOC, puissance, tension, 12 V, rapport, ouvrants. Secondaires : pneus, habitacle, cellules. Envoyé à l'ESP32 en Bluetooth s'il est connecté, et à Home Assistant pour la prochaine connexion WiFi.")
                }

                Section {
                    TextField("Webhook des données", text: $webhook, axis: .vertical)
                    TextField("Webhook des commandes", text: $cmdWebhook, axis: .vertical)
                    TextField("Dossier de l'app (…/local/kona_app_…/)", text: $haFolder, axis: .vertical)
                } header: {
                    Text("Home Assistant")
                } footer: {
                    Text("Webhooks : URL complètes https://…/api/webhook/…. Le dossier sert au 12 V au repos et à la restauration de l'historique.")
                }

                Section {
                    Stepper(value: $socCible, in: 50...100, step: 5) {
                        LabeledContent("Prévenir à", value: "\(socCible) %")
                    }
                } header: {
                    Text("Recharge sur borne")
                } footer: {
                    Text("Notification quand la Kona atteint ce niveau, puis à la fin de la recharge. L'iPhone doit rester à portée Bluetooth de la voiture (quelques dizaines de mètres).")
                }

                Section {
                    Picker("Apparence", selection: $theme) {
                        Text("Sombre").tag("sombre"); Text("Clair").tag("clair"); Text("Auto (clair 7 h–19 h)").tag("auto")
                    }
                    Picker("Couleur d'accent", selection: $accent) {
                        Text("Turquoise").tag("turquoise"); Text("Rouge Kona").tag("rouge")
                    }
                } header: {
                    Text("Thème")
                } footer: {
                    Text("Les widgets, l'activité en direct et CarPlay restent en sombre.")
                }

                Section {
                    NavigationLink { HomeEditor() } label: { Label("Cartes de l'écran d'accueil", systemImage: "rectangle.3.group") }
                    NavigationLink { EspNetworksView().environmentObject(r) } label: { Label("Réseaux de l'ESP32", systemImage: "wifi.router") }
                    if r.pendingCount > 0 {
                        LabeledContent("Sauvegardes en attente", value: "\(r.pendingCount)")
                    }
                } header: {
                    Text("Général")
                }

                Section {
                    Toggle("Économiser la batterie de l'iPhone", isOn: $ecoAuto)
                    if ecoAuto {
                        Stepper(value: $ecoSeuil, in: 10...50, step: 5) {
                            LabeledContent("Sous", value: "\(ecoSeuil) %")
                        }
                    }
                } header: {
                    Text("Mode économie")
                } footer: {
                    Text("Sous ce niveau, iPhone hors charge : GPS réduit (pas de tracé détaillé), envois à Home Assistant toutes les 2 min au plus, activité en direct rafraîchie chaque minute. L'ESP32 continue de tout enregistrer.")
                }

                Section {
                    Button { r.backupAll() } label: { Label("Sauvegarder tout l'historique", systemImage: "icloud.and.arrow.up") }
                    Button { r.restore() } label: { Label("Restaurer depuis Home Assistant", systemImage: "icloud.and.arrow.down") }
                } header: {
                    Text("Sauvegarde")
                } footer: {
                    Text("Chaque trajet et recharge est déjà envoyé automatiquement à Home Assistant (inclus dans ses sauvegardes). La restauration ajoute ce qui manque, sans doublon.")
                }
                .font(.footnote.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

                Section {
                    LabeledContent("kWh maison (trajets)") {
                        TextField("€", value: $prixMaison, format: .number.precision(.fractionLength(2...4))).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("kWh borne publique") {
                        TextField("€", value: $prixBorne, format: .number.precision(.fractionLength(2...4))).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Conso par défaut (kWh/100)") {
                        TextField("kWh", value: $consoDefaut, format: .number.precision(.fractionLength(1))).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Coûts et autonomie")
                } footer: {
                    Text("Le kWh maison sert au coût des trajets (mets ton prix heures creuses si tu charges la nuit). La conso par défaut sert à l'autonomie tant que l'app n'a pas 20 km de trajets.")
                }

                Section {
                    Button { pick = true } label: { Label("Choisir le fichier firmware.bin", systemImage: "doc.badge.arrow.up") }
                    if let fw {
                        LabeledContent(fwName, value: "\(fw.count / 1024) Ko · \(version(fw))")
                        Button { r.startOTA(fw) } label: { Label("Installer par Bluetooth", systemImage: "arrow.down.app.fill") }
                            .disabled(!r.bleReady || r.otaProgress != nil)
                    }
                    if let p = r.otaProgress {
                        ProgressView(value: p) { Text("Envoi : \(Int(p * 100)) %") }
                    }
                } header: {
                    Text("Firmware de l'ESP32")
                } footer: {
                    Text("Hors WiFi maison, ESP32 connecté en Bluetooth. Garde l'iPhone près de la voiture pendant l'envoi (1 à 2 min) ; l'ESP32 vérifie le fichier avant de l'installer.")
                }

                Section {
                    LabeledContent("État", value: r.status)
                    Button("Oublier l'ESP32 et rechercher", role: .destructive) { r.forget() }
                } header: {
                    Text("Bluetooth")
                } footer: {
                    Text("À la première commande en Bluetooth, l'iPhone demande le code d'appairage à 6 chiffres de l'ESP32.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .onAppear { main = cfgMain; extra = cfgExtra }
            .fileImporter(isPresented: $pick, allowedContentTypes: [.item]) { res in
                guard case .success(let url) = res else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                guard let d = try? Data(contentsOf: url), d.count > 200_000, d.first == 0xE9,
                      String(decoding: d, as: UTF8.self).contains("Waveshare ESP32-S3-RS485-CAN") else {
                    r.show("Ce fichier n'est pas le firmware de l'ESP32 Kona"); return
                }
                fw = d; fwName = url.lastPathComponent
            }
        }
        .preferredColorScheme(Theme.scheme)
        .tint(Theme.accent)
    }
}

/// Ordre et affichage des cartes de l'écran d'accueil
struct HomeEditor: View {
    @AppStorage("homeOrder") private var homeOrder = ""
    @AppStorage("homeHidden") private var homeHidden = ""
    @State private var liste: [HomeCard] = []

    var body: some View {
        List {
            Section {
                ForEach(liste) { c in
                    Toggle(isOn: Binding(get: { !cachees.contains(c.rawValue) }, set: { on in
                        var h = cachees; if on { h.remove(c.rawValue) } else { h.insert(c.rawValue) }
                        homeHidden = h.sorted().joined(separator: ",")
                    })) { Label(c.label, systemImage: c.icon) }
                }
                .onMove { liste.move(fromOffsets: $0, toOffset: $1); homeOrder = liste.map(\.rawValue).joined(separator: ",") }
            } footer: {
                Text("Fais glisser pour changer l'ordre, décoche pour masquer. La carte « Recharge en cours » n'apparaît que pendant une recharge.")
            }
            Section {
                Button("Rétablir l'ordre d'origine") { homeOrder = ""; homeHidden = ""; liste = HomeCard.allCases }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Écran d'accueil")
        .onAppear { liste = HomeCard.ordre(homeOrder) }
    }

    private var cachees: Set<String> { Set(homeHidden.split(separator: ",").map(String.init)) }
}

/// Réseaux WiFi et webhook de l'ESP32, envoyés en Bluetooth (voiture hors du WiFi maison)
struct EspNetworksView: View {
    @EnvironmentObject var r: BLERelay
    @AppStorage("webhook") private var webhook = ""
    @State private var ssid = Array(repeating: "", count: 5)       // 0 = maison, 1 = iPhone, 2..4 = autres
    @State private var pass = Array(repeating: "", count: 5)
    @State private var url = ""
    private let noms = ["WiFi maison", "Partage de l'iPhone", "Autre réseau 1", "Autre réseau 2", "Autre réseau 3"]

    var body: some View {
        Form {
            Section {
                LabeledContent("Bluetooth", value: r.bleReady ? "connecté" : "non connecté")
                if let n = r.espNets {
                    LabeledContent("Maison", value: n.m.isEmpty ? "—" : n.m)
                    ForEach(0..<min(n.p.count, 4), id: \.self) { i in
                        LabeledContent(i == 0 ? "iPhone" : "Autre \(i)", value: n.p[i].isEmpty ? "—" : n.p[i])
                    }
                    LabeledContent("Webhook", value: n.url ? "réglé" : "absent")
                }
                Button("Lire les réseaux de l'ESP32") { r.espReadNets() }.disabled(!r.bleReady)
            } header: {
                Text("Actuellement dans l'ESP32")
            }
            ForEach(0..<5, id: \.self) { i in
                Section(noms[i]) {
                    TextField("Nom du réseau (SSID)", text: $ssid[i]).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Mot de passe", text: $pass[i])
                }
            }
            Section {
                TextField("https://…/api/webhook/…", text: $url, axis: .vertical).font(.footnote.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            } header: {
                Text("Webhook utilisé par l'ESP32 hors maison")
            }
            Section {
                Button { envoyer() } label: { Label("Envoyer à l'ESP32", systemImage: "paperplane.fill") }
                    .disabled(!r.bleReady || (ssid.allSatisfy { $0.isEmpty } && url.isEmpty))
            } footer: {
                Text("Seuls les champs remplis sont envoyés ; les autres réseaux restent inchangés. Les réseaux « Internet » (iPhone, autres) servent hors de la maison, comme le partage de connexion. Il faut que l'ESP32 soit connecté en Bluetooth, donc voiture hors du WiFi maison.")
            }
        }
        .navigationTitle("Réseaux de l'ESP32")
        .onAppear { if url.isEmpty { url = webhook }; if r.bleReady { r.espReadNets() } }
    }

    private func envoyer() {
        let slots = ["m", "0", "1", "2", "3"]
        var cmds: [String] = []
        for i in 0..<5 where !ssid[i].trimmingCharacters(in: .whitespaces).isEmpty {
            cmds.append("net:\(slots[i]):\(ssid[i].trimmingCharacters(in: .whitespaces))\t\(pass[i])")
        }
        if url.hasPrefix("https://") { cmds.append("url:" + url.trimmingCharacters(in: .whitespacesAndNewlines)) }
        r.netSend(cmds)
        pass = Array(repeating: "", count: 5)
    }
}
