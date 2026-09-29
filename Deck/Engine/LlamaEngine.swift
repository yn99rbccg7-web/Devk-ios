import Foundation
import LlamaSwift

enum EngineError: Error, LocalizedError {
    case loadFailed
    case contextFailed
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "Could not load model file."
        case .contextFailed: return "Could not create inference context."
        case .notLoaded: return "Model not loaded yet."
        }
    }
}

/// Thin actor wrapper around llama.cpp's C API (via the llama.swift package).
/// Metal GPU offload is enabled; inference runs off the main thread.
actor LlamaEngine {
    static let shared = LlamaEngine()

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private(set) var isLoaded = false

    var modelPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models/dolphin.gguf").path
    }

    var modelExists: Bool {
        FileManager.default.fileExists(atPath: modelPath)
    }

    /// Load the GGUF model. Call once; subsequent calls are no-ops.
    func load(nCtx: Int32 = 4096) throws {
        if isLoaded { return }
        llama_backend_init()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 99 // offload everything to Metal
        guard let m = llama_model_load_from_file(modelPath, mparams) else {
            throw EngineError.loadFailed
        }
        model = m
        vocab = llama_model_get_vocab(m)

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(nCtx)
        cparams.n_batch = 512
        cparams.n_ubatch = 512
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            model = nil
            throw EngineError.contextFailed
        }
        ctx = c

        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.8))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0 ... UInt32.max)))
        sampler = chain

        isLoaded = true
    }

    func unload() {
        if let s = sampler { llama_sampler_free(s); sampler = nil }
        if let c = ctx { llama_free(c); ctx = nil }
        if let m = model { llama_model_free(m); model = nil }
        vocab = nil
        llama_backend_free()
        isLoaded = false
    }

    // MARK: - Tokenization

    private func tokenize(_ text: String, addBOS: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        let utf8Count = text.utf8.count
        var tokens = [llama_token](repeating: 0, count: utf8Count + 4)
        let n = llama_tokenize(vocab, text, Int32(utf8Count),
                               &tokens, Int32(tokens.count), addBOS, true)
        guard n > 0 else { return [] }
        return Array(tokens.prefix(Int(n)))
    }

    // MARK: - Generation

    /// Streams generated text pieces for a fully-formed prompt.
    func generate(prompt: String, maxTokens: Int = 512) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                self.runGenerate(prompt: prompt, maxTokens: maxTokens) { piece in
                    continuation.yield(piece)
                }
                continuation.finish()
            }
        }
    }

    private func runGenerate(prompt: String, maxTokens: Int, onPiece: (String) -> Void) {
        guard let ctx, let vocab, let sampler, isLoaded else { return }

        var batch = llama_batch_init(512, 0, 1)
        defer { llama_batch_free(batch) }

        // Feed the prompt in n_batch-sized chunks.
        let tokens = tokenize(prompt, addBOS: true)
        var pos: Int32 = 0
        var i = 0
        while i < tokens.count {
            let chunk = min(512, tokens.count - i)
            batch.n_tokens = Int32(chunk)
            for j in 0 ..< chunk {
                batch.token[j] = tokens[i + j]
                batch.pos[j] = pos + Int32(j)
                batch.n_seq_id[j] = 1
                if let seqIds = batch.seq_id, let seqId = seqIds[j] {
                    seqId[0] = 0
                }
                batch.logits[j] = 0
            }
            batch.logits[chunk - 1] = 1
            guard llama_decode(ctx, batch) == 0 else { return }
            pos += Int32(chunk)
            i += chunk
        }

        // Autoregressive decode loop.
        let eos = llama_vocab_eos(vocab)
        var nCur = pos
        for _ in 0 ..< maxTokens {
            let tok = llama_sampler_sample(sampler, ctx, batch.n_tokens - 1)
            llama_sampler_accept(sampler, tok)
            if tok == eos { break }

            var buf = [CChar](repeating: 0, count: 64)
            let len = llama_token_to_piece(vocab, tok, &buf, 64, 0, false)
            if len > 0 {
                let bytes = buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
                if let piece = String(bytes: bytes, encoding: .utf8) {
                    if piece == "<|eot_id|>" { break }
                    onPiece(piece)
                }
            }

            batch.n_tokens = 1
            batch.token[0] = tok
            batch.pos[0] = nCur
            batch.n_seq_id[0] = 1
            if let seqIds = batch.seq_id, let seqId = seqIds[0] {
                seqId[0] = 0
            }
            batch.logits[0] = 1
            guard llama_decode(ctx, batch) == 0 else { break }
            nCur += 1
        }
    }

    // MARK: - Chat template (Llama 3)

    nonisolated static func llama3Chat(system: String,
                                       transcript: String) -> String {
        "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n\(system)<|eot_id|>" +
        transcript +
        "<|start_header_id|>assistant<|end_header_id|>\n\n"
    }

    nonisolated static func userTurn(_ text: String) -> String {
        "<|start_header_id|>user<|end_header_id|>\n\n\(text)<|eot_id|>"
    }

    nonisolated static func assistantTurn(_ text: String) -> String {
        "<|start_header_id|>assistant<|end_header_id|>\n\n\(text)<|eot_id|>"
    }
}
