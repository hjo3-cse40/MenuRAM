import Darwin
import Foundation

struct ProcessMemoryInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let bytes: UInt64
    let kind: ProcessKind
    let processCount: Int
    let detail: String?
}

struct ProcessMemorySnapshot: Equatable {
    /// Every readable app/tool, largest first.
    var groups: [ProcessMemoryInfo] = []
    /// Footprint we could read. Root and other-user processes (WindowServer, most daemons) are not readable.
    var readableBytes: UInt64 = 0
    var unreadableProcessCount = 0
}

/// macOS responsibility API: which app owns an XPC helper (e.g. WebKit → Safari).
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

enum ProcessMemoryProvider {
    /// Every app by physical footprint, with helpers, XPC services, and WebKit folded into their owner.
    static func snapshot() -> ProcessMemorySnapshot {
        // On current macOS, proc_listallpids(nil, 0) returns a PID *count*, not a byte count.
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return ProcessMemorySnapshot() }

        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
        let bufferBytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        _ = proc_listallpids(&pids, bufferBytes)

        var labelByPid: [pid_t: ProcessLabel] = [:]
        var totals: [String: (bytes: UInt64, count: Int, label: ProcessLabel)] = [:]
        var result = ProcessMemorySnapshot()

        for pid in pids where pid > 0 {
            guard let bytes = memoryBytes(for: pid), bytes > 0 else {
                result.unreadableProcessCount += 1
                continue
            }
            let label = ownerLabel(for: pid, cache: &labelByPid)
            guard !label.name.isEmpty else { continue }
            result.readableBytes += bytes
            var entry = totals[label.name] ?? (0, 0, label)
            entry.bytes += bytes
            entry.count += 1
            totals[label.name] = entry
        }

        result.groups = totals
            .map {
                ProcessMemoryInfo(
                    id: $0.key,
                    name: $0.key,
                    bytes: $0.value.bytes,
                    kind: $0.value.label.kind,
                    processCount: $0.value.count,
                    detail: $0.value.label.detail
                )
            }
            .sorted { $0.bytes > $1.bytes }
        return result
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
        return (processPath(for: pid) as NSString).lastPathComponent
    }

    private static func processPath(for pid: pid_t) -> String {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return "" }
        return String(cString: pathBuffer)
    }

    private static func label(for pid: pid_t, cache: inout [pid_t: ProcessLabel]) -> ProcessLabel {
        if let cached = cache[pid] {
            return cached
        }
        let label = ProcessNaming.label(pid: pid, rawName: processName(for: pid), path: processPath(for: pid))
        cache[pid] = label
        return label
    }

    /// Fold XPC services (WebKit, extensions) into the app you would actually quit.
    /// Their process names have no parent, so we use the responsible PID.
    private static func ownerLabel(for pid: pid_t, cache: inout [pid_t: ProcessLabel]) -> ProcessLabel {
        let path = processPath(for: pid)
        let rawName = processName(for: pid)
        let isXPC = rawName.hasPrefix("com.apple.WebKit") || path.contains(".xpc/")
        guard isXPC else { return label(for: pid, cache: &cache) }

        let ownerPid = responsibility_get_pid_responsible_for_pid(pid)
        if ownerPid > 1, ownerPid != pid {
            let owner = label(for: ownerPid, cache: &cache)
            if !owner.name.isEmpty, owner.kind == .app {
                return owner
            }
        }
        if rawName.hasPrefix("com.apple.WebKit") {
            return ProcessLabel(name: "WebKit", kind: .system, detail: nil)
        }
        return label(for: pid, cache: &cache)
    }
}
