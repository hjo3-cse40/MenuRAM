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

/// One scanned process, already folded into the app you would quit.
struct ProcessSample {
    let pid: pid_t
    let rawName: String
    let label: ProcessLabel
    /// App that owns this process (Safari for WebKit XPCs, the Electron main process for helpers).
    let ownerPid: pid_t
    let bytes: UInt64

    var groupName: String { label.name }
}

/// macOS responsibility API: which app owns an XPC helper (e.g. WebKit → Safari).
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

enum ProcessMemoryProvider {
    /// Every app by physical footprint, with helpers, XPC services, and WebKit folded into their owner.
    static func snapshot() -> ProcessMemorySnapshot {
        let (samples, unreadable) = scan()
        var totals: [String: (bytes: UInt64, count: Int, label: ProcessLabel)] = [:]
        var result = ProcessMemorySnapshot()
        result.unreadableProcessCount = unreadable

        for sample in samples {
            result.readableBytes += sample.bytes
            var entry = totals[sample.label.name] ?? (0, 0, sample.label)
            entry.bytes += sample.bytes
            entry.count += 1
            totals[sample.label.name] = entry
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

    /// Every readable process with its footprint and owning app.
    static func samples() -> [ProcessSample] {
        scan().samples
    }

    private static func scan() -> (samples: [ProcessSample], unreadable: Int) {
        // On current macOS, proc_listallpids(nil, 0) returns a PID *count*, not a byte count.
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return ([], 0) }

        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
        let bufferBytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        _ = proc_listallpids(&pids, bufferBytes)

        var labelByPid: [pid_t: ProcessLabel] = [:]
        var samples: [ProcessSample] = []
        var unreadable = 0

        for pid in pids where pid > 0 {
            guard let bytes = memoryBytes(for: pid), bytes > 0 else {
                unreadable += 1
                continue
            }
            let rawName = processName(for: pid)
            let responsible = responsibility_get_pid_responsible_for_pid(pid)
            let ownerPid = responsible > 1 ? responsible : pid
            let label = ownerLabel(for: pid, rawName: rawName, ownerPid: ownerPid, cache: &labelByPid)
            guard !label.name.isEmpty else { continue }
            samples.append(ProcessSample(pid: pid, rawName: rawName, label: label, ownerPid: ownerPid, bytes: bytes))
        }
        return (samples, unreadable)
    }

    /// Prefer phys_footprint (matches Activity Monitor “Memory”); fall back to RSS.
    static func memoryBytes(for pid: pid_t) -> UInt64? {
        var rusage = rusage_info_v2()
        let rusageResult = withUnsafeMutablePointer(to: &rusage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        if rusageResult == 0, rusage.ri_phys_footprint > 0 {
            return rusage.ri_phys_footprint
        }
        return residentBytes(for: pid)
    }

    /// RSS. Unlike footprint, this includes mmapped model weights.
    static func residentBytes(for pid: pid_t) -> UInt64? {
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
    private static func ownerLabel(
        for pid: pid_t,
        rawName: String,
        ownerPid: pid_t,
        cache: inout [pid_t: ProcessLabel]
    ) -> ProcessLabel {
        let isXPC = rawName.hasPrefix("com.apple.WebKit") || processPath(for: pid).contains(".xpc/")
        guard isXPC else { return label(for: pid, cache: &cache) }

        if ownerPid != pid {
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
