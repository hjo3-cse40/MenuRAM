import Foundation

enum RunnerKind: String {
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case bionic = "Bionic"
    case llamaServer = "llama-server"
}

/// A model resident in memory right now.
struct LoadedModel: Identifiable, Equatable {
    var id: String { "\(runner.rawValue):\(name)" }
    let name: String
    let runner: RunnerKind
    /// LM Studio model key (e.g. `qwen/qwen3.5-9b`) when known, to match against the catalog.
    var modelKey: String? = nil
    /// Everything the runner holds for this model: weights, KV cache, compute buffers.
    let residentBytes: UInt64
    let contextLength: Int?
    let pid: pid_t?
}

/// A model on disk that can be planned before loading.
struct CatalogModel: Identifiable, Equatable {
    let id: String
    /// Key used by the runner's CLI (`lms load <name>`, `ollama run <name>`).
    let name: String
    var displayName: String? = nil
    /// Other keys LM Studio/Bionic use for the same files.
    var aliases: [String] = []
    let runner: RunnerKind
    let weightsBytes: UInt64
    let maxContext: Int?
    let quantization: String?
    /// Where to read architecture from, if we have one.
    let source: ProfileSource

    enum ProfileSource: Equatable {
        case ollama(model: String)
        case gguf(URL)
        case mlx(configURL: URL)
        case preset(KVProfile)
        case none
    }

    /// Typical Q4_K_M dense models, for planning before anything is downloaded.
    static let presets: [CatalogModel] = [
        preset("8B · Q4 (Llama 3.1 shape)", gb: 4.9, layers: 32, kvHeads: 8, headDim: 128, context: 131_072),
        preset("14B · Q4 (Qwen2.5 shape)", gb: 9.0, layers: 48, kvHeads: 8, headDim: 128, context: 32_768),
        preset("32B · Q4 (Qwen2.5 shape)", gb: 19.9, layers: 64, kvHeads: 8, headDim: 128, context: 32_768),
    ]

    private static func preset(_ name: String, gb: Double, layers: Int, kvHeads: Int, headDim: Int, context: Int) -> CatalogModel {
        let layer = KVLayer(kvHeads: kvHeads, keyDim: headDim, valueDim: headDim, window: nil)
        return CatalogModel(
            id: "preset:\(name)",
            name: name,
            runner: .llamaServer,
            weightsBytes: UInt64(gb * 1_073_741_824),
            maxContext: context,
            quantization: "Q4_K_M",
            source: .preset(KVProfile(layers: Array(repeating: layer, count: layers), source: .preset))
        )
    }
}

extension CatalogModel {
    var label: String { displayName ?? name }

    func renamed(_ key: String) -> CatalogModel {
        CatalogModel(
            id: id, name: key, displayName: displayName, aliases: aliases, runner: runner,
            weightsBytes: weightsBytes, maxContext: maxContext, quantization: quantization, source: source
        )
    }
}

struct RunnerStatus: Equatable {
    var loaded: [LoadedModel] = []
    var runnerPids: Set<pid_t> = []
    var ollamaReachable = false
    var lmStudioReachable = false
    var bionicRunning = false
}

