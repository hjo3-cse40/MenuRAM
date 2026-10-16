import Darwin
import Foundation
import Metal

enum SwapActivity: Equatable {
    case quiet
    case active
    case thrashing
}

enum GPUCeilingSource: Equatable {
    /// `iogpu.wired_limit_mb` was raised (or lowered) with sysctl.
    case sysctlOverride
    /// Metal's `recommendedMaxWorkingSetSize` (about 2/3 of RAM up to 36 GB, 3/4 above).
    case metalDefault
}

struct LLMMemorySnapshot: Equatable {
    var totalBytes: UInt64 = 0
    var appBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var availableBytes: UInt64 = 0
    var gpuCeilingBytes: UInt64 = 0
    var gpuCeilingSource: GPUCeilingSource = .metalDefault
    var swapInBytesPerSecond: Double = 0
    var swapOutBytesPerSecond: Double = 0

    /// Same definition as Standard mode: App + Wired + Compressed.
    var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }

    var swapBytesPerSecond: Double { swapInBytesPerSecond + swapOutBytesPerSecond }

    var swapActivity: SwapActivity {
        switch swapBytesPerSecond {
        case LLMTelemetryReader.thrashBytesPerSecond...:
            return .thrashing
        case LLMTelemetryReader.activeBytesPerSecond...:
            return .active
        default:
            return .quiet
        }
    }
}

/// Fast host counters for LLM Mode. Rates are deltas between consecutive `read()` calls.
final class LLMTelemetryReader {
    static let activeBytesPerSecond: Double = 1 * 1_048_576
    static let thrashBytesPerSecond: Double = 32 * 1_048_576

    private var lastSwapIns: UInt64?
    private var lastSwapOuts: UInt64?
    private var lastReadTime: Date?

    private static let metalCeilingBytes: UInt64? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return device.recommendedMaxWorkingSetSize
    }()

    func read() -> LLMMemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        var snapshot = LLMMemorySnapshot()
        snapshot.totalBytes = ProcessInfo.processInfo.physicalMemory
        snapshot.appBytes = UInt64(stats.internal_page_count) * pageSize
        snapshot.wiredBytes = UInt64(stats.wire_count) * pageSize
        snapshot.compressedBytes = UInt64(stats.compressor_page_count) * pageSize
        snapshot.availableBytes = (
            UInt64(stats.free_count)
                + UInt64(stats.speculative_count)
                + UInt64(stats.inactive_count)
                + UInt64(stats.purgeable_count)
        ) * pageSize

        let (ceiling, source) = Self.gpuCeiling(totalBytes: snapshot.totalBytes)
        snapshot.gpuCeilingBytes = ceiling
        snapshot.gpuCeilingSource = source

        // Use swapins/swapouts, not pageins: loading an mmapped GGUF pages in gigabytes
        // of file data, which is normal and would trip a pagein-based alarm.
        let now = Date()
        let swapIns = stats.swapins
        let swapOuts = stats.swapouts
        if let lastSwapIns, let lastSwapOuts, let lastReadTime {
            let seconds = now.timeIntervalSince(lastReadTime)
            if seconds > 0.05 {
                let inPages = swapIns >= lastSwapIns ? swapIns - lastSwapIns : 0
                let outPages = swapOuts >= lastSwapOuts ? swapOuts - lastSwapOuts : 0
                snapshot.swapInBytesPerSecond = Double(inPages * pageSize) / seconds
                snapshot.swapOutBytesPerSecond = Double(outPages * pageSize) / seconds
            }
        }
        lastSwapIns = swapIns
        lastSwapOuts = swapOuts
        lastReadTime = now

        return snapshot
    }

    private static func gpuCeiling(totalBytes: UInt64) -> (UInt64, GPUCeilingSource) {
        var limitMB: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("iogpu.wired_limit_mb", &limitMB, &size, nil, 0) == 0, limitMB > 0 {
            return (UInt64(limitMB) * 1_048_576, .sysctlOverride)
        }
        if let metalCeilingBytes {
            return (metalCeilingBytes, .metalDefault)
        }
        let fraction: Double = totalBytes > 36 * 1_073_741_824 ? 0.75 : 2.0 / 3.0
        return (UInt64(Double(totalBytes) * fraction), .metalDefault)
    }
}
