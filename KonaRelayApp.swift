import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    // Instancié dès le lancement, y compris quand iOS relance l'app en arrière-plan pour le BLE
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = BLERelay.shared
        return true
    }
}

@main
struct KonaRelayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(BLERelay.shared) }
    }
}
