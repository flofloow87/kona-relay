import SwiftUI

struct ContentView: View {
    @EnvironmentObject var r: BLERelay
    @AppStorage("webhook") var webhook = ""
    @AppStorage("minInterval") var minInterval = 0.0

    var body: some View {
        NavigationStack {
            Form {
                Section("État") {
                    Text(r.status)
                    Text(r.last).font(.caption.monospaced())
                    if let d = r.lastSent {
                        Text("Dernier envoi : \(d.formatted(date: .omitted, time: .standard))")
                    }
                }
                Section("Home Assistant") {
                    TextField("https://xxxx.ui.nabu.casa/api/webhook/…", text: $webhook)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Stepper("Envoi mini toutes les \(Int(minInterval)) s",
                            value: $minInterval, in: 0...600, step: 15)
                }
                Section {
                    Button("Oublier l'ESP et rechercher", role: .destructive) { r.forget() }
                }
            }
            .navigationTitle("Kona Relay")
        }
    }
}
