import Foundation

/// Copy-paste commands that apply a plan's context and KV type for each runner.
enum LaunchCommand {
    static func text(for model: CatalogModel, context: Int, quant: KVQuant) -> String {
        switch model.runner {
        case .ollama:
            var lines: [String] = []
            if quant != .fp16 {
                lines.append("# KV type is server-wide. Set once, then restart Ollama:")
                lines.append("launchctl setenv OLLAMA_FLASH_ATTENTION 1")
                lines.append("launchctl setenv OLLAMA_KV_CACHE_TYPE \(quant.rawValue)")
            }
            lines.append("ollama run \(model.name)")
            lines.append("/set parameter num_ctx \(context)")
            lines.append("# API: \"options\": {\"num_ctx\": \(context)}")
            return lines.joined(separator: "\n")
        case .lmStudio:
            var lines = ["lms load \(model.name) --context-length \(context) -y"]
            if quant != .fp16 {
                lines.append("# Set K/V cache quantization to \(quant.label) in LM Studio's model load settings.")
            }
            return lines.joined(separator: "\n")
        case .llamaServer:
            return llamaServer(path: nil, context: context, quant: quant)
        }
    }

    static func llamaServer(path: String?, context: Int, quant: KVQuant) -> String {
        var parts = ["llama-server", "-m", path.map { "\"\($0)\"" } ?? "<model.gguf>", "-c", "\(context)"]
        if quant != .fp16 {
            // Quantized V cache requires flash attention in llama.cpp.
            parts += ["-fa", "on", "-ctk", quant.rawValue, "-ctv", quant.rawValue]
        }
        return parts.joined(separator: " ")
    }
}
