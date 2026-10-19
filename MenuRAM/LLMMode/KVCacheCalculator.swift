import Foundation

enum KVQuant: String, CaseIterable, Identifiable {
    case fp16
    case q8_0
    case q4_0

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fp16: return "FP16"
        case .q8_0: return "Q8_0"
        case .q4_0: return "Q4_0"
        }
    }

    /// llama.cpp block formats: q8_0 is 34 bytes per 32 values, q4_0 is 18 bytes per 32.
    var bytesPerElement: Double {
        switch self {
        case .fp16: return 2.0
        case .q8_0: return 34.0 / 32.0
        case .q4_0: return 18.0 / 32.0
        }
    }
}

/// One attention layer's cache shape. `window` caps cached tokens for sliding-window layers.
struct KVLayer: Equatable {
    let kvHeads: Int
    let keyDim: Int
    let valueDim: Int
    let window: Int?

    func elementsPerToken() -> Int { kvHeads * (keyDim + valueDim) }
}

struct KVProfile: Equatable {
    enum Source: String {
        case ollama = "Ollama metadata"
        case gguf = "GGUF header"
        case mlxConfig = "MLX config.json"
        case preset = "typical shape"
        case heuristic = "size heuristic"
    }

    let layers: [KVLayer]
    let source: Source

    var isExact: Bool { source != .heuristic }

    func kvBytes(context: Int, quant: KVQuant) -> UInt64 {
        guard context > 0 else { return 0 }
        var elements = 0.0
        for layer in layers {
            let tokens = min(context, layer.window ?? context)
            elements += Double(layer.elementsPerToken()) * Double(tokens)
        }
        return UInt64(elements * quant.bytesPerElement)
    }

    /// Dense GQA models land near 16 KB of FP16 KV per token per billion parameters
    /// (Llama 3.1 8B is 128 KB/token, Qwen2.5 14B is 192 KB/token).
    static func heuristic(parameterBillions: Double) -> KVProfile {
        let elementsPerToken = max(1, Int(parameterBillions * 8192))
        return KVProfile(
            layers: [KVLayer(kvHeads: 1, keyDim: elementsPerToken / 2, valueDim: elementsPerToken / 2, window: nil)],
            source: .heuristic
        )
    }

    /// Q4-ish GGUF/MLX files run about 0.6 bytes per parameter.
    static func heuristic(weightBytes: UInt64) -> KVProfile {
        heuristic(parameterBillions: Double(weightBytes) / 0.6 / 1_000_000_000)
    }
}

/// Live room for a model load, already net of whatever the planned model currently holds.
struct MemoryBudget: Equatable {
    /// GPU ceiling minus current wired. Past this, Metal allocations fail or fall back to CPU.
    /// Conservative: kernel wired counts against it here.
    var metalHeadroomBytes: UInt64
    /// Standard mode's Available. Past this, macOS compresses or swaps other apps to make room.
    var ramHeadroomBytes: UInt64
    /// Rough RAM the compressor could take back cheaply from frozen apps.
    var freezeReclaimBytes: UInt64
}

enum PlanRecommendation: Equatable {
    /// Under the GPU ceiling and inside free RAM.
    case fits
    /// Under the GPU ceiling, but macOS must squeeze other apps first.
    case tight(squeezeBytes: UInt64)
    case useQuant(KVQuant)
    case freezeApps(quant: KVQuant)
    case reduceContext(to: Int, quant: KVQuant)
    case modelTooLarge(shortByBytes: UInt64)
}

struct ContextPlan: Equatable {
    let weightsBytes: UInt64
    let kvBytes: UInt64
    let overheadBytes: UInt64
    /// Metal ceiling headroom minus the safety buffer.
    let hardLimitBytes: UInt64
    /// Available RAM minus the safety buffer.
    let comfortLimitBytes: UInt64
    /// Largest context under the hard limit, per KV type.
    let maxContext: [KVQuant: Int]
    /// Largest context that also stays inside free RAM.
    let maxComfortContext: [KVQuant: Int]
    let maxComfortContextIfFrozen: [KVQuant: Int]
    let recommendation: PlanRecommendation

    var neededBytes: UInt64 { weightsBytes + kvBytes + overheadBytes }
    var fitsHard: Bool { neededBytes <= hardLimitBytes }
    var fitsComfortably: Bool { fitsHard && neededBytes <= comfortLimitBytes }
}

