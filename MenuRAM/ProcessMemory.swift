import Darwin
import Foundation

struct ProcessMemoryInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let bytes: UInt64
}

enum ProcessMemoryProvider {
    /// Returns the top apps by physical footprint, with Helper processes grouped.
    static func topProcesses(limit: Int = 5) -> [ProcessMemoryInfo] {
        // On current macOS, proc_listallpids(nil, 0) returns a PID *count*, not a byte count.
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
        let bufferBytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        _ = proc_listallpids(&pids, bufferBytes)

        var totals: [String: UInt64] = [:]

        for pid in pids {
            guard pid > 0 else { continue }
            guard let bytes = memoryBytes(for: pid), bytes > 0 else { continue }
            let rawName = processName(for: pid)
            guard !rawName.isEmpty else { continue }
            let name = displayName(for: rawName)
            totals[name, default: 0] += bytes
        }

        let ranked = totals
            .map { ProcessMemoryInfo(id: $0.key, name: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }

        if ranked.count > limit {
            return Array(ranked.prefix(limit))
        }
        return ranked
    }

    /// Prefer phys_footprint (matches Activity Monitor “Memory”); fall back to RSS.
    private static func memoryBytes(for pid: pid_t) -> UInt64? {
        var rusage = rusage_info_v2()
        let rusageResult = withUnsafeMutablePointer(to: &rusage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        if rusageResult == 0, rusage.ri_phys_footprint > 0 {
            return rusage.ri_phys_footprint
        }

        var taskInfo = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, size)
        guard result > 0 else { return nil }
        return UInt64(taskInfo.pti_resident_size)
    }

    private static func processName(for pid: pid_t) -> String {
        var nameBuffer = [CChar](repeating: 0, count: 1024)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if nameLength > 0 {
            let name = String(cString: nameBuffer)
            if !name.isEmpty { return name }
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return "" }
        let path = String(cString: pathBuffer)
        return (path as NSString).lastPathComponent
    }

    /// Collapse Electron/browser helpers into a parent-style label.
    private static func displayName(for rawName: String) -> String {
        if rawName.hasPrefix("com.apple.WebKit") {
            return "WebKit"
        }

        let suffixes = [
            " Helper (Renderer)",
            " Helper (Plugin)",
            " Helper (GPU)",
            " Helper",
        ]
        for suffix in suffixes where rawName.hasSuffix(suffix) {
            let base = String(rawName.dropLast(suffix.count))
            return base.isEmpty ? rawName : base
        }
        return rawName
    }
}
