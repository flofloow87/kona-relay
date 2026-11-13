import BackgroundTasks
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    // Instancié dès le lancement, y compris quand iOS relance l'app en arrière-plan pour le BLE
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = BLERelay.shared
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BLERelay.haTask, using: nil) { task in
            BLERelay.scheduleHA()
            let t = Task { await BLERelay.shared.fetchHA(); task.setTaskCompleted(success: true) }
            task.expirationHandler = { t.cancel() }
        }
        return true
    }
}

@main
struct KonaRelayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(BLERelay.shared).environmentObject(Store.shared)
                .onOpenURL { BLERelay.shared.applyConfig($0) }
        }
    }
}
