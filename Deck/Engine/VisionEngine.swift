import Foundation
import LlamaSwift

/// On-demand vision brain: MiniCPM-V-4.6 0.8B abliterated (0.42GB) + mmproj (0.73GB).
/// Loads only for a see_image call and unloads before returning — never resident
/// alongside the 2.5GB text brain.
///
/// Requires the mtmd-enabled llama.cpp XCFramework (Shalom-P/llama.swift fork,
/// LLAMA_BUILD_MTMD=ON); stock mattt/llama.swift has no mtmd symbols.
/// Inference pattern follows llama.cpp's own tools/mtmd/mtmd-cli.cpp (b8881):
/// tokenize prompt + bitmap with the <__media__> marker, mtmd_helper_eval_chunks,
/// then autoregressive decode sampling from logit -1.
actor VisionEngine {
    static let shared = VisionEngine()

    static let modelURLString =
        "https://huggingface.co/mradermacher/MiniCPM-V-4.6-0.8B-Abliterated-GGUF/resolve/main/MiniCPM-V-4.6-0.8B-Abliterated.Q2_K.gguf"
    static let mmprojURLString =
        "https://huggingface.co/mradermacher/MiniCPM-V-4.6-0.8B-Abliterated-GGUF/resolve/main/MiniCPM-V-4.6-0.8B-Abliterated.mmproj-Q8_0.gguf"

    private func docs(_ name: String) -> String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models/" + name).path
    }
    var modelPath: String { docs("vision-0.8b.gguf") }
    var mmprojPath: String { docs("vision-0.8b.mmproj.gguf") }

    var isReady: Bool {
        FileManager.default.fileExists(atPath: modelPath)
            && FileManager.default.fileExists(atPath: mmprojPath)
    }

    /// Describe the image at imagePath. Self-contained: loads the vision stack,
    /// runs inference, unloads everything before returning.
    func describe(imagePath: String, prompt: String) -> String {
        guard isReady else { return "Vision model not downloaded yet." }
        guard FileManager.default.fileExists(atPath: imagePath) else {
            return "Image not found."
        }

        llama_backend_init()
        defer { llama_backend_free() }

        // 1. Text model (the VLM's language tower).
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 99 // offload everything to Metal
        guard let m = llama_model_load_from_file(modelPath, mparams) else {
            return "Vision model failed to load."
        }
        defer { llama_model_free(m) }
        guard let vocab = llama_model_get_vocab(m) else {
            return "Vision vocab failed."
        }

        // 2. Multimodal projector.
        var mp = mtmd_context_params_default()
        mp.use_gpu = true
        guard let mc: OpaquePointer = mmprojPath.withCString({ cpath in
            mtmd_init_from_file(cpath, m, mp)
        }) else {
            return "mmproj failed to load."
        }
        defer { mtmd_free(mc) }

        // 3. Image bitmap (PNG/JPEG decoded by mtmd's bundled stb).
        guard let bmp: OpaquePointer = imagePath.withCString({ cpath in
            mtmd_helper_bitmap_init_from_file(mc, cpath)
        }) else {
            return "Could not read image."
        }
        defer { mtmd_bitmap_free(bmp) }

        // 4. Tokenize prompt + image (marker count must equal bitmap count).
        guard let chunks = mtmd_input_chunks_init() else {
            return "Chunk alloc failed."
        }
        defer { mtmd_input_chunks_free(chunks) }

        let ask = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let marked = "<__media__>\n" + (ask.isEmpty ? "Describe this image in detail." : ask)

        // 5. Small context: a description never needs more.
        var cparams = llama_context_default_params()
        cparams.n_ctx = 1024
        cparams.n_batch = 512
        guard let lc = llama_init_from_model(m, cparams) else {
            return "Vision context failed."
        }
        defer { llama_free(lc) }

        // 6. Sampler.
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.8))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0 ... UInt32.max)))
        defer { llama_sampler_free(chain) }

        // 7. Tokenize, eval chunks, generate. The prompt string must outlive
        // mtmd_tokenize, so everything happens inside withCString.
        var out = ""
        var failure = ""
        marked.withCString { cstr in
            var inputText = mtmd_input_text(text: cstr, add_special: true, parse_special: true)
            var bitmaps: [OpaquePointer?] = [bmp]
            bitmaps.withUnsafeMutableBufferPointer { buf in
                guard mtmd_tokenize(mc, chunks, &inputText, buf.baseAddress, 1) == 0 else {
                    failure = "Vision tokenize failed."
                    return
                }
                var nPast: llama_pos = 0
                guard mtmd_helper_eval_chunks(mc, lc, chunks, nPast, 0, 512,
                                              true, &nPast) == 0 else {
                    failure = "Vision eval failed."
                    return
                }
                // Autoregressive decode, sampling from the last logit (idx -1),
                // mirroring mtmd-cli.cpp.
                var batch = llama_batch_init(512, 0, 1)
                defer { llama_batch_free(batch) }
                let eos = llama_vocab_eos(vocab)
                var nCur = nPast
                for _ in 0 ..< 256 {
                    let tok = llama_sampler_sample(chain, lc, -1)
                    llama_sampler_accept(chain, tok)
                    if tok == eos { break }
                    var pbuf = [CChar](repeating: 0, count: 64)
                    let len = llama_token_to_piece(vocab, tok, &pbuf, 64, 0, false)
                    if len > 0 {
                        let bytes = pbuf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
                        if let piece = String(bytes: bytes, encoding: .utf8) {
                            out += piece
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
                    guard llama_decode(lc, batch) == 0 else { break }
                    nCur += 1
                }
            }
        }
        if !failure.isEmpty { return failure }
        let clean = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "(no description)" : String(clean.prefix(2000))
    }
}
