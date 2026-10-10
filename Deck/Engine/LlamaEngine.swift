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
            .appendingPathComponent("models/brain-4b.gguf").path
    }

    var modelExists: Bool {
        FileManager.default.fileExists(atPath: modelPath)
    }

    /// Load the GGUF model. Call once; subsequent calls are no-ops.
    /// 2048 ctx keeps the 4B brain's KV cache (~150MB) clear of the jetsam line on 6GB iPhones.
    func load(nCtx: Int32 = 2048) throws {
        if isLoaded { return }
        // D1 FIX: Use refcounted backend (shared with VisionEngine).
        LlamaBackendManager.shared.acquire()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 99 // offload everything to Metal
        guard let m = llama_model_load_from_file(modelPath, mparams) else {
            LlamaBackendManager.shared.release()
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
            LlamaBackendManager.shared.release()
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
        // D1 FIX: Release backend via refcount (VisionEngine may be using it).
        LlamaBackendManager.shared.release()
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
    /// A1 FIX: Checks prompt token count against n_ctx; throws if too large.
    /// A2 FIX: Throws EngineError on decode failure instead of silent return.
    func generate(prompt: String, maxTokens: Int = 512) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                do {
                    try self.runGenerate(prompt: prompt, maxTokens: maxTokens) { piece in
                        continuation.yield(piece)
                    }
                } catch {
                    // A2: Surface the error via a sentinel piece (stream can't throw).
                    // AgentLoop checks for this prefix.
                    continuation.yield("⚠️ ENGINE_ERROR: \(error.localizedDescription)")
                }
                continuation.finish()
            }
        }
    }

    /// Estimate token count (conservative: ~1 token per 3.5 chars for mixed content).
    func estimateTokens(_ text: String) -> Int {
        return Int(Double(text.count) / 3.5) + 1
    }

    /// Maximum prompt tokens allowed (leaves room for maxTokens generation).
    var maxPromptTokens: Int {
        return 2048 - 512 - 64  // n_ctx - maxTokens - safety margin
    }

    private func runGenerate(prompt: String, maxTokens: Int, onPiece: (String) -> Void) throws {
        guard let ctx, let vocab, let sampler, isLoaded else {
            throw EngineError.notLoaded
        }

        // A1 FIX: Check prompt fits in context before decoding.
        let promptTokens = estimateTokens(prompt)
        guard promptTokens <= maxPromptTokens else {
            throw EngineError.contextFailed
        }

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
            guard llama_decode(ctx, batch) == 0 else { throw EngineError.contextFailed }
            pos += Int32(chunk)
            i += chunk
        }

        // Autoregressive decode loop.
        let eos = llama_vocab_eos(vocab)
        var nCur = pos
        // B1 FIX: Buffer for partial UTF-8 sequences. Tokens often split
        // multi-byte codepoints; decoding each in isolation drops them.
        var utf8Buffer: [UInt8] = []
        for _ in 0 ..< maxTokens {
            let tok = llama_sampler_sample(sampler, ctx, batch.n_tokens - 1)
            llama_sampler_accept(sampler, tok)
            if tok == eos { break }

            var buf = [CChar](repeating: 0, count: 64)
            let len = llama_token_to_piece(vocab, tok, &buf, 64, 0, false)
            // B2 FIX: Handle len < 0 (buffer too small) by skipping.
            guard len > 0 else { continue }
            let bytes = buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
            utf8Buffer.append(contentsOf: bytes)
            // Try to decode; if incomplete, keep buffering.
            if let piece = String(bytes: utf8Buffer, encoding: .utf8) {
                utf8Buffer.removeAll(keepingCapacity: true)
                if piece == "<|im_end|>" { break }  // Qwen3 end-of-turn
                onPiece(piece)
            }
            // Else: incomplete UTF-8, keep bytes buffered for next token.

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
        // Flush any remaining buffered bytes (incomplete sequence at end).
        if !utf8Buffer.isEmpty, let piece = String(bytes: utf8Buffer, encoding: .utf8) {
            onPiece(piece)
        }
    }

    // MARK: - Chat template (Qwen3 / ChatML)

    nonisolated static func qwen3Chat(system: String,
                                     transcript: String) -> String {
        "<|im_start|>system\n\(system)<|im_end|>\n" +
        transcript +
        "<|im_start|>assistant\n"
    }

    nonisolated static func userTurn(_ text: String) -> String {
        "<|im_start|>user\n\(text)<|im_end|>\n"
    }

    nonisolated static func assistantTurn(_ text: String) -> String {
        "<|im_start|>assistant\n\(text)<|im_end|>\n"
    }
}
