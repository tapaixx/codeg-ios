import SwiftUI

@main
struct CodegiOSApp: App {
    init() {
        BackgroundAgentCoordinator.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
