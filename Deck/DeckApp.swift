import SwiftUI

@main
struct DeckApp: App {
    @StateObject private var agent = AgentLoop()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(agent)
                .onOpenURL { url in agent.handleURL(url) }
                .onAppear {
                    KeepAlive.shared.start()
                    LiveDeck.shared.ensureRunning()
                    ScreenMonitor.shared.checkOnForeground()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        ScreenMonitor.shared.checkOnForeground()
                        LiveDeck.shared.ensureRunning()
                    }
                }
        }
    }
}
