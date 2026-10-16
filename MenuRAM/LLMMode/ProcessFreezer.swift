import AppKit
import Darwin
import Foundation

/// An app whose renderer processes can be paused with SIGSTOP.
struct FreezableGroup: Identifiable, Equatable {
    let id: pid_t
    let name: String
    /// Renderer/WebContent PIDs. The app's main process is never stopped, so its windows stay responsive.
    let rendererPids: [pid_t]
    let rendererBytes: UInt64
    let totalBytes: UInt64
    var frozenCount: Int
    var isFrontmost: Bool

    var ownerPid: pid_t { id }
    var isFrozen: Bool { frozenCount > 0 }
}

/// Pauses and resumes renderer processes. Resumes everything on quit, SIGTERM, and next launch.
@MainActor
final class ProcessFreezer: ObservableObject {
    @Published private(set) var groups: [FreezableGroup] = []
    @Published private(set) var lastError: String?

    /// pid → process start time, so a recycled PID is never resumed or stopped by mistake.
    private var frozen: [pid_t: UInt64] = [:]
    /// owner pid → frozen renderer pids.
    private var frozenByOwner: [pid_t: Set<pid_t>] = [:]
    private var activationObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    private static weak var live: ProcessFreezer?
    /// Process-wide so SIGTERM still exits even if no freezer is alive.
    private static var sigtermSource: DispatchSourceSignal?

    private static let defaultsKey = "LLMMode.frozenProcesses"
    private static let neverFreeze: Set<String> = [
        "WindowServer", "kernel_task", "launchd", "loginwindow", "Dock", "Finder",
        "SystemUIServer", "ControlCenter", "MenuRAM", "LM Studio", "Ollama",
    ]
    private static let rendererNames: [String] = ["com.apple.WebKit.WebContent"]
    private static let rendererSuffixes: [String] = [" Helper (Renderer)"]
    private static let minimumGroupBytes: UInt64 = 150 * 1_048_576

    init() {
        resumeFromPreviousLaunch()

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in self?.resume(ownerPid: pid) }
        }

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeAll() }
        }

        Self.live = self
        Self.installSigtermHandler()
    }

    /// scripts/install-local.sh uses killall (SIGTERM), which skips willTerminate.
    private static func installSigtermHandler() {
        guard sigtermSource == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { live?.resumeAll() }
            exit(0)
        }
        source.resume()
        sigtermSource = source
    }

    var hasFrozenProcesses: Bool { !frozen.isEmpty }

    /// Rebuild the freezable list from a fresh process scan.
    func update(samples: [ProcessSample], excludingPids runnerPids: Set<pid_t>, limit: Int = 5) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let selfPid = getpid()

        var renderersByOwner: [pid_t: [ProcessSample]] = [:]
        var totalByOwner: [pid_t: UInt64] = [:]
        var nameByOwner: [pid_t: String] = [:]
        var excludedOwners: Set<pid_t> = [selfPid]

        for sample in samples {
            totalByOwner[sample.ownerPid, default: 0] += sample.bytes
            if sample.pid == sample.ownerPid || nameByOwner[sample.ownerPid] == nil {
                nameByOwner[sample.ownerPid] = sample.groupName
            }
            if runnerPids.contains(sample.pid) || Self.neverFreeze.contains(sample.groupName) {
                excludedOwners.insert(sample.ownerPid)
            }
            if Self.isRenderer(sample.rawName), sample.pid != sample.ownerPid {
                renderersByOwner[sample.ownerPid, default: []].append(sample)
            }
        }

        groups = renderersByOwner.compactMap { owner, renderers -> FreezableGroup? in
            guard !excludedOwners.contains(owner), owner > 1 else { return nil }
            let rendererBytes = renderers.reduce(0) { $0 + $1.bytes }
            let frozenPids = frozenByOwner[owner] ?? []
            guard rendererBytes >= Self.minimumGroupBytes || !frozenPids.isEmpty else { return nil }
            return FreezableGroup(
                id: owner,
                name: nameByOwner[owner] ?? "PID \(owner)",
                rendererPids: renderers.map(\.pid),
                rendererBytes: rendererBytes,
                totalBytes: totalByOwner[owner] ?? rendererBytes,
                frozenCount: frozenPids.count,
                isFrontmost: owner == frontmost
            )
        }
        .sorted { $0.rendererBytes > $1.rendererBytes }
        .prefix(limit)
        .map { $0 }
    }

    func toggle(_ group: FreezableGroup) {
        if group.isFrozen {
            resume(ownerPid: group.ownerPid)
        } else {
            freeze(group)
        }
    }

    func freeze(_ group: FreezableGroup) {
        guard !group.isFrontmost else {
            lastError = "\(group.name) is in front. Switch away from it first."
            return
        }
        var stopped = frozenByOwner[group.ownerPid] ?? []
        var failures = 0
        for pid in group.rendererPids where frozen[pid] == nil {
            guard let started = Self.startTime(of: pid) else { continue }
            if kill(pid, SIGSTOP) == 0 {
                frozen[pid] = started
                stopped.insert(pid)
            } else {
                failures += 1
            }
        }
        frozenByOwner[group.ownerPid] = stopped
        lastError = failures > 0 ? "Could not pause \(failures) \(group.name) process(es)." : nil
        persist()
        refreshFrozenCounts()
    }

    func resume(ownerPid: pid_t) {
        guard let pids = frozenByOwner.removeValue(forKey: ownerPid) else { return }
        for pid in pids {
            resume(pid: pid)
        }
        persist()
        refreshFrozenCounts()
    }

    func resumeAll() {
        for pid in Array(frozen.keys) {
            resume(pid: pid)
        }
        frozenByOwner.removeAll()
        persist()
        refreshFrozenCounts()
    }

    private func resume(pid: pid_t) {
        guard let started = frozen.removeValue(forKey: pid) else { return }
        if Self.startTime(of: pid) == started {
            kill(pid, SIGCONT)
        }
    }

    private func refreshFrozenCounts() {
        groups = groups.map { group in
            var updated = group
            updated.frozenCount = frozenByOwner[group.ownerPid]?.count ?? 0
            return updated
        }
    }

    private func persist() {
        let encoded = frozen.map { ["pid": Int($0.key), "start": Int($0.value)] }
        UserDefaults.standard.set(encoded, forKey: Self.defaultsKey)
    }

    /// If MenuRAM crashed while apps were paused, wake them now.
    private func resumeFromPreviousLaunch() {
        guard let entries = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [[String: Int]] else { return }
        for entry in entries {
            guard let rawPid = entry["pid"], let start = entry["start"] else { continue }
            let pid = pid_t(rawPid)
            if Self.startTime(of: pid) == UInt64(start) {
                kill(pid, SIGCONT)
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    private static func isRenderer(_ rawName: String) -> Bool {
        rendererNames.contains(rawName) || rendererSuffixes.contains { rawName.hasSuffix($0) }
    }

    private static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}
