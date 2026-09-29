import AppIntents
import UIKit

/// "Hey Siri, ask Deck <question>" — works from any app.
/// Opens Deck via its URL scheme and auto-runs the question.
struct AskDeckIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Deck"
    static let description = IntentDescription("Ask your on-device Deck a question.")
    static let openAppWhenRun = false

    @Parameter(title: "Question")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let q = question.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "deck://ask?question=\(q)") else {
            return .result()
        }
        await UIApplication.shared.open(url)
        return .result()
    }
}

/// "Hey Siri, tell Deck to <task>" — runs an agentic task.
struct DoDeckIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell Deck to do something"
    static let description = IntentDescription("Give your on-device Deck a task to carry out.")
    static let openAppWhenRun = false

    @Parameter(title: "Task")
    var task: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let q = task.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "deck://do?task=\(q)") else {
            return .result()
        }
        await UIApplication.shared.open(url)
        return .result()
    }
}

/// Makes both intents discoverable as App Shortcuts.
struct DeckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskDeckIntent(),
            phrases: ["Ask \(.applicationName)", "Ask Deck a question"],
            shortTitle: "Ask Deck",
            systemImageName: "message.fill"
        )
        AppShortcut(
            intent: DoDeckIntent(),
            phrases: ["Tell \(.applicationName) to \(.applicationName)", "Get Deck to do something"],
            shortTitle: "Deck Do",
            systemImageName: "bolt.fill"
        )
    }
}
