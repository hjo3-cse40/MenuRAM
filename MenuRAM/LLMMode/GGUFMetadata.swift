import Foundation

/// Reads only the key/value header of a GGUF file to build a KV cache profile.
enum GGUFMetadata {
    enum Value {
        case int(Int)
        case double(Double)
        case bool(Bool)
        case string(String)
        case intArray([Int])
        case boolArray([Bool])
        case skipped
    }

    static func profile(at url: URL) -> (profile: KVProfile, contextLength: Int?)? {
        guard let metadata = read(url) else { return nil }
        guard case .string(let arch)? = metadata["general.architecture"] else { return nil }
        let keys = ArchitectureKeys(prefix: arch, values: metadata)
        guard let profile = keys.profile() else { return nil }
        return (profile, keys.int("context_length"))
    }

    static func read(_ url: URL) -> [String: Value]? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        var reader = Reader(data: data)
        guard reader.readUInt32() == 0x4655_4747 else { return nil } // "GGUF" little-endian
        guard let version = reader.readUInt32(), version >= 2 else { return nil }
        guard reader.readUInt64() != nil, let kvCount = reader.readUInt64() else { return nil }

        var values: [String: Value] = [:]
        for _ in 0..<kvCount {
            guard let key = reader.readString(), let type = reader.readUInt32() else { return values }
            guard let value = reader.readValue(type: type) else { return values }
            values[key] = value
        }
        return values
    }

    private struct ArchitectureKeys {
        let prefix: String
        let values: [String: Value]

        func value(_ suffix: String) -> Value? { values["\(prefix).\(suffix)"] }

        func int(_ suffix: String) -> Int? {
            if case .int(let number)? = value(suffix) { return number }
            return nil
        }

        func profile() -> KVProfile? {
            guard let layerCount = int("block_count"), layerCount > 0 else { return nil }
            let heads = int("attention.head_count") ?? 0
            let embedding = int("embedding_length") ?? 0
            let defaultHeadDim = heads > 0 ? embedding / heads : 0
            let keyDim = int("attention.key_length") ?? defaultHeadDim
            let valueDim = int("attention.value_length") ?? keyDim
            let keyDimSWA = int("attention.key_length_swa") ?? keyDim
            let valueDimSWA = int("attention.value_length_swa") ?? valueDim
            let window = int("attention.sliding_window")
            let fullInterval = int("full_attention_interval")

            var kvHeads = [Int](repeating: heads, count: layerCount)
            switch value("attention.head_count_kv") {
            case .int(let count)?:
                kvHeads = [Int](repeating: count, count: layerCount)
            case .intArray(let perLayer)? where perLayer.count == layerCount:
                kvHeads = perLayer
            default:
                break
            }

            var slidingPattern: [Bool]?
            if case .boolArray(let pattern)? = value("attention.sliding_window_pattern"), pattern.count == layerCount {
                slidingPattern = pattern
            }

            guard keyDim > 0 else { return nil }
            var layers: [KVLayer] = []
            for index in 0..<layerCount {
                // Hybrid models (Qwen3.5) only keep a KV cache on every Nth layer.
                if let fullInterval, fullInterval > 1, (index + 1) % fullInterval != 0 { continue }
                guard kvHeads[index] > 0 else { continue }
                let isSliding = slidingPattern?[index] ?? false
                layers.append(KVLayer(
                    kvHeads: kvHeads[index],
                    keyDim: isSliding ? keyDimSWA : keyDim,
                    valueDim: isSliding ? valueDimSWA : valueDim,
                    window: isSliding ? window : nil
                ))
            }
            return layers.isEmpty ? nil : KVProfile(layers: layers, source: .gguf)
        }
    }

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func readBytes(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            let start = data.startIndex + offset
            offset += count
            return data[start..<(start + count)]
        }

        mutating func readInteger<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard let bytes = readBytes(size) else { return nil }
            var value: T = 0
            for (shift, byte) in bytes.enumerated() {
                value |= T(truncatingIfNeeded: byte) << (shift * 8)
            }
            return value
        }

        mutating func readUInt32() -> UInt32? { readInteger(UInt32.self) }
        mutating func readUInt64() -> UInt64? { readInteger(UInt64.self) }

        mutating func readString() -> String? {
            guard let length = readUInt64(), length < 1 << 24 else { return nil }
            guard let bytes = readBytes(Int(length)) else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }

        mutating func skipString() -> Bool {
            guard let length = readUInt64(), length < 1 << 24 else { return false }
            return readBytes(Int(length)) != nil
        }

        /// GGUF value types: 0 u8, 1 i8, 2 u16, 3 i16, 4 u32, 5 i32, 6 f32, 7 bool,
        /// 8 string, 9 array, 10 u64, 11 i64, 12 f64.
        mutating func readValue(type: UInt32) -> Value? {
            switch type {
            case 0: return readInteger(UInt8.self).map { .int(Int($0)) }
            case 1: return readInteger(Int8.self).map { .int(Int($0)) }
            case 2: return readInteger(UInt16.self).map { .int(Int($0)) }
            case 3: return readInteger(Int16.self).map { .int(Int($0)) }
            case 4: return readUInt32().map { .int(Int($0)) }
            case 5: return readInteger(Int32.self).map { .int(Int($0)) }
            case 6: return readUInt32().map { .double(Double(Float(bitPattern: $0))) }
            case 7: return readInteger(UInt8.self).map { .bool($0 != 0) }
            case 8: return readString().map { .string($0) }
            case 9: return readArray()
            case 10: return readUInt64().map { .int(Int(truncatingIfNeeded: $0)) }
            case 11: return readInteger(Int64.self).map { .int(Int($0)) }
            case 12: return readUInt64().map { .double(Double(bitPattern: $0)) }
            default: return nil
            }
        }

        private mutating func readArray() -> Value? {
            guard let elementType = readUInt32(), let count = readUInt64() else { return nil }
            // Tokenizer arrays are huge; skip anything that is not a small numeric/bool list.
            if elementType == 8 {
                for _ in 0..<count {
                    guard skipString() else { return nil }
                }
                return .skipped
            }
            let width: Int
            switch elementType {
            case 0, 1, 7: width = 1
            case 2, 3: width = 2
            case 4, 5, 6: width = 4
            case 10, 11, 12: width = 8
            default: return nil
            }
            guard count <= 4096 else {
                return readBytes(Int(count) * width) == nil ? nil : .skipped
            }
            if elementType == 7 {
                var flags: [Bool] = []
                for _ in 0..<count {
                    guard let byte = readInteger(UInt8.self) else { return nil }
                    flags.append(byte != 0)
                }
                return .boolArray(flags)
            }
            guard elementType != 6, elementType != 12 else {
                return readBytes(Int(count) * width) == nil ? nil : .skipped
            }
            var numbers: [Int] = []
            for _ in 0..<count {
                guard case .int(let number)? = readValue(type: elementType) else { return nil }
                numbers.append(number)
            }
            return .intArray(numbers)
        }
    }
}
