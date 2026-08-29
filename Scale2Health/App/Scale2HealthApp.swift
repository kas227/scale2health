import SwiftUI

@main
struct Scale2HealthApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.updateScenePhase(phase)
                }
        }
    }
}
