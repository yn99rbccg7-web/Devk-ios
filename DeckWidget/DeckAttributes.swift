import ActivityKit
import Foundation

/// Shared between the Deck app target and the DeckWidget extension target
/// (this file is compiled into both).
struct DeckAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "ready" | "thinking" | "reply"
        var status: String
        /// One-line status or reply snippet.
        var line: String
    }

    var title: String = "Deck"
}