enum ContextPlanner {
    static let safetyBufferBytes: UInt64 = 1_073_741_824
    /// llama.cpp compute buffers and graph scratch; grows a little with context.
    static let baseOverheadBytes: UInt64 = 400 * 1_048_576
    static let contextSteps = [2048, 4096, 8192, 16384, 32768, 65536, 131072]

    static func plan(
        weightsBytes: UInt64,
        profile: KVProfile,
        context: Int,
        quant: KVQuant,
        budget: MemoryBudget,
        maxModelContext: Int?
    ) -> ContextPlan {
        let ceilingContext = maxModelContext ?? 262_144
        let hard = usable(budget.metalHeadroomBytes)
        let comfort = min(hard, usable(budget.ramHeadroomBytes))
        let comfortFrozen = min(hard, usable(budget.ramHeadroomBytes + budget.freezeReclaimBytes))

        func solve(_ limit: UInt64) -> [KVQuant: Int] {
            var result: [KVQuant: Int] = [:]
            for candidate in KVQuant.allCases {
                result[candidate] = largestContext(
                    weightsBytes: weightsBytes, profile: profile, quant: candidate,
                    limit: limit, ceiling: ceilingContext
                )
            }
            return result
        }
        let maxContext = solve(hard)
        let maxComfort = solve(comfort)
        let maxComfortFrozen = solve(comfortFrozen)

        let kv = profile.kvBytes(context: context, quant: quant)
        let overhead = overheadBytes(context: context)
        let needed = weightsBytes + kv + overhead
        let smallerQuants = KVQuant.allCases.filter { $0.bytesPerElement < quant.bytesPerElement }
        let sameOrSmaller = KVQuant.allCases.filter { $0.bytesPerElement <= quant.bytesPerElement }

        let recommendation: PlanRecommendation
        if needed > hard {
            if let better = smallerQuants.first(where: { (maxContext[$0] ?? 0) >= context }) {
                recommendation = .useQuant(better)
            } else if let best = maxContext[.q8_0], best >= 2048 {
                recommendation = .reduceContext(to: best, quant: .q8_0)
            } else {
                let floor = weightsBytes + overheadBytes(context: 2048)
                recommendation = .modelTooLarge(shortByBytes: floor > hard ? floor - hard : 0)
            }
        } else if needed > comfort {
            if budget.freezeReclaimBytes > 0,
               let frozenQuant = sameOrSmaller.first(where: { (maxComfortFrozen[$0] ?? 0) >= context }) {
                recommendation = .freezeApps(quant: frozenQuant)
            } else if let better = smallerQuants.first(where: { (maxComfort[$0] ?? 0) >= context }) {
                recommendation = .useQuant(better)
            } else {
                recommendation = .tight(squeezeBytes: needed - comfort)
            }
        } else {
            recommendation = .fits
        }

        return ContextPlan(
            weightsBytes: weightsBytes,
            kvBytes: kv,
            overheadBytes: overhead,
            hardLimitBytes: hard,
            comfortLimitBytes: comfort,
            maxContext: maxContext,
            maxComfortContext: maxComfort,
            maxComfortContextIfFrozen: maxComfortFrozen,
            recommendation: recommendation
        )
    }

    static func overheadBytes(context: Int) -> UInt64 {
        baseOverheadBytes + UInt64(context) * 4096
    }

    private static func usable(_ bytes: UInt64) -> UInt64 {
        bytes > safetyBufferBytes ? bytes - safetyBufferBytes : 0
    }

    /// Largest context (rounded down to 1k) whose weights + KV + overhead fit under `limit`.
    private static func largestContext(
        weightsBytes: UInt64,
        profile: KVProfile,
        quant: KVQuant,
        limit: UInt64,
        ceiling: Int
    ) -> Int {
        func fits(_ context: Int) -> Bool {
            weightsBytes + profile.kvBytes(context: context, quant: quant) + overheadBytes(context: context) <= limit
        }
        guard fits(1024) else { return 0 }
        var low = 1024
        var high = max(ceiling, 1024)
        if fits(high) { return high }
        while high - low > 1024 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        return low / 1024 * 1024
    }
}

enum ContextFormat {
    static func tokens(_ value: Int) -> String {
        if value >= 1024, value % 1024 == 0 {
            return "\(value / 1024)k"
        }
        if value >= 1000 {
            return String(format: "%.1fk", Double(value) / 1024)
        }
        return "\(value)"
    }
}
