import Foundation

enum RunnerKind: String {
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case llamaServer = "llama-server"
}

/// A model resident in memory right now.
struct LoadedModel: Identifiable, Equatable {
    var id: String { "\(runner.rawValue):\(name)" }
    let name: String
    let runner: RunnerKind
    /// Everything the runner holds for this model: weights, KV cache, compute buffers.
    let residentBytes: UInt64
    let contextLength: Int?
    let pid: pid_t?
}

/// A model on disk that can be planned before loading.
struct CatalogModel: Identifiable, Equatable {
    let id: String
    let name: String
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

struct RunnerStatus: Equatable {
    var loaded: [LoadedModel] = []
    var runnerPids: Set<pid_t> = []
    var ollamaReachable = false
    var lmStudioReachable = false
}

/// Talks to local inference servers. All network calls hit 127.0.0.1 with short timeouts.
actor LLMRunnerDetector {
    private let session: URLSession
    private var profileCache: [String: (KVProfile, Int?)] = [:]

    private static let ollamaBase = URL(string: "http://127.0.0.1:11434")!
    private static let lmStudioBase = URL(string: "http://127.0.0.1:1234")!
    private static let runnerProcessNames: Set<String> = ["llama-server", "ollama", "ollama_llama_server", "llama-cli", "mlx_lm.server"]
    private static let lmStudioModelsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lmstudio/models", isDirectory: true)

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

        // Ollama reports exact per-model size; prefer it over process RSS.
        status.loaded.append(contentsOf: ollamaResult ?? [])

        let lmStudioServers = runners
            .filter { $0.rawName == "llama-server" && $0.groupName != "ollama" }
            .compactMap { sample -> (ProcessSample, UInt64)? in
                guard let rss = ProcessMemoryProvider.residentBytes(for: sample.pid) else { return nil }
                return (sample, max(rss, sample.bytes))
            }
            .sorted { $0.1 > $1.1 }

        var unclaimed = lmStudioServers
        for model in lmResult ?? [] {
            let server = unclaimed.isEmpty ? nil : unclaimed.removeFirst()
            status.loaded.append(LoadedModel(
                name: model.name,
                runner: .lmStudio,
                residentBytes: server?.1 ?? 0,
                contextLength: model.context,
                pid: server?.0.pid
            ))
        }
        for (sample, bytes) in unclaimed where bytes > 256 * 1_048_576 {
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

    private func lmStudioLoaded() async -> [(name: String, context: Int?)]? {
        guard let models = await lmStudioModels() else { return nil }
        return models.filter { $0.state == "loaded" }.map { ($0.id, $0.loaded_context_length) }
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
        async let ollama = ollamaCatalog()
        async let lmStudio = lmStudioCatalog()
        let (a, b) = await (ollama, lmStudio)
        return (a + b).sorted { $0.weightsBytes < $1.weightsBytes }
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

    /// LM Studio's API knows model keys; the model folder knows sizes and architecture.
    private func lmStudioCatalog() async -> [CatalogModel] {
        let apiModels = await lmStudioModels() ?? []
        let folders = Self.lmStudioFolders()
        var result: [CatalogModel] = []
        for model in apiModels where model.type != "embeddings" {
            guard let folder = Self.matchFolder(for: model.id, format: model.compatibility_type, in: folders) else { continue }
            result.append(CatalogModel(
                id: "lmstudio:\(model.id)",
                name: model.id,
                runner: .lmStudio,
                weightsBytes: folder.weightsBytes,
                maxContext: model.max_context_length,
                quantization: model.quantization,
                source: folder.source
            ))
        }
        return result
    }

    private struct ModelFolder {
        let key: String
        let weightsBytes: UInt64
        let source: CatalogModel.ProfileSource
    }

    private static func lmStudioFolders() -> [ModelFolder] {
        let fm = FileManager.default
        guard let publishers = try? fm.contentsOfDirectory(at: lmStudioModelsDir, includingPropertiesForKeys: nil) else { return [] }
        var folders: [ModelFolder] = []
        for publisher in publishers {
            guard let repos = try? fm.contentsOfDirectory(at: publisher, includingPropertiesForKeys: nil) else { continue }
            for repo in repos {
                guard let files = try? fm.contentsOfDirectory(at: repo, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
                let sizes = files.map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0) }
                let ggufs = sizes.filter { $0.0.pathExtension == "gguf" && !$0.0.lastPathComponent.hasPrefix("mmproj") }
                if let largest = ggufs.max(by: { $0.1 < $1.1 }) {
                    folders.append(ModelFolder(key: repo.lastPathComponent.lowercased(), weightsBytes: largest.1, source: .gguf(largest.0)))
                    continue
                }
                let config = repo.appendingPathComponent("config.json")
                let weights = sizes.filter { $0.0.pathExtension == "safetensors" }.reduce(0) { $0 + $1.1 }
                if weights > 0, fm.fileExists(atPath: config.path) {
                    folders.append(ModelFolder(key: repo.lastPathComponent.lowercased(), weightsBytes: weights, source: .mlx(configURL: config)))
                }
            }
        }
        return folders
    }

    /// LM Studio keys look like `qwen/qwen3.5-9b` or `qwen3-8b`; folders like `Qwen3.5-9B-MLX-4bit`.
    private static func matchFolder(for modelID: String, format: String?, in folders: [ModelFolder]) -> ModelFolder? {
        let base = (modelID.split(separator: "/").last.map(String.init) ?? modelID).lowercased()
        let candidates = folders.filter { folder in
            guard folder.key.contains(base) else { return false }
            switch (format, folder.source) {
            case ("mlx", .mlx), ("gguf", .gguf), (nil, _):
                return true
            default:
                return false
            }
        }
        // Folder names are not unique per key (GGUF and MLX copies); keep the shortest, most specific match.
        return candidates.min { $0.key.count < $1.key.count }
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