/// Talks to local inference servers. All network calls hit 127.0.0.1 with short timeouts.
actor LLMRunnerDetector {
    private let session: URLSession
    private var profileCache: [String: (KVProfile, Int?)] = [:]

    private static let ollamaBase = URL(string: "http://127.0.0.1:11434")!
    private static let lmStudioBase = URL(string: "http://127.0.0.1:1234")!
    private static let runnerProcessNames: Set<String> = ["llama-server", "ollama", "ollama_llama_server", "llama-cli", "mlx_lm.server"]
    private static let lmStudioHome = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lmstudio", isDirectory: true)
    private static let lmStudioFamily: Set<String> = ["LM Studio", "Bionic"]
    private static let engineProcessNames: Set<String> = ["node", "llama-server"]
    /// UI helpers are a few hundred MB; an engine holding a model is well over this.
    private static let engineMinimumBytes: UInt64 = 1_073_741_824

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.6
        config.timeoutIntervalForResource = 2
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: - Loaded models

    func status(samples: [ProcessSample]) async -> RunnerStatus {
        async let ollama = ollamaLoaded()
        async let lmStudio = lmStudioLoaded()
        let (ollamaResult, lmResult) = await (ollama, lmStudio)

        var status = RunnerStatus()
        status.ollamaReachable = ollamaResult != nil
        status.lmStudioReachable = lmResult != nil

        let runners = samples.filter { Self.runnerProcessNames.contains($0.rawName) }
        status.runnerPids = Set(runners.map(\.pid))
        status.bionicRunning = samples.contains { $0.groupName == "Bionic" }

        // Ollama reports exact per-model size; prefer it over process RSS.
        status.loaded.append(contentsOf: ollamaResult ?? [])

        // LM Studio and Bionic run models inside their own engine processes (llama-server for
        // GGUF, node for MLX/embeddings). MLX weights live in Metal buffers, so footprint is the honest size.
        let lmStudioProcesses = samples
            .filter { Self.lmStudioFamily.contains($0.groupName) && Self.engineProcessNames.contains($0.rawName) }
            .map { sample -> (sample: ProcessSample, bytes: UInt64, role: String) in
                let bytes = max(ProcessMemoryProvider.residentBytes(for: sample.pid) ?? 0, sample.bytes)
                let args = Self.processArgsString(for: sample.pid)
                let role: String
                if sample.rawName == "llama-server" || args.contains("llama-server") {
                    role = "llama-server"
                } else if args.contains("embeddingworker") {
                    role = "embedding"
                } else if args.contains("llmworker") {
                    role = "llm"
                } else {
                    role = "other"
                }
                return (sample, bytes, role)
            }
            .filter { $0.bytes >= 50 * 1_048_576 }
            .sorted { $0.bytes > $1.bytes }

        status.runnerPids.formUnion(lmStudioProcesses.map(\.sample.pid))

        var availableEngines = lmStudioProcesses
        let apiModels = lmResult ?? []

        for model in apiModels {
            let isEmbedding = model.type == "embeddings"
            let matchedIndex = availableEngines.firstIndex { engine in
                if engine.sample.groupName == "Bionic" { return false }
                if isEmbedding {
                    return engine.role == "embedding" || (engine.role == "other" && engine.bytes < 1_073_741_824)
                } else {
                    return engine.role == "llm" || engine.role == "llama-server" || (engine.role == "other" && engine.bytes >= 1_073_741_824)
                }
            } ?? availableEngines.firstIndex { $0.sample.groupName != "Bionic" }

            let engine = matchedIndex.map { availableEngines.remove(at: $0) }
            let name = Self.lmStudioDisplayName(forKey: model.id) ?? model.id
            let resident = engine?.bytes ?? 0

            status.loaded.append(LoadedModel(
                name: name,
                runner: .lmStudio,
                modelKey: model.id,
                residentBytes: resident,
                contextLength: model.loaded_context_length,
                pid: engine?.sample.pid
            ))
        }

        if status.bionicRunning, let bionicKey = Self.bionicSessionModelKey() {
            let bionicEngine = availableEngines.first { $0.sample.groupName == "Bionic" }
            let name = Self.lmStudioDisplayName(forKey: bionicKey) ?? bionicKey
            status.loaded.append(LoadedModel(
                name: name,
                runner: .bionic,
                modelKey: bionicKey,
                residentBytes: bionicEngine?.bytes ?? 0,
                contextLength: nil,
                pid: bionicEngine?.sample.pid
            ))
        }

        let claimed = Set(status.loaded.compactMap(\.pid))
        for sample in runners where sample.rawName == "llama-server" && !claimed.contains(sample.pid) {
            let bytes = max(ProcessMemoryProvider.residentBytes(for: sample.pid) ?? 0, sample.bytes)
            guard bytes > 256 * 1_048_576 else { continue }
            status.loaded.append(LoadedModel(
                name: "llama-server (PID \(sample.pid))",
                runner: .llamaServer,
                residentBytes: bytes,
                contextLength: nil,
                pid: sample.pid
            ))
        }
        return status
    }

    private static func processArgsString(for pid: pid_t) -> String {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer, as: UTF8.self)
    }

    private func ollamaLoaded() async -> [LoadedModel]? {
        struct Response: Decodable {
            struct Model: Decodable {
                let name: String
                let size: UInt64
                let size_vram: UInt64?
                let context_length: Int?
            }
            let models: [Model]
        }
        guard let response: Response = await get(Self.ollamaBase.appendingPathComponent("api/ps")) else { return nil }
        return response.models.map {
            LoadedModel(name: $0.name, runner: .ollama, residentBytes: $0.size, contextLength: $0.context_length, pid: nil)
        }
    }

    private func lmStudioLoaded() async -> [LMStudioModel]? {
        guard let models = await lmStudioModels() else { return nil }
        return models.filter { $0.state == "loaded" }
    }

    private struct LMStudioModel: Decodable {
        let id: String
        let type: String?
        let state: String?
        let quantization: String?
        let compatibility_type: String?
        let max_context_length: Int?
        let loaded_context_length: Int?
    }

    private func lmStudioModels() async -> [LMStudioModel]? {
        struct Response: Decodable { let data: [LMStudioModel] }
        let response: Response? = await get(Self.lmStudioBase.appendingPathComponent("api/v0/models"))
        return response?.data
    }

    // MARK: - Catalog

    /// Models on disk across Ollama and LM Studio, for the planner picker.
    func catalog() async -> [CatalogModel] {
        let ollama = await ollamaCatalog()
        let lmStudio = lmStudioCatalog()
        return (ollama + lmStudio).sorted { $0.weightsBytes < $1.weightsBytes }
    }

    private func ollamaCatalog() async -> [CatalogModel] {
        struct Response: Decodable {
            struct Model: Decodable {
                struct Details: Decodable { let quantization_level: String? }
                let name: String
                let size: UInt64
                let details: Details?
            }
            let models: [Model]
        }
        guard let response: Response = await get(Self.ollamaBase.appendingPathComponent("api/tags")) else { return [] }
        return response.models.map {
            CatalogModel(
                id: "ollama:\($0.name)",
                name: $0.name,
                runner: .ollama,
                weightsBytes: $0.size,
                maxContext: nil,
                quantization: $0.details?.quantization_level,
                source: .ollama(model: $0.name)
            )
        }
    }

    /// LM Studio and Bionic share one model store and each keep an index of it on disk,
    /// so this works with both apps closed and covers the newer `hub/models` layout.
    private func lmStudioCatalog() -> [CatalogModel] {
        var byDirectory: [String: CatalogModel] = [:]
        for entry in Self.lmStudioIndexEntries() {
            guard entry.domain == "llm", let directory = entry.concreteModelDirAbsolutePath else { continue }
            let key = entry.identifier
            let dedupeKey = directory + "|" + (entry.entryPoint?.absPath ?? "")
            if var existing = byDirectory[dedupeKey] {
                existing.aliases.append(key)
                if key.count < existing.name.count {
                    existing = existing.renamed(key)
                }
                byDirectory[dedupeKey] = existing
                continue
            }
            guard let model = Self.catalogModel(for: entry, key: key, directory: directory) else { continue }
            byDirectory[dedupeKey] = model
        }
        return Array(byDirectory.values)
    }

    private struct IndexEntry: Decodable {
        struct Quant: Decodable { let name: String? }
        struct File: Decodable { let absPath: String }
        let domain: String?
        let indexedModelIdentifier: String
        let displayName: String?
        let format: String?
        let contextLength: Int?
        let concreteModelDirAbsolutePath: String?
        let entryPoint: File?
        let quant: Quant?

        var identifier: String { indexedModelIdentifier }
    }

    private static func lmStudioIndexEntries() -> [IndexEntry] {
        /// One odd entry (embeddings, virtual models, older schema) must not drop the whole index.
        struct Lossy: Decodable {
            let entry: IndexEntry?
            init(from decoder: Decoder) throws { entry = try? IndexEntry(from: decoder) }
        }
        struct Index: Decodable {
            let entries: [Lossy]
            enum CodingKeys: String, CodingKey { case entries = "models" }
            var models: [IndexEntry] { entries.compactMap(\.entry) }
        }
        var files = [lmStudioHome.appendingPathComponent(".internal/model-index-cache.json")]
        let apps = lmStudioHome.appendingPathComponent("apps", isDirectory: true)
        if let appDirs = try? FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil) {
            files += appDirs.map { $0.appendingPathComponent(".internal/model-index-cache.json") }
        }
        return files.flatMap { url -> [IndexEntry] in
            guard let data = try? Data(contentsOf: url),
                  let index = try? JSONDecoder().decode(Index.self, from: data)
            else { return [] }
            return index.models
        }
    }

    private static func catalogModel(for entry: IndexEntry, key: String, directory: String) -> CatalogModel? {
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: directory, isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        func size(_ url: URL) -> UInt64 {
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        }

        let weights: UInt64
        let source: CatalogModel.ProfileSource
        var quant = entry.quant?.name
        if entry.format == "gguf" {
            let ggufs = files.filter { $0.pathExtension == "gguf" && !$0.lastPathComponent.hasPrefix("mmproj") }
            let chosen = entry.entryPoint.map { URL(fileURLWithPath: $0.absPath) }.flatMap { point in
                ggufs.first { $0.lastPathComponent == point.lastPathComponent }
            } ?? ggufs.max { size($0) < size($1) }
            guard let chosen else { return nil }
            weights = size(chosen)
            source = .gguf(chosen)
            quant = quant ?? Self.ggufQuant(fromFilename: chosen.lastPathComponent)
        } else {
            weights = files.filter { $0.pathExtension == "safetensors" }.reduce(0) { $0 + size($1) }
            let config = dirURL.appendingPathComponent("config.json")
            guard weights > 0 else { return nil }
            source = fm.fileExists(atPath: config.path) ? .mlx(configURL: config) : .none
            quant = quant.map { "MLX \($0)" } ?? "MLX"
        }

        return CatalogModel(
            id: "lmstudio:\(directory)|\(entry.entryPoint?.absPath ?? "")",
            name: key,
            displayName: entry.displayName,
            aliases: [key],
            runner: .lmStudio,
            weightsBytes: weights,
            maxContext: entry.contextLength,
            quantization: quant,
            source: source
        )
    }

    /// `Qwen3-8B-Q5_K_M.gguf` → `Q5_K_M`.
    private static func ggufQuant(fromFilename name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        guard let range = stem.range(of: #"(I?Q\d[A-Z0-9_]*|F16|BF16|F32)$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(stem[range]).uppercased()
    }

    /// Bionic loads models on demand for its sessions; this is the model those sessions use.
    private static func bionicSessionModelKey() -> String? {
        let url = lmStudioHome.appendingPathComponent("apps/bionic/.internal/settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [String: Any]
        else { return nil }
        for key in ["lastSelectedModelSpecifier", "rootModelSpecifier"] {
            if let spec = sessions[key] as? [String: Any], let id = spec["indexedModelIdentifier"] as? String {
                return id
            }
        }
        return nil
    }

    private static func lmStudioDisplayName(forKey key: String) -> String? {
        let entries = lmStudioIndexEntries()
        if let exact = entries.first(where: { $0.identifier == key })?.displayName {
            return exact
        }
        return entries.first(where: { key.contains($0.identifier) || $0.identifier.contains(key) })?.displayName
    }

    // MARK: - KV profiles

    /// Architecture for a catalog model; falls back to a size heuristic.
    func profile(for model: CatalogModel) async -> (KVProfile, Int?) {
        if let cached = profileCache[model.id] { return cached }

        var result: (KVProfile, Int?)?
        switch model.source {
        case .ollama(let name):
            result = await ollamaProfile(name: name)
        case .gguf(let url):
            result = GGUFMetadata.profile(at: url).map { ($0.profile, $0.contextLength) }
        case .mlx(let configURL):
            result = Self.mlxProfile(configURL: configURL)
        case .preset(let profile):
            result = (profile, model.maxContext)
        case .none:
            result = nil
        }
        let resolved = result ?? (KVProfile.heuristic(weightBytes: model.weightsBytes), model.maxContext)

        profileCache[model.id] = resolved
        return resolved
    }

    private func ollamaProfile(name: String) async -> (KVProfile, Int?)? {
        var request = URLRequest(url: Self.ollamaBase.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        // verbose=true is the only way to get per-layer head counts and sliding-window patterns.
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "verbose": true])
        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["model_info"] as? [String: Any],
              let arch = info["general.architecture"] as? String
        else { return nil }

        func int(_ key: String) -> Int? { (info["\(arch).\(key)"] as? NSNumber)?.intValue }
        guard let layerCount = int("block_count"), layerCount > 0 else { return nil }
        let heads = int("attention.head_count") ?? 0
        let embedding = int("embedding_length") ?? 0
        let keyDim = int("attention.key_length") ?? (heads > 0 ? embedding / heads : 0)
        let valueDim = int("attention.value_length") ?? keyDim
        let keyDimSWA = int("attention.key_length_swa") ?? keyDim
        let valueDimSWA = int("attention.value_length_swa") ?? valueDim
        let window = int("attention.sliding_window")
        let fullInterval = int("full_attention_interval")
        let perLayerHeads = (info["\(arch).attention.head_count_kv"] as? [NSNumber])?.map(\.intValue)
        let uniformHeads = int("attention.head_count_kv") ?? heads
        let pattern = (info["\(arch).attention.sliding_window_pattern"] as? [Bool])
        guard keyDim > 0 else { return nil }

        var layers: [KVLayer] = []
        for index in 0..<layerCount {
            if let fullInterval, fullInterval > 1, (index + 1) % fullInterval != 0 { continue }
            let kvHeads = perLayerHeads.flatMap { $0.count == layerCount ? $0[index] : nil } ?? uniformHeads
            guard kvHeads > 0 else { continue }
            let isSliding = pattern.flatMap { $0.count == layerCount ? $0[index] : nil } ?? false
            layers.append(KVLayer(
                kvHeads: kvHeads,
                keyDim: isSliding ? keyDimSWA : keyDim,
                valueDim: isSliding ? valueDimSWA : valueDim,
                window: isSliding ? window : nil
            ))
        }
        guard !layers.isEmpty else { return nil }
        return (KVProfile(layers: layers, source: .ollama), int("context_length"))
    }

    static func mlxProfile(configURL: URL) -> (KVProfile, Int?)? {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let config = (root["text_config"] as? [String: Any]) ?? root

        func int(_ key: String) -> Int? { (config[key] as? NSNumber)?.intValue }
        guard let layerCount = int("num_hidden_layers"), layerCount > 0 else { return nil }
        let heads = int("num_attention_heads") ?? 0
        let kvHeads = int("num_key_value_heads") ?? heads
        let headDim = int("head_dim") ?? (heads > 0 ? (int("hidden_size") ?? 0) / heads : 0)
        let window = int("sliding_window")
        let layerTypes = config["layer_types"] as? [String]
        guard kvHeads > 0, headDim > 0 else { return nil }

        var layers: [KVLayer] = []
        for index in 0..<layerCount {
            let type = layerTypes.flatMap { $0.count == layerCount ? $0[index] : nil } ?? "full_attention"
            switch type {
            case "linear_attention":
                continue
            case "sliding_attention":
                layers.append(KVLayer(kvHeads: kvHeads, keyDim: headDim, valueDim: headDim, window: window))
            default:
                layers.append(KVLayer(kvHeads: kvHeads, keyDim: headDim, valueDim: headDim, window: nil))
            }
        }
        guard !layers.isEmpty else { return nil }
        return (KVProfile(layers: layers, source: .mlxConfig), int("max_position_embeddings"))
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ url: URL) async -> T? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
