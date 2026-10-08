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
                    } else if newPhase == .background {
                        // Drop the 2.5GB resident model the moment we're backgrounded:
                        // jetsam kills resident giants first. Lazy-reloads on next turn.
                        Task { await LlamaEngine.shared.unload() }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task { await LlamaEngine.shared.unload() }
                }
        }
    }
}
