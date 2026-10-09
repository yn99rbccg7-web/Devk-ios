import SwiftUI

struct ContentView: View {
    @EnvironmentObject var agent: AgentLoop
    @StateObject private var downloader = ModelDownloader()
    @State private var modelURLString = ModelDownloader.defaultModelURL
    @StateObject private var visionModelDl = ModelDownloader(filename: "models/vision-0.8b.gguf")
    @StateObject private var visionMmprojDl = ModelDownloader(filename: "models/vision-0.8b.mmproj.gguf")
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
                    .onChange(of: agent.messages.count) { _, _ in
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
                            Text("NeoHorse 4B abliterated · on-device · offline")
                                .font(.caption)
                        }
                        Section("Vision") {
                            if visionReady {
                                Text("MiniCPM-V 0.8B abliterated · on-device · on-demand")
                                    .font(.caption)
                            } else {
                                Text("Lets Deck actually see screenshots (~1.15 GB total, Wi-Fi).")
                                    .font(.caption)
                                visionDlRow(title: "Vision model (~0.42 GB)",
                                            dl: visionModelDl,
                                            urlString: VisionEngine.modelURLString)
                                visionDlRow(title: "Vision projector (~0.73 GB)",
                                            dl: visionMmprojDl,
                                            urlString: VisionEngine.mmprojURLString)
                            }
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

    private var visionReady: Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return FileManager.default.fileExists(
            atPath: docs.appendingPathComponent("models/vision-0.8b.gguf").path)
            && FileManager.default.fileExists(
                atPath: docs.appendingPathComponent("models/vision-0.8b.mmproj.gguf").path)
    }

    @ViewBuilder
    private func visionDlRow(title: String, dl: ModelDownloader, urlString: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption)
            if dl.state == .downloading || dl.progress > 0 {
                ProgressView(value: dl.progress)
                Text(String(format: "%.0f / %.0f MB", dl.downloadedMB, dl.totalMB))
                    .font(.caption2).foregroundColor(.secondary)
            }
            if case .failed(let msg) = dl.state {
                Text(msg).foregroundColor(.red).font(.caption2)
            }
            Button(dl.state == .downloading ? "Downloading…" : "Download") {
                dl.start(urlString: urlString)
            }
            .buttonStyle(.bordered)
            .disabled(dl.state == .downloading || dl.state == .done)
        }
        .padding(.vertical, 4)
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
