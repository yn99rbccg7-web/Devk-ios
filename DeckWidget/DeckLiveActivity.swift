import ActivityKit
import SwiftUI
import WidgetKit

/// The persistent Deck pill: Dynamic Island + Lock Screen.
/// Same system as the device-monitor widget: always visible,
/// tap "Chat" to jump straight into the conversation.
struct DeckLiveActivity: Widget {
    private func chatURL() -> URL { URL(string: "deck://chat")! }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeckAttributes.self) { context in
            // Lock Screen / banner presentation
            HStack(spacing: 12) {
                Image(systemName: "bolt.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deck").font(.headline)
                    Text(context.state.line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Link(destination: chatURL()) {
                    Text("Chat")
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.9))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "bolt.circle.fill").foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Link(destination: chatURL()) {
                        Text("Chat").font(.headline)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.line).lineLimit(2).font(.subheadline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.status == "thinking" ? "Thinking…" : "Deck ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "bolt.circle.fill").foregroundStyle(.green)
            } compactTrailing: {
                Circle()
                    .fill(context.state.status == "thinking" ? Color.orange : Color.green)
                    .frame(width: 9, height: 9)
            } minimal: {
                Image(systemName: "bolt.circle.fill").foregroundStyle(.green)
            }
        }
    }
}
