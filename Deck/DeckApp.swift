import SwiftUI

@main
struct DeckApp: App {
    @StateObject private var agent = AgentLoop()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(agent)
                .onOpenURL { url in agent.handleURL(url) }
        }
    }
}
