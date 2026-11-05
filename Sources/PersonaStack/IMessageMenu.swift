import SwiftUI

struct IMessageMenu: View {
    @ObservedObject private var manager = IMessageSetupManager.shared
    var body: some View {
        Menu("Messages") {
            Text(manager.menuState.statusText)
            Button(manager.menuState == .setupRequired ? "Set Up Messages…" : "Review Connection…") { manager.openSetup() }
            if manager.menuState != .setupRequired {
                if manager.menuState.offersResume {
                    Button("Resume Messages") { Task { await manager.resume() } }
                } else {
                    Button("Pause Messages") { Task { await manager.pause() } }
                }
            }
        }
    }
}
