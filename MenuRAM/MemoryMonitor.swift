import Combine
import Darwin
import Dispatch
import Foundation

/// Reads macOS VM stats via Darwin host APIs and publishes them for the menu bar UI.
@MainActor
final class MemoryMonitor: ObservableObject {
    @Published private(set) var usedBytes: UInt64 = 0
    @Published private(set) var totalBytes: UInt64 = 0
    @Published private(set) var appBytes: UInt64 = 0
    @Published private(set) var wiredBytes: UInt64 = 0
    @Published private(set) var compressedBytes: UInt64 = 0
    @Published private(set) var availableBytes: UInt64 = 0
    @Published private(set) var swapUsedBytes: UInt64 = 0
    @Published private(set) var pressure: MemoryPressureLevel = .normal
    @Published private(set) var topProcesses: [ProcessMemoryInfo] = []

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var refreshProcessesOnNextTick = true

    var menuBarTitle: String {
        "\(MemoryFormat.gb(usedBytes)) / \(MemoryFormat.gb(totalBytes)) GB"
    }

    var availableText: String { "Available: \(MemoryFormat.bytes(availableBytes))" }
    var swapText: String { "Swap: \(MemoryFormat.bytes(swapUsedBytes))" }
    var pressureText: String { "Pressure: \(pressure.rawValue)" }

    init() {
        totalBytes = ProcessInfo.processInfo.physicalMemory
        refresh()
        startPressureMonitor()
        start()
    }

    func start() {
        stopTimer()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        stopTimer()
        pressureSource?.cancel()
        pressureSource = nil
    }

    func refresh() {
        refreshHostStats()
        // Process scan is heavier; refresh about every 4 seconds.
        if refreshProcessesOnNextTick {
            refreshTopProcesses()
        }
        refreshProcessesOnNextTick.toggle()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshHostStats() {
        var stats = vm_statistics64()
        // Use stride (not size). Wrong count can return incomplete/wrong fields.
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_kernel_page_size)

        // On current macOS, internal pages are anonymous/app-resident and are
        // already separate from compressor pages. Do not subtract compressed.
        let app = UInt64(stats.internal_page_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        // Headroom: free pages + pages macOS can usually reclaim for apps.
        let available = (
            UInt64(stats.free_count)
                + UInt64(stats.speculative_count)
                + UInt64(stats.inactive_count)
                + UInt64(stats.purgeable_count)
        ) * pageSize

        appBytes = app
        wiredBytes = wired
        compressedBytes = compressed
        availableBytes = available
        usedBytes = app + wired + compressed
        totalBytes = ProcessInfo.processInfo.physicalMemory
        swapUsedBytes = Self.readSwapUsedBytes() ?? swapUsedBytes

        // Keep pressure in sync when sysctl is readable; DispatchSource covers transitions.
        if let level = Self.readPressureLevel() {
            pressure = level
        }
    }

    private func refreshTopProcesses() {
        topProcesses = ProcessMemoryProvider.topProcesses(limit: 5)
    }

    private func startPressureMonitor() {
        if let level = Self.readPressureLevel() {
            pressure = level
        }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            Task { @MainActor in
                if event.contains(.critical) {
                    self.pressure = .critical
                } else if event.contains(.warning) {
                    self.pressure = .warning
                } else if event.contains(.normal) {
                    self.pressure = .normal
                }
            }
        }
        source.resume()
        pressureSource = source
    }

    /// Reads `kern.memorystatus_vm_pressure_level` when permitted.
    /// 0 = normal, 1 = warning, 2+ = critical/urgent (kernel pressure).
    private static func readPressureLevel() -> MemoryPressureLevel? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        guard result == 0 else { return nil }

        switch level {
        case 0:
            return .normal
        case 1:
            return .warning
        default:
            return .critical
        }
    }

    private static func readSwapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else { return nil }
        return usage.xsu_used
    }
}
