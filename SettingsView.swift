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
    @AppStorage("carColor") private var carColor = "gris"
    @AppStorage("carPhoto") private var carPhoto = true
    @EnvironmentObject var r: BLERelay
    @Environment(\.dismiss) private var dismiss
    @AppStorage("webhook") private var webhook = ""
    @AppStorage("cmdWebhook") private var cmdWebhook = ""
    @AppStorage("cfgMain") private var cfgMain = 60
    @AppStorage("cfgExtra") private var cfgExtra = 300
    @AppStorage("cfgDrive") private var cfgDrive = 3
    @AppStorage("prixMaison") private var prixMaison = 0.21
    @AppStorage("prixBorne") private var prixBorne = 0.45
    @AppStorage("consoDefaut") private var consoDefaut = 15.5
    @AppStorage("haFolder") private var haFolder = ""
    @AppStorage("socCible") private var socCible = 80
    @AppStorage("ecoAuto") private var ecoAuto = true
    @AppStorage("ecoSeuil") private var ecoSeuil = 20
    @State private var main = 60
    @State private var extra = 300
    @State private var drive = 3
    @State private var fw: Data?
    @State private var fwName = ""
    @State private var pick = false

    var body: some View {
        NavigationStack {
            Form { Group {
                Section {
                    Stepper(value: $main, in: 10...600, step: main < 60 ? 5 : 15) {
                        LabeledContent("Principales", value: "toutes les \(duree(main))")
                    }
                    Stepper(value: $extra, in: 30...3600, step: extra < 300 ? 30 : 60) {
                        LabeledContent("Secondaires", value: "toutes les \(duree(extra))")
                    }
                    // 0 = désactivée, sinon 2 à 30 s (l'ESP32 n'accepte pas 1 s)
                    Stepper {
                        LabeledContent("En roulant", value: drive == 0 ? "désactivée" : "toutes les \(duree(drive))")
                    } onIncrement: {
                        drive = drive == 0 ? 2 : min(drive + 1, 30)
                    } onDecrement: {
                        drive = drive <= 2 ? 0 : drive - 1
                    }
                    Button {
                        r.applyCadence(main: main, extra: extra, drive: drive)
                    } label: {
                        Label("Appliquer", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(main == cfgMain && extra == cfgExtra && drive == cfgDrive)
                } header: {
                    Text("Fréquence de rafraîchissement")
                } footer: {
                    Text("Principales : SOC, puissance, tension, 12 V, rapport, ouvrants. Secondaires : pneus, habitacle, cellules. En roulant : les principales en direct dans l'app, voiture en D, R ou N et ESP32 connecté en Bluetooth (firmware ws-2.6 ou plus) ; Home Assistant et l'historique des trajets restent à la cadence principale. Envoyé à l'ESP32 en Bluetooth s'il est connecté, sinon à sa prochaine connexion.")
                }

                Section {
                    // adresses : police à chasse fixe, sans majuscule ni correction automatiques
                    Group {
                        TextField("Webhook des données", text: $webhook, axis: .vertical)
                        TextField("Webhook des commandes", text: $cmdWebhook, axis: .vertical)
                        TextField("Dossier de l'app (…/local/kona_app_…/)", text: $haFolder, axis: .vertical)
                    }
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
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
                    if KonaPhoto.image != nil {
                        Toggle("Photo réaliste de la Kona", isOn: $carPhoto.animation())
                    }
                    // la teinte ne sert qu'au dessin : réglage visible seulement sans la photo
                    if !carPhoto || KonaPhoto.image == nil {
                        KonaSide(paint: CarPaint(rawValue: carColor) ?? .gris)
                            .frame(maxWidth: 260)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .animation(.easeInOut(duration: 0.4), value: carColor)
                        Picker("Teinte du dessin", selection: $carColor) {
                            ForEach(CarPaint.allCases) { p in Text(p.label).tag(p.rawValue) }
                        }
                    }
                } header: {
                    Text("Thème")
                } footer: {
                    Text(carPhoto ? "La photo est utilisée dans l'onglet Voiture, les widgets et l'activité en direct. Désactive-la pour revenir au dessin animé et choisir sa teinte. Les widgets, l'activité en direct et CarPlay restent en sombre."
                         : "La teinte sert au dessin de l'onglet Voiture, des widgets et de l'activité en direct. Les widgets, l'activité en direct et CarPlay restent en sombre.")
                }

                Section {
                    NavigationLink { EspNetworksView().environmentObject(r).konaPage() } label: { Label("Réseaux de l'ESP32", systemImage: "wifi.router") }
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
            }.konaRows() }
            .konaPage()
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .onAppear { main = cfgMain; extra = cfgExtra; drive = cfgDrive }
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

/// Réseaux WiFi et webhook de l'ESP32, envoyés en Bluetooth (voiture hors du WiFi maison)
struct EspNetworksView: View {
    @EnvironmentObject var r: BLERelay
    @AppStorage("webhook") private var webhook = ""
    @State private var ssid = Array(repeating: "", count: 5)       // 0 = maison, 1 = iPhone, 2..4 = autres
    @State private var pass = Array(repeating: "", count: 5)
    @State private var url = ""
    @State private var effacer = Array(repeating: false, count: 5)  // seuls les « autres réseaux » (2..4) peuvent être effacés
    private let noms = ["WiFi maison", "Partage de l'iPhone", "Autre réseau 1", "Autre réseau 2", "Autre réseau 3"]

    var body: some View {
        Form { Group {
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
                        .disabled(effacer[i])
                    SecureField("Mot de passe", text: $pass[i]).disabled(effacer[i])
                    if i >= 2 { Toggle("Effacer ce réseau de l'ESP32", isOn: $effacer[i]) }
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
                    .disabled(!r.bleReady || (ssid.allSatisfy { $0.isEmpty } && url.isEmpty && !effacer.contains(true)))
            } footer: {
                Text("Seuls les champs remplis (ou les réseaux à effacer) sont envoyés ; les autres réseaux restent inchangés. Les réseaux « Internet » (iPhone, autres) servent hors de la maison, comme le partage de connexion. Il faut que l'ESP32 soit connecté en Bluetooth, donc voiture hors du WiFi maison.")
            }
        }.konaRows() }
        .navigationTitle("Réseaux de l'ESP32")
        .onAppear { if url.isEmpty { url = webhook }; if r.bleReady { r.espReadNets() } }
    }

    private func envoyer() {
        let slots = ["m", "0", "1", "2", "3"]
        var cmds: [String] = []
        for i in 0..<5 {
            if i >= 2 && effacer[i] { cmds.append("net:\(slots[i]):"); continue }   // SSID vide = réseau effacé par l'ESP32
            let s = ssid[i].trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { cmds.append("net:\(slots[i]):\(s)\t\(pass[i])") }
        }
        if url.hasPrefix("https://") { cmds.append("url:" + url.trimmingCharacters(in: .whitespacesAndNewlines)) }
        r.netSend(cmds)
        pass = Array(repeating: "", count: 5)
        effacer = Array(repeating: false, count: 5)
    }
}
