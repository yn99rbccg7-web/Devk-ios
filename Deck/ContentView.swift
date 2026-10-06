import SwiftUI

struct ContentView: View {
    @EnvironmentObject var agent: AgentLoop
    @StateObject private var downloader = ModelDownloader()
    @State private var modelURLString = ModelDownloader.defaultModelURL
    @State private var input = ""
    @State private var showSettings = false

    var body: some View {
        Group {
            if downloader.modelExists {
                chatView
            } else {
                downloadView
            }
        }
        .onAppear {
            _ = downloader.modelExists
            if downloader.modelExists { downloader.state = .done }
        }
    }

    // MARK: - Chat

    private var chatView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(agent.messages) { m in
                                messageBubble(m)
                                    .id(m.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: agent.messages.count) { _ in
                        if let last = agent.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                if agent.isWorking {
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Text(agent.engineState).font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                HStack {
                    TextField("Ask Deck anything…", text: $input, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1 ... 4)
                    Button("Send") {
                        let text = input
                        input = ""
                        Task { await agent.send(text) }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.isWorking)
                }
                .padding()
            }
            .navigationTitle("Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    Form {
                        Section("Brain") {
                            Text("Qwen3 1.7B (uncensored) · on-device · offline")
                                .font(.caption)
                        }
                        Section {
                            Button("Clear chat", role: .destructive) {
                                agent.clearChat()
                                showSettings = false
                            }
                        }
                        Section("Summon") {
                            Text("“Hey Siri, ask Deck …” works from any app.")
                                .font(.caption)
                        }
                    }
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    private func messageBubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.role == .user { Spacer(minLength: 40) }
            Text(m.text)
                .padding(10)
                .background(
                    m.role == .user ? Color.blue.opacity(0.85) :
                        (m.isToolStatus ? Color.gray.opacity(0.15) : Color.gray.opacity(0.25))
                )
                .foregroundColor(m.role == .user ? .white : .primary)
                .cornerRadius(12)
                .font(m.isToolStatus ? .caption : .body)
            if m.role != .user { Spacer(minLength: 40) }
        }
    }

    // MARK: - First-launch model download

    private var downloadView: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                Text("Deck needs its brain")
                    .font(.title2).bold()
                Text("One download (~5 GB, Wi-Fi recommended). After that the uncensored model lives on your iPhone and works fully offline.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                TextField("Model URL", text: $modelURLString, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .padding(.horizontal)

                if downloader.state == .downloading || downloader.progress > 0 {
                    ProgressView(value: downloader.progress)
                        .padding(.horizontal)
                    Text(String(format: "%.0f / %.0f MB", downloader.downloadedMB, downloader.totalMB))
                        .font(.caption).foregroundColor(.secondary)
                }

                if case .failed(let msg) = downloader.state {
                    Text(msg).foregroundColor(.red).font(.caption).padding(.horizontal)
                }

                Button(downloader.state == .downloading ? "Downloading…" : "Download brain") {
                    downloader.start(urlString: modelURLString)
                }
                .buttonStyle(.borderedProminent)
                .disabled(downloader.state == .downloading)

                if downloader.state == .done {
                    Button("Enter Deck") {
                        _ = downloader.modelExists
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
            .padding(.top, 40)
            .navigationTitle("Deck")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
